# Repository Guidelines

## Project Structure & Module Organization

This repository is a Docker Compose bundle for running Hermes Agent with Hindsight MCP, Headroom MCP, and Firecrawl/SearXNG/Camofox web sidecars. The main stack is `docker-compose.yml`; use `docker-compose.rootless.yml` as an override for rootless Docker deployments. Tracked Hermes seed configuration lives under `hermes-data/`: `config.rootless.yaml`, `config.rootful.yaml`, and `profile-templates/`. Writable Hermes runtime state lives under ignored `appdata/hermes/`, including local `config.yaml` and generated profiles. Web-search templates live in `web-search/`; generated `web-search/searxng-settings.yml` and `.firecrawl-src/` are ignored. Helper scripts are in `scripts/`. Keep secrets in local `.env` files copied from `.env.example` files, not in committed YAML.

## Build, Test, and Development Commands

- `docker compose --env-file .env config`: validate the rootful Compose configuration.
- `docker compose --env-file .env --profile headroom up -d`: start Hermes, Hindsight, Headroom MCP plus proxy/stats, Firecrawl, SearXNG, and Camofox.
- `docker compose --env-file .env --profile dashboard --profile headroom up -d`: include the Hermes dashboard service and Headroom stats proxy.
- `docker compose --env-file .env --profile headroom -f docker-compose.yml -f docker-compose.rootless.yml config`: validate rootless mode with the Headroom stats proxy.
- `./setup.sh`: run the guided local setup flow and print the matching Compose command.
- `./reset.sh`: archive generated runtime state and prepare for a fresh `./setup.sh` run.
- `./scripts/create-profile.sh research`: create a rootful profile using bank `hermes-research`.
- `./scripts/create-profile-rootless.sh research`: create a rootless profile using service-name MCP URLs.
- `curl -fsS http://127.0.0.1:8888/health`, `curl -fsS http://127.0.0.1:8787/readyz`, and `curl -fsS http://127.0.0.1:3002/v0/health/liveness`: check core sidecar health.

## Coding Style & Naming Conventions

Use two-space indentation in YAML. Keep shell scripts POSIX-compatible (`#!/usr/bin/env sh`, `set -eu`) and prefer lowercase variable names for local script variables. Profile names must be lowercase and use only letters, numbers, underscores, and hyphens; `default` is reserved by Hermes for the base home. Hindsight bank IDs use the default pattern `hermes-<profile>`.

## Testing Guidelines

There is no formal test suite. Before submitting changes, run the relevant `docker compose ... config` command and syntax-check scripts with `sh -n scripts/create-profile.sh scripts/create-profile-rootless.sh`. For profile template changes, create a temporary profile and inspect the generated `config.yaml`, `SOUL.md`, `.env.example`, and `README.md`.

## Commit & Pull Request Guidelines

This workspace does not include Git history, so no project-specific commit convention can be inferred. Use concise, imperative commit subjects such as `Add rootless profile template`. Pull requests should describe the deployment path affected, list validation commands run, link related issues, and call out changes to ports, socket mounts, secrets, or profile defaults.

## Security & Configuration Tips

Treat the Docker socket mount as privileged host access. Do not commit `.env` files, API keys, generated local state, profile secrets, `.firecrawl-src/`, or generated SearXNG settings. Keep public examples in `.env.example` and template files only.
