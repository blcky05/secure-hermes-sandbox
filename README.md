# Secure Hermes Sandbox

Run [NousResearch Hermes Agent](https://github.com/NousResearch/hermes-agent) inside a Docker Sandbox (`sbx`) microVM, with web access forced through a local sanitizer proxy.

The stack provides:

- A `shell` sandbox named `secure-hermes`.
- A `hermes-secure` sbx mixin that installs Hermes, sets `FIRECRAWL_API_URL`, and pins Hermes' terminal backend to `local`.
- A Hono/TypeScript proxy on `localhost:5050` that scrubs Firecrawl requests with Microsoft Presidio before forwarding to self-hosted Firecrawl.
- Host-side LLM credentials via sbx's built-in credential proxy; keys do not enter the VM.

```
Hermes in sbx
  -> FIRECRAWL_API_URL=http://host.docker.internal:5050
  -> sanitizer-proxy
  -> Presidio analyzer/anonymizer
  -> Firecrawl
```

## Prerequisites

- macOS with Docker Desktop running.
- Docker Sandboxes CLI:

```sh
brew install docker/tap/sbx
sbx login
```

- Around 6 GB free disk for the Firecrawl stack.

## Quick Start

```sh
./setup.sh
```

On first run, this starts the backend services and creates the sandbox with:

```sh
sbx run --name secure-hermes --kit ./sandbox shell
```

Inside the sandbox, start Hermes with:

```sh
hermes
```

The mixin writes Hermes config so terminal/code execution uses the microVM itself:

```yaml
terminal:
  backend: local
```

## Restarting

Any of these restart the same sandbox and preserve its internal state:

```sh
sbx run secure-hermes
./setup.sh
```

You can also use the Docker Sandboxes TUI (`sbx`) and run `secure-hermes` there.

Do not recreate the sandbox unless you intentionally want a fresh VM. `sbx rm secure-hermes` deletes Hermes' internal state (`~/.hermes`, OAuth tokens, memories, history). Files in `HermesWorkspace/` stay on the host.

## Credentials

Set LLM provider keys on the host:

```sh
sbx secret set -g anthropic
sbx secret set -g openai
sbx secret set -g openrouter
```

The built-in `shell` agent already wires these providers through the sbx credential proxy. Inside the sandbox the env vars show `proxy-managed`; that is expected.

If you add a secret after creating the sandbox, recreate the sandbox to pick it up:

```sh
sbx rm secure-hermes
./setup.sh
```

If you prefer OAuth, run `hermes setup` inside the sandbox and pick Nous Portal. That token lives inside the sandbox volume.

## Web Search Sanitization

Hermes uses Firecrawl through:

```sh
FIRECRAWL_API_URL=http://host.docker.internal:5050
```

The proxy supports Firecrawl `/v1/*` and `/v2/*` routes. It scans these request fields before forwarding:

- `/search`: `query`
- `/scrape`: `url`, `prompt`
- `/extract`: `urls`, `prompt`
- `/crawl`: `url`, `prompt`

Presidio currently redacts credit cards, API keys, emails, phone numbers, IP addresses, SSNs, IBANs, people, and locations. Redaction events are logged with the original and scrubbed values so you can audit what would have left the sandbox.

## Observability

CLI logs:

```sh
docker compose logs -f sanitizer-proxy
docker compose logs -f firecrawl
docker compose logs -f sanitizer-proxy firecrawl
```

Docker Desktop:

- Open `docker-desktop://dashboard/logs`
- Or use Docker Desktop -> Containers -> `secure-hermes-sandbox` -> service -> Logs

The Firecrawl API is reachable on:

```sh
http://localhost:3002
```

The sanitizer proxy health endpoint is:

```sh
http://localhost:5050/health
```

## Teardown

Stop backend services:

```sh
docker compose down
```

Destroy the sandbox:

```sh
sbx rm secure-hermes
```

Delete backend volumes too:

```sh
docker compose down -v
```

## Troubleshooting

- `agent "hermes" not found`: use this repo's mixin flow (`sbx run --name secure-hermes --kit ./sandbox shell`). Hermes is installed inside a `shell` sandbox; it is not an sbx built-in agent type.
- Search returns 404: rebuild the proxy with `docker compose up -d --build sanitizer-proxy`; Hermes uses Firecrawl `/v2/*`.
- Search reaches proxy but leaks URL query data: check logs for `field=url` or `field=urls[...]`; scrape/extract/crawl URLs should be scanned.
- Firecrawl search returns weak/no results: configure `SEARXNG_ENDPOINT` in `.env` or accept Firecrawl's default search backend limitations.
- Provider calls return 401: set the host secret with `sbx secret set -g <provider>` and recreate the sandbox.

## Repository Layout

```
secure-hermes-sandbox/
├── setup.sh
├── docker-compose.yml
├── .env.example
├── sandbox/
│   └── spec.yaml
├── sanitizer_proxy/
│   ├── Dockerfile
│   ├── package.json
│   ├── tsconfig.json
│   └── src/
│       └── server.ts
└── HermesWorkspace/
    └── .gitkeep
```
