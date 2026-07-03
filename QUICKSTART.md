# Quickstart

This is the short path for getting the Compose stack running. Use `research`
as the example profile name, or replace it with your own.

## Rootless Docker Workflow (Recommended)

Use this when Docker is running in rootless mode for your deployment user.

1. Create and edit the environment files:

```bash
cp .env.example .env
sed -i "s|^DOCKER_SOCK=.*|DOCKER_SOCK=/run/user/$(id -u)/docker.sock|" .env
cp hermes-data/.env.example hermes-data/.env
```

Set `HINDSIGHT_API_LLM_*` in `.env` for Hindsight. Add Hermes runtime provider
keys, such as `DEEPSEEK_API_KEY`, to `hermes-data/.env` if needed.

2. Create a rootless profile:

```bash
chmod +x scripts/create-profile.sh scripts/create-profile-rootless.sh
./scripts/create-profile-rootless.sh research
```

3. Validate and start the rootless stack:

```bash
docker compose --env-file .env \
  -f docker-compose.yml \
  -f docker-compose.rootless.yml \
  config

docker compose --env-file .env \
  -f docker-compose.yml \
  -f docker-compose.rootless.yml \
  up -d
```

4. Check services and initialize the Hindsight bank:

```bash
curl -fsS http://127.0.0.1:8888/health
curl -fsS http://127.0.0.1:8787/readyz
curl -fsS -X PUT "http://127.0.0.1:8888/v1/default/banks/hermes-research" \
  -H "content-type: application/json" \
  -d '{}'
```

## Rootful Docker Workflow

Use this when Docker runs normally with the host socket at `/var/run/docker.sock`.

1. Create and edit the environment files:

```bash
cp .env.example .env
sed -i "s/^HERMES_UID=.*/HERMES_UID=$(id -u)/" .env
sed -i "s/^HERMES_GID=.*/HERMES_GID=$(id -g)/" .env
cp hermes-data/.env.example hermes-data/.env
```

2. Create a rootful profile:

```bash
chmod +x scripts/create-profile.sh scripts/create-profile-rootless.sh
./scripts/create-profile.sh research
```

3. Validate and start the stack:

```bash
docker compose --env-file .env config
docker compose --env-file .env up -d
```

4. Check services and initialize the Hindsight bank:

```bash
curl -fsS http://127.0.0.1:8888/health
curl -fsS http://127.0.0.1:8787/readyz
curl -fsS -X PUT "http://127.0.0.1:8888/v1/default/banks/hermes-research" \
  -H "content-type: application/json" \
  -d '{}'
```

For details on dashboards, provider examples, ports, and profile wiring, see
`README.md`.
