# Repository Guidelines

## Project Structure & Module Organization

This repository is a Docker Compose bundle for running Hermes Agent with Hindsight MCP and Headroom MCP sidecars. The main stack is `docker-compose.yml`; use `docker-compose.rootless.yml` as an override for rootless Docker deployments. Runtime configuration lives under `hermes-data/`, with `hermes-data/config.yaml` and `hermes-data/config.rootless.yaml` mounted into the Hermes container. Profile templates live in `hermes-data/profiles/`: `_template/` and `_template-rootless/` are scaffolding sources for generated profiles. Helper scripts are in `scripts/`. Keep secrets in local `.env` files copied from `.env.example` files, not in committed YAML.

## Build, Test, and Development Commands

- `docker compose --env-file .env config`: validate the rootful Compose configuration.
- `docker compose --env-file .env up -d`: start Hermes, Hindsight, and Headroom.
- `docker compose --env-file .env --profile dashboard up -d`: include the Hermes dashboard service.
- `docker compose --env-file .env -f docker-compose.yml -f docker-compose.rootless.yml config`: validate rootless mode.
- `./scripts/create-profile.sh research`: create a rootful profile using bank `hermes-research`.
- `./scripts/create-profile-rootless.sh research`: create a rootless profile using service-name MCP URLs.
- `curl -fsS http://127.0.0.1:8888/health` and `curl -fsS http://127.0.0.1:8787/readyz`: check sidecar health.

## Coding Style & Naming Conventions

Use two-space indentation in YAML. Keep shell scripts POSIX-compatible (`#!/usr/bin/env sh`, `set -eu`) and prefer lowercase variable names for local script variables. Profile names and Hindsight bank IDs must use only letters, numbers, underscores, and hyphens; the default bank pattern is `hermes-<profile>`.

## Testing Guidelines

There is no formal test suite. Before submitting changes, run the relevant `docker compose ... config` command and syntax-check scripts with `sh -n scripts/create-profile.sh scripts/create-profile-rootless.sh`. For profile template changes, create a temporary profile and inspect the generated `config.yaml`, `SOUL.md`, `.env.example`, and `README.md`.

## Commit & Pull Request Guidelines

This workspace does not include Git history, so no project-specific commit convention can be inferred. Use concise, imperative commit subjects such as `Add rootless profile template`. Pull requests should describe the deployment path affected, list validation commands run, link related issues, and call out changes to ports, socket mounts, secrets, or profile defaults.

## Security & Configuration Tips

Treat the Docker socket mount as privileged host access. Do not commit `.env` files, API keys, generated local state, or profile secrets. Keep public examples in `.env.example` and template files only.
