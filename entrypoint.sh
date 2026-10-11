#!/usr/bin/env bash
# Runs one job with a single-use just-in-time (JIT) runner config, then exits. The host-side
# supervisor (supervisor/runner-supervisor.ps1) mints the config with GitHub's
# generate-jitconfig API and starts a brand-new container (docker run --rm) for every job, so
# no long-lived credential ever enters the container.
#
# Environment:
#   RUNNER_JITCONFIG   encoded JIT config for exactly one ephemeral runner (required)
set -euo pipefail

: "${RUNNER_JITCONFIG:?Set RUNNER_JITCONFIG; the runner supervisor provides it}"
jit_config="${RUNNER_JITCONFIG}"
unset RUNNER_JITCONFIG

log() { echo "[entrypoint] $*"; }

# 1. Wait for the Docker-in-Docker sidecar (shared network namespace, TLS on localhost:2376).
for _ in $(seq 1 60); do
  if docker info >/dev/null 2>&1; then break; fi
  sleep 1
done
docker info >/dev/null 2>&1 || { log "Docker-in-Docker is not reachable at ${DOCKER_HOST}"; exit 1; }

# 2. The dind daemon outlives runner containers: remove whatever the previous job left in it.
#    Images are kept as a cache.
ids=$(docker ps -aq)
[ -z "${ids}" ] || docker rm -f ${ids} >/dev/null
docker network prune -f >/dev/null
docker volume prune -af >/dev/null

# 3. Run exactly one job.
log "Starting the runner."
cd "${HOME}/actions-runner"
exec ./run.sh --jitconfig "${jit_config}"
