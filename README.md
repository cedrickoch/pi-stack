# pi-stack — sandboxed pi coding agent behind a LiteLLM proxy

This stack runs the [pi coding agent](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
inside a locked-down container with **no internet access**. All model traffic goes
through a local [LiteLLM](https://docs.litellm.ai/) proxy, which is the only
container with internet egress and provider API keys.

```
┌──────────────┐    internal network (no internet)    ┌───────────┐      egress       ┌─────────────────────┐
│      pi      │ ───────────────────────────────────▶ │  LiteLLM  │ ────────────────▶ │ Providers           │
│  (sandbox)   │      http://litellm:4000/v1          │   proxy   │     Internet      │ Swisscom / Numes    │
└──────────────┘                                      └───────────┘                   └─────────────────────┘
        host: LiteLLM reachable only on 127.0.0.1:4000
```

## Repository layout

| File | Purpose |
|---|---|
| `Dockerfile.pi` | Image build for the `pi` container (`node:24-bookworm-slim` + pinned pi version) |
| `docker-compose.yml` | Defines the `litellm` and `pi` services, networks, and hardening |
| `litellm-config.yaml` | Model list, master key, global budget for LiteLLM |
| `pi-config/` | pi agent config (`models.json`, `settings.json`) and session history |
| `scripts/make-pi-key.sh` | Mints a restricted LiteLLM **virtual key** for the pi container |
| `SECURITY.md` | Threat model, hardening measures, residual risks |

## Prerequisites

- Docker with the compose plugin (`docker compose version`)
- API keys for the configured providers (see `litellm-config.yaml`)
- `jq` (optional, nicer output for `make-pi-key.sh`)

## 1. Configure environment

Create a `.env` file in the project root (never commit it):

```sh
# Required: master key for the LiteLLM proxy (choose a strong random value)
LITELLM_MASTER_KEY=sk-master-change-me

# Required: provider keys used by litellm-config.yaml
SWISSCOM_MYAI_API_KEY=...
NUMES_API_KEY=...

# Recommended: restricted virtual key for pi (see step 3).
# Leave unset for the first bootstrap; pi then falls back to the master key.
# LITELLM_PROXY_TOKEN=sk-...

# Optional: workspace to mount into the pi container (defaults to this repo).
# Can also be set per command: WORKSPACE=$PWD/testprojekt docker compose run --rm pi ...
# WORKSPACE=/path/to/your/project
```

## 2. Build the image

Only the `pi` image is built; the LiteLLM image is pulled from
`ghcr.io/berriai/litellm` (version-pinned in `docker-compose.yml`).

```sh
docker compose build pi
```

To build with a different pi version (default is pinned in `Dockerfile.pi`):

```sh
docker compose build --build-arg PI_VERSION=1.5.2 pi
```

Recommended hardening: pin the LiteLLM image additionally by digest:

```sh
docker buildx imagetools inspect ghcr.io/berriai/litellm:v1.108.9
# append @sha256:<DIGEST> to the image line in docker-compose.yml
```

## 3. Start the stack

LiteLLM must be up first so the virtual key can be created:

```sh
docker compose up -d litellm

# Wait until healthy, then mint the restricted key for pi:
./scripts/make-pi-key.sh
```

Copy the printed token into `.env`:

```
LITELLM_PROXY_TOKEN=sk-...
```

Then recreate pi so it picks up the new token:

```sh
docker compose up -d
```

## 4. Start pi

The container's entrypoint is `pi` itself, so extra arguments are passed straight
to the pi CLI. Recommended for interactive use:

```sh
WORKSPACE=$PWD/testprojekt docker compose run --rm pi --provider litellm --model glm-5.3-flash
```

What each part does:

- `WORKSPACE=$PWD/testprojekt` — mounts the given directory at `/workspace`
  inside the container (overrides the `WORKSPACE` variable from `.env`/the
  default of this repo). Point it at whatever project pi should work on.
- `--rm` — removes the container when the session ends, so every run starts
  fresh and disposable (with a TTY).
- `--provider litellm --model glm-5.3-flash` — selects provider and model for
  this session, overriding the defaults from `pi-config/settings.json`
  (`defaultProvider: litellm`, `defaultModel: kimi-k3.1-pro:free`).

Alternatives:

```sh
docker compose run --rm pi                                    # use the configured defaults
docker compose attach pi                                      # attach to the long-running container from `up -d`
docker compose run --rm pi --help                             # pi CLI help
WORKSPACE=$PWD/myrepo docker compose run --rm pi --provider litellm --model kimi-k2.6
```

Inside pi, switch models any time with `/model`. Config and session history
come from `pi-config/`.

## 5. Verify

```sh
# pi must NOT see the master key (expect 0)
docker compose exec pi env | grep -c MASTER

# pi has no direct internet (expect the fallback message)
docker compose exec pi sh -c 'wget -qO- https://example.com || echo "kein Internet (ok)"'

# pi can reach the proxy and list models
docker compose exec pi curl -s -H "Authorization: Bearer $LITELLM_PROXY_TOKEN" \
  http://litellm:4000/model/info | head

# proxy health from the host
curl -s http://127.0.0.1:4000/health/liveliness
```

## Available models

Configured in `litellm-config.yaml` (proxy side) and `pi-config/models.json`
(pi side):

- `glm-5.3-flash`, `qwen3.5-397b-a17b` (Swisscom)
- `deepseek-v4.1-flash-1017-uncensored`, `deepseek-v4.1-flash-uncensored-fp8`,
  `kimi-k2.6`, `kimi-k3.1-pro:free` (Numes)

To add a model: extend **both** `litellm-config.yaml` and `pi-config/models.json`,
and add it to the model list in `scripts/make-pi-key.sh` if pi should use it via
the virtual key.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `LITELLM_MASTER_KEY oder LITELLM_PROXY_TOKEN in .env setzen` on `up` | Neither variable is set in `.env` — see step 1. |
| pi requests fail with 401 after a LiteLLM restart | Without Postgres, virtual keys live only in memory. Re-run `scripts/make-pi-key.sh`, update `.env`, then `docker compose up -d --force-recreate pi`. |
| `litellm` container unhealthy | Check `docker compose logs litellm`; usually a missing provider key or bad `litellm-config.yaml`. |
| Model not listed in pi | Model missing in `pi-config/models.json` or not in `enabledModels` in `pi-config/settings.json`. |
| `npm install` inside pi fails on read-only fs | Intentional; `/home/node/.npm` is a tmpfs and non-persistent. Install on the host workspace instead. |

## Security

Read `SECURITY.md` for the threat model, applied hardening
(no egress for pi, read-only rootfs, `cap_drop: ALL`, resource limits, budget
caps), and residual risks. Key points:

- pi gets a **virtual key** restricted to 4 models, rpm/tpm limits, and a
  budget — never the master key.
- The global spend cap is `max_budget` in `litellm-config.yaml`.
- `.env` and `pi-config/sessions/` must never be committed or shared.
