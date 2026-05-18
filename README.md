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

`setup.sh` brings up the backend (Presidio + Firecrawl + sanitizer), waits for it to be healthy, then `sbx run --kit ./sandbox hermes` mounted on `HermesWorkspace/`. Hermes' `FIRECRAWL_API_URL` is already pointed at the sanitizer in the kit — there's nothing to configure inside the sandbox to make web search safe.

## Provider credentials — set them on the HOST, not in the sandbox

This is the secure path. The kit declares three providers (`anthropic`, `openai`, `openrouter`); pick whichever you want to use and run one of:

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

| Survives `sbx rm`? | What | Where |
| --- | --- | --- |
| Yes | Files you dropped in `HermesWorkspace/` | Host bind mount |
| Yes | Host secrets stored via `sbx secret set` | macOS keychain |
| Yes | Backend stack data (Firecrawl indexes, redis, etc.) | Docker named volumes managed by `docker-compose.yml` |
| **No** | Hermes' memory, auto-created skills, conversation history | `~/.hermes/` inside the sandbox volume |
| **No** | Nous Portal OAuth token (if you used `hermes setup` instead of `sbx secret set`) | `~/.hermes/` inside the sandbox volume |
| **No** | Anything else under `/home/agent/` outside the workspace bind | Sandbox volume |

If you need to change something **without losing memory**, pick the lightest option that fits your change:

1. **Just allowing a new domain — no recreate needed.** Use the `sbx` TUI's network panel (run `sbx`, press `tab` to the network panel) or the CLI:

   ```sh
   sbx policy allow network -g api.groq.com:443
   ```

   This applies immediately to running sandboxes; nothing reinstalls, nothing reboots. Use this when an LLM call or a tool failed with a blocked-domain error and you just need to open one host.

2. **Layer a full kit change onto the running sandbox.** When you've edited `spec.yaml` (added install commands, env vars, static files, etc.) and want the changes applied without recreating, run:

   ```sh
   sbx kit add <sandbox-name> ./sandbox
   ```

   This re-runs install commands and re-copies static files. Caveat: `serviceDomains`, `serviceAuth`, and `credentials.sources` are part of the kit's network/credential model — if you're adding **proxy-managed credential injection** for a brand-new provider, the cleanest way to be sure it takes effect is still a fresh sandbox (options 3 or 4 below). For pure `allowedDomains` additions, option 1 above is enough.

3. **Snapshot, then recreate.** Save the configured sandbox as a template image, remove the sandbox, and start a fresh one from the saved template (also re-applies the kit on top):

   ```sh
   sbx stop <sandbox-name>
   sbx template save <sandbox-name> hermes-state:v1
   sbx rm <sandbox-name>
   sbx run --template hermes-state:v1 --kit ./sandbox hermes
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

The kit ships with Anthropic / OpenAI / OpenRouter / Nous Portal. To add another (Groq, Mistral, Google, etc.) you have two paths depending on how much credential isolation you want:

### Quick path (key lives inside the sandbox)

Best when you just want to try a provider and don't mind pasting the key into Hermes:

```sh
sbx policy allow network -g api.groq.com:443     # or the host you need
```

Then inside the sandbox, `hermes setup` (or `hermes config set GROQ_API_KEY ...`) writes the key to `~/.hermes/.env`. No kit edit, no recreate. The key now lives in the sandbox volume — fine for development, but it's the weaker of the two threat models.

### Secure path (key stays on the host)

When you want the proxy to inject the credential so the agent never sees it:

1. Add the API host to `sandbox/spec.yaml` → `allowedDomains`.
2. Add a `serviceDomains` mapping and a `serviceAuth` block (header + value format) for that provider.
3. Add a `credentials.sources` entry pointing at the host env var Hermes uses for that provider (see the [Hermes env var reference](https://hermes-agent.nousresearch.com/docs/reference/environment-variables/)).
4. Add the env var name to `environment.proxyManaged`.
5. `sbx secret set -g <your-service-id>`, then recreate the sandbox so the new `serviceDomains` / `credentials.sources` wiring takes effect. See [What survives a sandbox recreate](#what-survives-a-sandbox-recreate) for how to keep Hermes' memory across the recreate.

The [Docker credentials docs](https://docs.docker.com/ai/sandboxes/security/credentials/) list built-in service identifiers you can re-use (`anthropic`, `openai`, `groq`, `mistral`, `google`, `nebius`, `xai`, `github`, `aws`).

## Observing redactions

In another terminal:

```sh
docker compose logs -f sanitizer-proxy
```

Trigger a search that contains a fake credit card or `sk-...` key. You should see:

```
WARNING sanitizer-proxy PII REDACTED before Firecrawl. endpoint=v1/search field=query
  findings=[{'entity_type': 'API_KEY', 'score': 0.9}, {'entity_type': 'CREDIT_CARD', 'score': 1.0}]
  | original='leak sk-AAAA... 4242 4242 4242 4242'
  | scrubbed='leak <API_KEY> <CREDIT_CARD>'
```

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

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `sbx: command not found` | `sbx` CLI not installed | `brew install docker/tap/sbx` |
| LLM call returns 401 / auth error | No credential stored for the provider you're using | `sbx secret set -g <service>` then recreate the sandbox |
| LLM call hangs or times out | Provider domain not on `allowedDomains` | Check `sbx policy log`; add domain to `sandbox/spec.yaml` |
| Hermes searches fail | Sanitizer proxy not healthy | `docker compose logs sanitizer-proxy` |
| Firecrawl `/v1/search` returns no results | Default backend (Google) blocked or rate-limited | Run a local SearXNG and set `SEARXNG_ENDPOINT` in `.env`, then restart `firecrawl` |
| Redaction not logged | Query contained nothing Presidio recognises | Try `sk-AAAAAAAAAAAAAAAAAAAA` or `4242 4242 4242 4242` |

## Repository layout

```
secure-hermes-sandbox/
├── setup.sh                    # One-click setup
├── docker-compose.yml          # Presidio + Firecrawl + sanitizer
├── .env.example                # Host-side env template (not for LLM keys)
├── README.md
├── sandbox/
│   └── spec.yaml               # sbx agent kit (kit-only, no Dockerfile)
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
