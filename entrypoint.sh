#!/usr/bin/env bash
# Registers an ephemeral GitHub Actions runner, runs one job, and exits; the container's
# restart policy starts the next one. Runs as root only to hold the GitHub credential: the
# runner and every job step run as the unprivileged `runner` user with a clean environment,
# so jobs can't read the token (root-owned process memory and /proc/1/environ).
#
# Environment:
#   RUNNER_REPOSITORY   owner/repo to register with (required)
#   GITHUB_TOKEN        fine-grained PAT with the repository's "Administration: write"
#                       permission, used only to request registration/removal tokens (required)
#   RUNNER_LABELS       comma-separated extra labels (default: none; GitHub adds self-hosted,Linux,X64)
#   RUNNER_NAME_PREFIX  runner name prefix (default: runner)
#   RUNNER_EPHEMERAL    true (default) for one job per registration
set -euo pipefail

: "${RUNNER_REPOSITORY:?Set RUNNER_REPOSITORY to owner/repo}"
: "${GITHUB_TOKEN:?Set GITHUB_TOKEN to a fine-grained PAT with Administration: write}"
github_token="${GITHUB_TOKEN}"
unset GITHUB_TOKEN

labels="${RUNNER_LABELS:-}"
name="${RUNNER_NAME_PREFIX:-runner}-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
ephemeral="${RUNNER_EPHEMERAL:-true}"
runner_home=/home/runner
runner_dir="${runner_home}/actions-runner"

log() { echo "[entrypoint] $*"; }

runner_token() {
  # $1: registration-token | remove-token
  curl -fsSL -X POST \
    -H "Authorization: Bearer ${github_token}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${RUNNER_REPOSITORY}/actions/runners/$1" | jq -er .token
}

as_runner() {
  # Run as `runner` with only the variables a job needs; never the GitHub credential.
  setpriv --reuid=runner --regid=runner --init-groups \
    env -i HOME="${runner_home}" USER=runner PATH="${PATH}" LANG=C.UTF-8 \
      DOTNET_ROOT="${DOTNET_ROOT}" DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 \
      POWERSHELL_TELEMETRY_OPTOUT=1 PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH}" \
      DOCKER_HOST="${DOCKER_HOST}" DOCKER_TLS_VERIFY="${DOCKER_TLS_VERIFY}" DOCKER_CERT_PATH="${DOCKER_CERT_PATH}" \
      RUNNER_ALLOW_RUNASROOT=0 "$@"
}

# 1. Wait for the Docker-in-Docker sidecar.
for _ in $(seq 1 60); do
  if as_runner docker info >/dev/null 2>&1; then break; fi
  sleep 1
done
as_runner docker info >/dev/null 2>&1 || { log "Docker-in-Docker is not reachable at ${DOCKER_HOST}"; exit 1; }

# 2. Start from a clean slate: the container (and its dind daemon) are reused between jobs.
log "Cleaning up after any previous job."
as_runner bash -c 'ids=$(docker ps -aq); [ -z "$ids" ] || docker rm -f $ids >/dev/null'
as_runner docker network prune -f >/dev/null
as_runner docker volume prune -af >/dev/null
# Keep the mounted package caches (.nuget, .npm); remove everything else in the home directory.
find "${runner_home}" -mindepth 1 -maxdepth 1 ! -name .nuget ! -name .npm -exec rm -rf {} +
rm -rf /tmp/* /tmp/.[!.]* 2>/dev/null || true
cp -a /opt/actions-runner "${runner_dir}"
chown -R runner:runner "${runner_home}"

# 3. Register.
log "Registering ${name} for ${RUNNER_REPOSITORY} (labels: ${labels:-default}, ephemeral: ${ephemeral})."
if ! registration_token="$(runner_token registration-token)"; then
  # Back off so a bad or expired token doesn't make the restart policy hammer the GitHub API.
  log "Could not get a registration token (check GITHUB_TOKEN and RUNNER_REPOSITORY); retrying in 60s."
  sleep 60
  exit 1
fi
config_args=(--unattended --url "https://github.com/${RUNNER_REPOSITORY}" --token "${registration_token}"
  --name "${name}" --work _work --replace --disableupdate)
[ -n "${labels}" ] && config_args+=(--labels "${labels}")
[ "${ephemeral}" = "true" ] && config_args+=(--ephemeral)
(cd "${runner_dir}" && as_runner ./config.sh "${config_args[@]}")
unset registration_token

deregister() {
  log "Deregistering ${name}."
  local token
  token="$(runner_token remove-token)" || return 0
  (cd "${runner_dir}" && as_runner ./config.sh remove --token "${token}") || true
}

# 4. Run one job (ephemeral) or until stopped.
runner_pid=""
on_signal() {
  [ -n "${runner_pid}" ] && kill -TERM "${runner_pid}" 2>/dev/null && wait "${runner_pid}" || true
  deregister
  exit 143
}
trap on_signal TERM INT

(cd "${runner_dir}" && as_runner ./run.sh) &
runner_pid=$!
set +e
wait "${runner_pid}"
status=$?
set -e

# An ephemeral runner deregisters itself after its job; otherwise clean up here.
[ -f "${runner_dir}/.runner" ] && deregister
exit "${status}"
