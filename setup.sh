#!/usr/bin/env zsh
# Secure Hermes Sandbox — one-click setup.
#
# Brings up the backend stack (Presidio + Firecrawl + sanitizer proxy) via
# docker compose, waits for it to be healthy, then launches the Hermes
# agent inside a Docker Sandbox (sbx) microVM. Works under zsh and bash.

emulate -L sh 2>/dev/null || true
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

if [ -t 1 ]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[0;33m'
  BLU=$'\033[0;34m'; BLD=$'\033[1m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YLW=""; BLU=""; BLD=""; DIM=""; RST=""
fi

info() { printf "%s[i]%s %s\n" "$BLU" "$RST" "$*"; }
ok()   { printf "%s[+]%s %s\n" "$GRN" "$RST" "$*"; }
warn() { printf "%s[!]%s %s\n" "$YLW" "$RST" "$*"; }
err()  { printf "%s[x]%s %s\n" "$RED" "$RST" "$*" >&2; }
hdr()  { printf "\n%s== %s ==%s\n" "$BLD" "$*" "$RST"; }

abort() { err "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || abort "$2"
}

# ---------------------------------------------------------------------
hdr "Preflight"

require_cmd docker \
  "Docker is not installed. Install Docker Desktop from https://docs.docker.com/desktop/"

if ! docker info >/dev/null 2>&1; then
  abort "Docker daemon is not reachable. Start Docker Desktop and re-run."
fi
ok "Docker daemon reachable"

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  abort "Neither 'docker compose' nor 'docker-compose' is available."
fi
ok "Docker Compose available: ${DC[*]}"

require_cmd sbx \
  "The 'sbx' CLI is not installed. Install it with: brew install docker/tap/sbx (then run: sbx login)"
ok "sbx CLI available: $(sbx --version 2>/dev/null | head -n1 || echo unknown)"

# ---------------------------------------------------------------------
hdr "Workspace bootstrap"

mkdir -p HermesWorkspace
[ -f HermesWorkspace/.gitkeep ] || touch HermesWorkspace/.gitkeep
ok "HermesWorkspace/ ready (mounted into the sandbox at launch)"

if [ ! -f .env ]; then
  cp .env.example .env
  warn ".env created from .env.example — only host-side options for Firecrawl/SearXNG live here."
  warn "LLM provider keys belong on the host keychain via 'sbx secret set -g <service>', NOT in .env."
else
  ok ".env already present (left untouched)"
fi

# ---------------------------------------------------------------------
hdr "Backend services (Presidio + Firecrawl + sanitizer)"

"${DC[@]}" up --build -d

poll_url() {
  local url="$1" max_attempts="$2" label="$3"
  local attempt=1
  while [ "$attempt" -le "$max_attempts" ]; do
    if curl -fsS -o /dev/null --max-time 3 "$url"; then
      ok "$label is healthy ($url)"
      return 0
    fi
    printf "  %swaiting for %s (%d/%d)%s\r" "$DIM" "$label" "$attempt" "$max_attempts" "$RST"
    sleep 2
    attempt=$((attempt + 1))
  done
  printf "\n"
  return 1
}

info "Waiting for the sanitizer proxy to become healthy..."
if ! poll_url "http://localhost:5000/health" 60 "sanitizer-proxy"; then
  err "sanitizer-proxy never became healthy. Last 50 log lines:"
  "${DC[@]}" logs --tail 50 sanitizer-proxy || true
  exit 1
fi

info "Waiting for Firecrawl (best-effort; first boot takes ~30-60s)..."
if ! poll_url "http://localhost:3002/v1/health" 60 "firecrawl"; then
  warn "Firecrawl health check did not pass within 120s."
  warn "The sandbox will still launch; searches may fail until Firecrawl is up."
  warn "Tail logs with: ${DC[*]} logs -f firecrawl"
fi

# ---------------------------------------------------------------------
hdr "Launch Hermes sandbox"

KIT_PATH="$SCRIPT_DIR/sandbox"
WORKSPACE="$SCRIPT_DIR/HermesWorkspace"

info "Sandbox kit:    $KIT_PATH"
info "Workspace mount: $WORKSPACE"
info "Validating kit..."
sbx kit validate "$KIT_PATH"
ok "Kit is valid"

have_secret() { sbx secret ls 2>/dev/null | awk '{print $2}' | grep -qx "$1"; }

CREDS_FOUND=()
for svc in anthropic openai openrouter; do
  if have_secret "$svc"; then CREDS_FOUND+=("$svc"); fi
done

if [ ${#CREDS_FOUND[@]} -gt 0 ]; then
  ok "Host-side credentials detected: ${CREDS_FOUND[*]}"
  ok "Hermes will pick them up automatically (proxy-managed inside the VM)."
else
  warn "No host-side LLM credentials found yet."
  warn "Before Hermes can talk to a model, store a key on the HOST with one of:"
  printf "    %ssbx secret set -g anthropic%s\n" "$BLD" "$RST"
  printf "    %ssbx secret set -g openai%s\n"    "$BLD" "$RST"
  printf "    %ssbx secret set -g openrouter%s\n" "$BLD" "$RST"
  warn "Global secrets only apply at sandbox creation: run \`sbx rm <name>\` and re-run this script after adding one."
fi

cat <<EOF

${BLD}Now launching the Hermes sandbox.${RST}
${DIM}Inside the sandbox:${RST}
  - The env vars ANTHROPIC_API_KEY / OPENAI_API_KEY / OPENROUTER_API_KEY /
    FIRECRAWL_API_KEY all read ${BLD}proxy-managed${RST}. That is correct.
    The real values stay on your host and are injected by the sbx proxy.
  - Web search is already wired through the sanitizer proxy via
    ${BLD}FIRECRAWL_API_URL=http://host.docker.internal:5000${RST}.
  - If you'd rather OAuth into Nous Portal from inside the VM, run
    ${BLD}hermes setup${RST} and pick Nous Portal.

${DIM}From another terminal you can watch redaction events with:${RST}
  ${BLD}${DC[*]} logs -f sanitizer-proxy${RST}

EOF

cd "$WORKSPACE"
exec sbx run --kit "$KIT_PATH" hermes
