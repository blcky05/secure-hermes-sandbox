# Secure Hermes Sandbox

Run [NousResearch Hermes Agent](https://github.com/NousResearch/hermes-agent) inside a Docker Sandbox (`sbx`) microVM, with web access forced through a local sanitizer proxy.

The stack provides:

- A `shell` sandbox named `secure-hermes`.
- A `hermes-secure` sbx mixin that installs Hermes, sets `FIRECRAWL_API_URL`, and pins Hermes' terminal backend to `local`.
- A local Flask proxy on `localhost:5050` that scrubs Firecrawl requests with Microsoft Presidio before forwarding to self-hosted Firecrawl.
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
sbx start secure-hermes
./setup.sh
```

You can also use the Docker Sandboxes TUI (`sbx`) and start `secure-hermes` there.

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
- Or use Docker Desktop → Containers → `secure-hermes-sandbox` → service → Logs

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
│   ├── requirements.txt
│   └── app.py
└── HermesWorkspace/
    └── .gitkeep
```
# Secure Hermes Sandbox

One-click deployment of the [NousResearch Hermes Agent](https://github.com/NousResearch/hermes-agent) inside a Docker Sandbox (`sbx`) microVM. Two security boundaries are layered on top of stock Hermes:

1. **Web search is scrubbed.** Hermes' built-in Firecrawl backend is pointed at a local Microsoft Presidio proxy that strips PII, credit cards, and API keys from queries before they hit Firecrawl.
2. **LLM provider keys never enter the VM.** The host-side `sbx` credential proxy injects them into outbound requests; inside the sandbox the env vars read `proxy-managed`.

```
+--------------------------+   host.docker.internal:5050  +-------------------+
|  Hermes (sbx microVM)    |  --------------------------> |  sanitizer-proxy  |
|  FIRECRAWL_API_URL=...   |    (Firecrawl-compatible)    |  Flask host :5050 |
|  Default-deny network    |                              +---------+---------+
+--------------+-----------+                                         |
               |  outbound LLM calls                                 |  analyze/anonymize
               v                                                     v
   sbx host-side credential proxy                        +----------------------------+
   (rewrites Authorization header                        |  presidio-analyzer  :5001  |
    with secret from host keychain)                      |  presidio-anonymizer :5002 |
               |                                         +----------------------------+
               v                                                      |
        api.anthropic.com / api.openai.com /                          v  forward scrubbed query
        openrouter.ai (allow-listed)                       +---------------------------+
                                                           | firecrawl (self-hosted)   |
                                                           | + redis + playwright +    |
                                                           |   rabbitmq + postgres     |
                                                           +---------------------------+
```

## What gets scrubbed

The sanitizer proxy uses [Microsoft Presidio](https://microsoft.github.io/presidio/) to detect and redact:

- Credit card numbers (`CREDIT_CARD`)
- Emails (`EMAIL_ADDRESS`), phone numbers (`PHONE_NUMBER`), IP addresses, US SSNs, IBANs
- People and locations (`PERSON`, `LOCATION`)
- API keys (`API_KEY`) — custom recognizer matches `sk-[A-Za-z0-9]{20,}` and `sk-ant-...`

Redactions are logged at WARNING level with a `PII REDACTED` line containing the original and the scrubbed query so you can audit what would have left the box.

## Prerequisites

- macOS with **Docker Desktop** running.
- The **`sbx`** CLI ([Docker AI Sandboxes](https://docs.docker.com/ai/sandboxes/)):

  ```sh
  brew install docker/tap/sbx
  sbx login
  ```

- Roughly 6 GB free disk for the Firecrawl stack on first boot.

## Quick start

```sh
git clone <this-repo> secure-hermes-sandbox
cd secure-hermes-sandbox
./setup.sh
```

`setup.sh` brings up the backend (Presidio + Firecrawl + sanitizer), waits for it to be healthy, then runs:

```sh
sbx run --name secure-hermes --kit ./sandbox shell
```

The kit is a [mixin](https://docs.docker.com/ai/sandboxes/customize/kit-examples/) (`kind: mixin`) layered on top of the built-in `shell` agent. The mixin only contributes Hermes-specific bits: the install command, `FIRECRAWL_API_URL`, the extra `allowedDomains` (sanitizer proxy + Nous Portal + install-time CDNs), and a one-shot post-install step that pins Hermes' [`terminal.backend`](https://hermes-agent.nousresearch.com/docs/user-guide/configuration) to `local`. We don't want Hermes spinning up a nested Docker container for tool calls — the sbx microVM is already the sandbox boundary. LLM credentials (`anthropic`, `openai`, `openrouter`) are already wired by the `shell` base, so the mixin doesn't redeclare them. The base agent stays `shell`, which is what makes `sbx start` and the TUI work cleanly for restart — sbx restart paths only know about built-in agent types.

Inside the sandbox you land at a bash prompt. Type `hermes` to start the agent. Web search, env vars, and provider credentials are already wired through the mixin — there's nothing to configure on the inside.

### Restarting

Any of these work:

```sh
sbx start secure-hermes      # CLI
./setup.sh                   # idempotent: detects the existing sandbox and `sbx start`s it
```

…or open `sbx` (the TUI), find `secure-hermes`, hit `enter`. All three preserve the persistent volume (Hermes' memory, installed deps, OAuth tokens).

## Provider credentials — set them on the HOST, not in the sandbox

This is the secure path. The `shell` base agent has built-in credential wiring for the major providers (`anthropic`, `openai`, `openrouter`, and others — see the [Docker credentials docs](https://docs.docker.com/ai/sandboxes/security/credentials/)). Pick whichever you want to use and run one of:

```sh
sbx secret set -g anthropic     # prompts for the value
sbx secret set -g openai
sbx secret set -g openrouter
```

These land in your macOS keychain. Inside the sandbox the matching env var (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`) shows up as `proxy-managed`. When Hermes hits `api.anthropic.com` / `api.openai.com` / `openrouter.ai`, the host-side credential proxy rewrites the auth header with the real secret. The agent never sees it.

Once you've added a secret, the sandbox needs to be recreated to pick it up — global secrets only apply at sandbox creation per the [credentials docs](https://docs.docker.com/ai/sandboxes/security/credentials/). **Read the next section before you `sbx rm`**: recreating wipes Hermes' memory.

You can list and remove secrets with:

```sh
sbx secret ls
sbx secret rm -g openrouter
```

## What survives a sandbox recreate

Per the [Docker Sandboxes usage docs](https://docs.docker.com/ai/sandboxes/usage/#what-persists), `sbx rm` deletes the entire microVM and everything inside it. `persistence: persistent` in the kit only keeps state across `sbx stop` / `sbx start` of the **same** sandbox, not across `sbx rm`.

| Survives `sbx rm`? | What                                                                             | Where                                                |
| ------------------ | -------------------------------------------------------------------------------- | ---------------------------------------------------- |
| Yes                | Files you dropped in `HermesWorkspace/`                                          | Host bind mount                                      |
| Yes                | Host secrets stored via `sbx secret set`                                         | macOS keychain                                       |
| Yes                | Backend stack data (Firecrawl indexes, redis, etc.)                              | Docker named volumes managed by `docker-compose.yml` |
| **No**             | Hermes' memory, auto-created skills, conversation history                        | `~/.hermes/` inside the sandbox volume               |
| **No**             | Nous Portal OAuth token (if you used `hermes setup` instead of `sbx secret set`) | `~/.hermes/` inside the sandbox volume               |
| **No**             | Anything else under `/home/agent/` outside the workspace bind                    | Sandbox volume                                       |

If you need to change something **without losing memory**, pick the lightest option that fits your change:

1. **Just allowing a new domain — no recreate needed.** Use the `sbx` TUI's network panel (run `sbx`, press `tab` to the network panel) or the CLI:

   ```sh
   sbx policy allow network -g api.groq.com:443
   ```

   This applies immediately to running sandboxes; nothing reinstalls, nothing reboots. Use this when an LLM call or a tool failed with a blocked-domain error and you just need to open one host.

2. **Layer a full kit change onto the running sandbox.** When you've edited `spec.yaml` (added install commands, env vars, static files, etc.) and want the changes applied without recreating, run:

   ```sh
   sbx kit add secure-hermes ./sandbox
   ```

   This re-runs install commands and re-copies static files. Caveat: network/credential changes interact with the base agent's wiring — for `allowedDomains` additions option 1 above is enough; for anything else, a fresh sandbox (options 3 or 4 below) is the cleanest path.

3. **Snapshot, then recreate.** Save the configured sandbox as a template image, remove the sandbox, and start a fresh one from the saved template (also re-applies the kit on top):

   ```sh
   sbx stop secure-hermes
   sbx template save secure-hermes hermes-state:v1
   sbx rm secure-hermes
   sbx run --name secure-hermes --template hermes-state:v1 --kit ./sandbox shell
   ```

4. **Copy memory out and back.** One-shot escape hatch when you don't want a template:

   ```sh
   sbx cp <sandbox-name>:/home/agent/.hermes ./.hermes-backup
   sbx rm <sandbox-name>
   ./setup.sh                                # boots a fresh sandbox
   sbx cp ./.hermes-backup <new-sandbox-name>:/home/agent/.hermes
   ```

If you don't care about memory, the simple flow still works:

```sh
sbx ls
sbx rm <sandbox-name>
./setup.sh
```

### Alternative: OAuth via `hermes setup` (Nous Portal)

If you prefer OAuth and are happy for the (short-lived) token to live inside the sandbox volume, just run `hermes setup` inside the sandbox and pick Nous Portal. The token is stored under `~/.hermes/` in the persistent sandbox volume. The kit already allow-lists `portal.nousresearch.com` and `inference-api.nousresearch.com`.

Trade-off: OAuth means a token sits in the sandbox filesystem. The `sbx secret set` flow keeps the secret entirely on the host.

## Adding another provider

The `shell` base agent supports the built-in service identifiers listed in the [Docker credentials docs](https://docs.docker.com/ai/sandboxes/security/credentials/) (`anthropic`, `openai`, `openrouter`, `groq`, `mistral`, `google`, `nebius`, `xai`, `github`, `aws`). For any of those, the secure path is:

```sh
sbx secret set -g <provider>       # e.g. groq
sbx rm secure-hermes && ./setup.sh # recreate so the new secret is picked up
```

For a provider that isn't in that built-in list, or if you want to add a one-off host without a credential, the quick path is to allow the domain at runtime and let Hermes read the key from `~/.hermes/.env`:

```sh
sbx policy allow network -g api.example.com:443
```

(Inside the sandbox, then run `hermes setup` or `hermes config set ...`. The key lives in the sandbox volume rather than your host keychain — fine for dev, weaker isolation.)

## Observing redactions

In another terminal:

```sh
docker compose logs -f sanitizer-proxy
```

Trigger a search or scrape URL that contains a fake credit card or `sk-...` key. You should see:

```
WARNING sanitizer-proxy PII REDACTED before Firecrawl. endpoint=v1/search field=query
  findings=[{'entity_type': 'API_KEY', 'score': 0.9}, {'entity_type': 'CREDIT_CARD', 'score': 1.0}]
  | original='leak sk-AAAA... 4242 4242 4242 4242'
  | scrubbed='leak <API_KEY> <CREDIT_CARD>'
```

For scrape/extract/crawl requests the proxy also scans URL fields (`url`, `urls`) before forwarding.

## Working with files

Anything you drop in `HermesWorkspace/` on macOS shows up immediately inside the sandbox at the current working directory, and anything Hermes writes there appears on your host.

## Teardown

```sh
sbx ls                 # find the sandbox name
sbx rm <sandbox-name>  # destroy the sandbox
docker compose down    # stop backend services
docker compose down -v # also delete Firecrawl/redis/rabbitmq/postgres volumes
```

## Troubleshooting

| Symptom                                   | Likely cause                                       | Fix                                                                                |
| ----------------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `sbx: command not found`                  | `sbx` CLI not installed                            | `brew install docker/tap/sbx`                                                      |
| LLM call returns 401 / auth error         | No credential stored for the provider you're using | `sbx secret set -g <service>` then recreate the sandbox                            |
| LLM call hangs or times out               | Provider domain not on `allowedDomains`            | Check `sbx policy log`; add domain to `sandbox/spec.yaml`                          |
| Hermes searches fail                      | Sanitizer proxy not healthy                        | `docker compose logs sanitizer-proxy`                                              |
| Firecrawl `/v1/search` returns no results | Default backend (Google) blocked or rate-limited   | Run a local SearXNG and set `SEARXNG_ENDPOINT` in `.env`, then restart `firecrawl` |
| Redaction not logged                      | Query contained nothing Presidio recognises        | Try `sk-AAAAAAAAAAAAAAAAAAAA` or `4242 4242 4242 4242`                             |

## Repository layout

```
secure-hermes-sandbox/
├── setup.sh                    # One-click setup
├── docker-compose.yml          # Presidio + Firecrawl + sanitizer
├── .env.example                # Host-side env template (not for LLM keys)
├── README.md
├── sandbox/
│   └── spec.yaml               # sbx mixin (kind: mixin) layered on `shell`
├── sanitizer_proxy/            # Firecrawl-shaped Flask proxy
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app.py
└── HermesWorkspace/            # Bind-mounted into the sandbox
    └── .gitkeep
```

## Security notes

- **LLM keys**: stored only in the host macOS keychain via `sbx secret set`. The sandbox sees the literal string `proxy-managed`.
- **Search**: Hermes' `web_search`, `web_extract`, `web_crawl` tools call `$FIRECRAWL_API_URL`. Since the sandbox is default-deny and the only allow-listed search-shaped host is the sanitizer, the agent has no path around it.
- **Sandbox**: microVM with hardware-level isolation. Even a compromised agent process cannot reach the host's local network unless a domain is on `allowedDomains`.
- **Proxy port**: published on `localhost:5050` only (host port `5050` → container port `5000`; `5000` is avoided because macOS AirPlay Receiver binds it by default).
- **Persistence**: `persistence: persistent` in the kit keeps Hermes' state across `sbx stop` / `sbx start` of the **same** sandbox. `sbx rm` destroys the VM and its volume; only `HermesWorkspace/` survives. See [What survives a sandbox recreate](#what-survives-a-sandbox-recreate) for ways to keep memory across kit edits.
