# Security policy

## Reporting a vulnerability

Please report vulnerabilities **privately** through GitHub: **Security → Report a vulnerability** on this repository. Don't open a public issue. Reports are acknowledged as soon as possible, and fixes are released as a new image build.

## Supported versions

Only the latest image built from `main` is supported. Images are rebuilt weekly, so base-image and package security fixes are picked up even without code changes. Update your pinned digest regularly.

## How the image is maintained

- Every tool is pinned to an exact version and verified against its published checksum or signed package repository at build time.
- Every build is scanned with Trivy and fails on HIGH or CRITICAL vulnerabilities that have a fix. Published images carry an SBOM and build provenance attestations.
- Dependabot tracks the base and dind image digests and the GitHub Actions, which are pinned by commit SHA. A weekly workflow tracks the other pinned tools.
- This repository's workflows run on GitHub-hosted runners only.

## Using the runners safely

Read the [isolation model](README.md#isolation-model). In short: the Docker-in-Docker sidecar is privileged, so only run trusted code on these runners. Attach them only to private repositories you control, never to a public repository, and scope the registration token to a single repository.
