# Secure Hermes Sandbox — Operating Environment

You are running inside a Docker Sandbox microVM with strict egress controls.
Read this before reaching for any tool that touches the network.

## What you can do

- **Use `web_search` and `web_extract`** for any web access. They route through
  `FIRECRAWL_API_URL=http://host.docker.internal:5050`, a host-side sanitizer
  proxy that scans request fields with Microsoft Presidio and strips the
  following entity types before forwarding to a self-hosted Firecrawl instance:
  credit cards, API keys, emails, phone numbers, US SSNs, IBANs, IP addresses,
  people, and locations.
- **Use the `terminal`, `file`, and `execute_code` tools normally.** They run
  inside this microVM with `terminal.backend: local`.

## What will not work

- **Direct internet access is blocked.** The microVM's network policy only
  permits `host.docker.internal:5050` (the sanitizer proxy) plus a small set of
  package/auth endpoints needed for the Hermes installer itself. Arbitrary
  `curl` / `wget` / `requests.get(...)` to the open internet will fail.
- **Interactive browser tools (`browser_navigate`, `browser_snapshot`,
  `browser_vision`) are disabled.** There is no Chromium installed in the VM,
  and routing browser traffic through the proxy is not yet supported.

## Credentials

LLM provider keys (Anthropic, OpenAI, Google, …) live on the host keychain
and are injected into outbound API requests by sbx's credential proxy. Inside
this VM the corresponding env vars read `proxy-managed`; that is expected.
Never try to print, copy, or override these values — the real key never enters
the VM.

## If a web fetch fails

1. Prefer reformulating the query for `web_search` / `web_extract` — the
   sanitizer may have redacted a field that looked like PII (credit-card-shaped
   query tokens, IP-looking strings, etc.). Check whether the original input
   contains data that would trigger a Presidio match.
2. If you need a host that is currently blocked, ask the user to add the
   domain to `sandbox/spec.yaml`'s `network.allowedDomains` and recreate the
   sandbox (`sbx rm secure-hermes && ./setup.sh`).
