# Secure Hermes Sandbox

Run [NousResearch Hermes Agent](https://github.com/NousResearch/hermes-agent) inside a [Docker Sandbox](https://docs.docker.com/ai/sandboxes/) (`sbx`) microVM, with web access forced through a local sanitizer that strips PII with [Microsoft Presidio](https://microsoft.github.io/presidio/) before forwarding to [self-hosted Firecrawl](https://github.com/firecrawl/firecrawl/blob/main/SELF_HOST.md).

```
Hermes (sbx microVM)
  │  FIRECRAWL_API_URL = http://host.docker.internal:5050
  ▼
sanitizer-proxy  (Presidio analyze + anonymize)
  │
  ▼
Firecrawl
```

LLM credentials stay on the host and are injected through sbx's credential proxy; keys never enter the VM.

## Prerequisites

- macOS with Docker Desktop running
- Docker Sandboxes CLI:
  ```sh
  brew install docker/tap/sbx
  sbx login
  ```
- ~6 GB free disk for the Firecrawl stack

## Quick Start

```sh
./setup.sh
```

This builds the backend (Presidio + Firecrawl + sanitizer), creates the `secure-hermes` sandbox, and drops you into a shell. Type `hermes` to launch the agent.

Re-attach later (preserving installs, memory, and history):

```sh
sbx run secure-hermes      # or pick it from the sbx TUI, or re-run ./setup.sh
```

> `sbx rm secure-hermes` wipes Hermes' internal state (`~/.hermes`, OAuth tokens, memory, history). Files in `HermesWorkspace/` survive on the host.

## Credentials

LLM provider keys live in your host keychain and are injected into outbound requests by sbx's [credential proxy](https://docs.docker.com/ai/sandboxes/security/credentials/) — they never enter the VM. Inside the sandbox the corresponding env vars read `proxy-managed`; that is expected.

Any [built-in service](https://docs.docker.com/ai/sandboxes/security/credentials/#built-in-services) (`anthropic`, `openai`, `google`, `groq`, `mistral`, `xai`, `aws`, …) works out of the box:

```sh
sbx secret set -g anthropic   # ANTHROPIC_API_KEY
sbx secret set -g openai      # OPENAI_API_KEY
sbx secret set -g google      # GEMINI_API_KEY / GOOGLE_API_KEY
```

**Global vs sandbox-scoped.** `-g` secrets apply to every sandbox but only bind at sandbox creation — recreate to pick up a new one (`sbx rm secure-hermes && ./setup.sh`). Sandbox-scoped secrets take effect immediately, no recreation needed:

```sh
sbx secret set secure-hermes anthropic
```

**Adding a non-built-in provider** (OpenRouter, self-hosted endpoints, …) requires two changes:

1. **Credential** — use [`sbx secret set-custom`](https://docs.docker.com/ai/sandboxes/security/credentials/#custom-secrets) for an ad-hoc binding, or declare the service in `sandbox/spec.yaml` under `credentials.sources` (see [Kits → Authenticate to external services](https://docs.docker.com/ai/sandboxes/customize/kits/#authenticate-to-external-services)).
2. **Network** — add the provider's domain to `network.allowedDomains` in `sandbox/spec.yaml`.

Recreate the sandbox after either change.

**OAuth.** Run `hermes setup` inside the sandbox and pick Nous Portal.

## Web Search Sanitization

Hermes talks to Firecrawl through `FIRECRAWL_API_URL=http://host.docker.internal:5050`. The proxy intercepts `/v1/*` and `/v2/*`, runs the user-controlled fields through Presidio, and forwards the scrubbed request:

| Route      | Fields scrubbed   |
| ---------- | ----------------- |
| `/search`  | `query`           |
| `/scrape`  | `url`, `prompt`   |
| `/extract` | `urls`, `prompt`  |
| `/crawl`   | `url`, `prompt`   |

Default entities: credit cards, API keys, emails, phone numbers, IP addresses, SSNs, IBANs, people, locations.

Every redaction is logged with the original and scrubbed values so you can audit what would have left the VM:

```sh
docker compose logs -f sanitizer-proxy
```

## Endpoints

- Sanitizer health: <http://localhost:5050/health>
- Firecrawl API: <http://localhost:3002>

Port 5050 is used on the host because macOS AirPlay binds 5000.

## Teardown

```sh
docker compose down        # stop backend
sbx rm secure-hermes       # destroy sandbox
docker compose down -v     # also drop backend volumes
```

## Troubleshooting

- **`agent "hermes" not found`** — Hermes is not an sbx built-in. Use `./setup.sh` (or `sbx run --name secure-hermes --kit ./sandbox shell`).
- **Search returns 404** — rebuild the proxy: `docker compose up -d --build sanitizer-proxy`.
- **Provider call returns 401** — set the host secret (`sbx secret set -g <provider>`) and recreate the sandbox.
- **Weak/no search results** — set `SEARXNG_ENDPOINT` in `.env`; otherwise Firecrawl falls back to rate-limited Google scraping.
