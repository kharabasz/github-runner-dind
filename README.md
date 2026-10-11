# github-runner-dind

Ephemeral self-hosted GitHub Actions runners in our own Docker image, each paired with its own Docker-in-Docker (dind) daemon.

- **Our own image.** It starts from `ubuntu:24.04`, pinned by digest. Every tool is pinned to an exact version and verified against its published checksum or signed package repository: the Actions runner, PowerShell 7, .NET SDK, Node.js, the Docker CLI and Compose plugin, and Playwright Chromium. Nothing comes from a third-party runner image.
- **One job per registration.** A runner registers, runs one job, deregisters and restarts. Before each job it removes everything the previous job left behind, in its workspace and in its dind daemon.
- **Isolated from the host's Docker.** Jobs get their own dind daemon, so they can't see or control the host's containers, and no host directories are mounted.
- **Maintained.** The image is rebuilt weekly and on every change on GitHub-hosted runners, scanned with Trivy, published with an SBOM and provenance, and kept current by Dependabot plus a weekly version check.

## Quick start

1. Create a **fine-grained personal access token** (GitHub → Settings → Developer settings → Fine-grained tokens):
   - Resource owner: the owner of the repository the runners serve.
   - Repository access: **only that repository**.
   - Permissions: **Administration: Read and write**. The entrypoint uses it only to request short-lived runner registration and removal tokens, and job steps never see it.
   - Set an expiry and rotate it.
2. Configure and start the runners:

   ```sh
   cp runner.env.example runner.env   # set RUNNER_REPOSITORY, GITHUB_TOKEN, RUNNER_LABELS
   docker compose up -d
   docker compose logs -f runner-1
   ```

3. Target them in workflows by label:

   ```yaml
   jobs:
     test:
       runs-on: [self-hosted, linux, ci]
   ```

**Pin the image by digest** in production rather than using `latest`. Set `RUNNER_IMAGE` in the shell or in a `.env` file next to `compose.yaml`:

```sh
RUNNER_IMAGE=ghcr.io/kharabasz/github-runner-dind@sha256:<digest>
```

## Configuration

| Setting | Where | Default | Meaning |
|---|---|---|---|
| `RUNNER_REPOSITORY` | `runner.env` | (required) | `owner/repo` to register with |
| `GITHUB_TOKEN` | `runner.env` | (required) | Fine-grained PAT, see above |
| `RUNNER_LABELS` | `runner.env` | none | Extra labels; GitHub adds `self-hosted`, `Linux`, `X64` |
| `RUNNER_EPHEMERAL` | `runner.env` | `true` | One job per registration |
| `RUNNER_IMAGE` | shell or `.env` | `ghcr.io/kharabasz/github-runner-dind:latest` | Runner image, ideally pinned by digest |
| `RUNNER_NAME_PREFIX` | shell or `.env` | `runner` | Runners are named `<prefix>-<n>-<random>` |
| `RUNNER_CPUS`, `RUNNER_MEMORY` | shell or `.env` | `4`, `6g` | Limits for each dind daemon, which runs the jobs' containers |
| `RUNNERS_PROJECT` | shell or `.env` | `github-runners` | Compose project name |

`compose.yaml` defines two runner/dind pairs. To add more, copy a `dind-N`/`runner-N` pair with the next number and add its volumes.

### What persists between jobs
- **Package caches:** `~/.nuget` and `~/.npm` are named volumes per runner, so restores stay fast.
- **Docker images** in each dind daemon (for example `postgres:17-alpine`), so jobs don't pull them every time. Containers, networks and volumes are removed before every job.
- **Nothing else.** The runner directory, workspace, home directory and `/tmp` are reset before every job.

### Tests that start containers
Each runner shares its dind sidecar's network namespace. A job that runs `docker run --publish 127.0.0.1::5432 …` can therefore reach the container on `127.0.0.1:<port>`, as on a normal machine, and concurrent runners can't collide on ports.

## Isolation model

**What it protects against:**
- jobs reading or changing the host's Docker containers and volumes, because the host's Docker socket is never mounted;
- jobs reading host files, because no host directories are mounted;
- jobs reading the runner registration credential, because the entrypoint keeps it in a root-owned process and runs jobs as the unprivileged `runner` user with a clean environment;
- one job seeing another's leftovers, because of the per-job cleanup and one dind daemon per runner.

**What it does not protect against:** the dind sidecar must run `privileged`. Code that controls a job can start privileged containers on its dind daemon, and a determined attacker could use that to escape to the Docker host (on Docker Desktop, its Linux VM). So treat these runners as **trusted-code runners**:
- Only attach them to **private** repositories whose code you trust. Never attach them to a public repository: anyone who can open a pull request could run code on them.
- Don't run untrusted or third-party pull requests on them.

Stronger isolation needs a different runtime, such as Sysbox, rootless dind on a Linux host, or a VM per job.

## Updating

- **Base image, dind image and GitHub Actions:** Dependabot opens pull requests.
- **Tools pinned by version** (`ARG …_VERSION` in the `Dockerfile`): the weekly `check-versions` workflow opens or updates a *Pinned tool updates available* issue. Bump the version **and its checksum**; each `ARG` has a comment saying where the checksum comes from. Keep `DOCKER_CLI_VERSION` in step with the dind image, and `PLAYWRIGHT_VERSION` in step with the consuming projects' `@playwright/test`.
- **The runner never auto-updates** (`--disableupdate`). GitHub stops accepting runner versions some time after a new release, so keep `RUNNER_VERSION` current.

Every change is built, scanned and only pushed from `main`. Consumers then bump their pinned digest.

## Troubleshooting

- **`Could not get a registration token`:** `GITHUB_TOKEN` is missing, expired, scoped to another repository, or lacks *Administration: write*. The runner retries every 60 seconds.
- **`Docker-in-Docker is not reachable`:** the dind sidecar isn't healthy. Check `docker compose logs dind-1`. It needs `privileged: true`.
- **A job is stuck as queued:** check that the runners are online in the repository's **Settings → Actions → Runners** and that the job's `runs-on` labels match `RUNNER_LABELS`.
- **The dind data volumes grow:** images accumulate across jobs. Run `docker compose down` followed by `docker volume rm <project>_dind-1-data` (one per runner), then `docker compose up -d`.

## License

[MIT](LICENSE)
