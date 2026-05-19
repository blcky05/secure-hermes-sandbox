#!/usr/bin/env zsh
# One-click setup: backend stack + Hermes sandbox.

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

expand_path() {
  local raw="$1"
  case "$raw" in
    "~") raw="$HOME" ;;
    "~/"*) raw="$HOME/${raw#\~/}" ;;  # \~ to defeat zsh tilde expansion inside ${#…}
  esac
  [[ "$raw" = /* ]] || raw="$SCRIPT_DIR/$raw"
  print -r -- "${raw:A}"
}

choose_workspace() {
  local default_workspace="$HOME/secure-hermes-workspace"
  local input candidate parent

  if [ -n "${HERMES_WORKSPACE:-}" ]; then
    candidate="$(expand_path "$HERMES_WORKSPACE")"
    info "Using HERMES_WORKSPACE=$candidate"
    WORKSPACE="$candidate"
    return 0
  fi

  while true; do
    if [ -t 0 ]; then
      printf "Workspace directory [%s]: " "$default_workspace"
      IFS= read -r input
    else
      input=""
    fi

    [ -n "$input" ] || input="$default_workspace"
    candidate="$(expand_path "$input")"
    parent="$(dirname "$candidate")"

    if [ ! -d "$parent" ]; then
      err "Parent directory '$parent' does not exist."
    elif [ ! -w "$parent" ]; then
      err "Parent directory '$parent' is not writable."
    else
      WORKSPACE="$candidate"
      return 0
    fi

    [ -t 0 ] || exit 1
  done
}

seed_workspace() {
  local src="$SCRIPT_DIR/workspace-template"
  [ -d "$src" ] || return 0

  local seeded=0 f rel dest
  while IFS= read -r f; do
    rel="${f#$src/}"
    dest="$WORKSPACE/$rel"
    if [ ! -e "$dest" ]; then
      mkdir -p "$(dirname "$dest")"
      cp "$f" "$dest"
      seeded=$((seeded + 1))
    fi
  done < <(find "$src" -type f)

  if [ "$seeded" -gt 0 ]; then
    info "Seeded $seeded template file(s) into $WORKSPACE (existing files left untouched)"
  fi
}

existing_sandbox_workspace() {
  local sandbox_name="$1"
  sbx ls 2>/dev/null | awk -v name="$sandbox_name" '
    NR > 1 && $1 == name {
      start = (NF >= 5 ? 5 : 4)
      for (i = start; i <= NF; i++) printf "%s%s", (i == start ? "" : " "), $i
      print ""
    }
  '
}

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

hdr "Workspace bootstrap"

choose_workspace
mkdir -p "$WORKSPACE"
seed_workspace
ok "$WORKSPACE ready (mounted into the sandbox at launch)"

if [ ! -f .env ]; then
  cp .env.example .env
  warn ".env created from .env.example — only host-side options for Firecrawl/SearXNG live here."
  warn "LLM provider keys belong on the host keychain via 'sbx secret set -g <service>', NOT in .env."
else
  ok ".env already present (left untouched)"
fi

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
if ! poll_url "http://localhost:5050/health" 60 "sanitizer-proxy"; then
  err "sanitizer-proxy never became healthy. Last 50 log lines:"
  "${DC[@]}" logs --tail 50 sanitizer-proxy || true
  exit 1
fi

info "Waiting for Firecrawl (best-effort; first boot takes ~30-60s)..."
# Firecrawl has no /health route; the root `/` returns 200 once the API is ready.
if ! poll_url "http://localhost:3002/" 60 "firecrawl"; then
  warn "Firecrawl health check did not pass within 120s."
  warn "The sandbox will still launch; searches may fail until Firecrawl is up."
  warn "Tail logs with: ${DC[*]} logs -f firecrawl"
fi

hdr "Launch Hermes sandbox"

KIT_PATH="$SCRIPT_DIR/sandbox"

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

${BLD}Now launching the sandbox (shell agent + Hermes mixin).${RST}
${DIM}Inside the sandbox:${RST}
  - You land at a bash prompt. Type ${BLD}hermes${RST} to start the agent.
  - ANTHROPIC_API_KEY / OPENAI_API_KEY / OPENROUTER_API_KEY / FIRECRAWL_API_KEY
    all read ${BLD}proxy-managed${RST} — that is correct. The real values stay
    on your host and are injected by the sbx credential proxy.
  - Web search is wired through the sanitizer proxy via
    ${BLD}FIRECRAWL_API_URL=http://host.docker.internal:5050${RST}.
  - For OAuth instead of host-side keys, run ${BLD}hermes setup${RST} and pick
    Nous Portal.

${DIM}Restart later with:${RST} ${BLD}sbx run secure-hermes${RST} (or the sbx TUI, or ./setup.sh)
${DIM}Tail redaction events with:${RST} ${BLD}${DC[*]} logs -f sanitizer-proxy${RST}

EOF

cd "$WORKSPACE"
# Kit is `kind: mixin` layered on top of the built-in `shell` agent.
# Positional arg = built-in agent type (`shell`), NOT the mixin name.
# Default sandbox name is `shell-<workdir>`; we pin it to avoid collisions
# with other shell-based sandboxes the user may have.
SANDBOX_NAME="secure-hermes"

if sbx ls 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$SANDBOX_NAME"; then
  EXISTING_WORKSPACE="$(existing_sandbox_workspace "$SANDBOX_NAME")"
  if [ -n "$EXISTING_WORKSPACE" ] && [ "${EXISTING_WORKSPACE:A}" != "${WORKSPACE:A}" ]; then
    err "Sandbox '$SANDBOX_NAME' already exists with workspace:"
    err "  $EXISTING_WORKSPACE"
    err "Requested workspace:"
    err "  $WORKSPACE"
    err "Run with that existing workspace, or remove the sandbox first: sbx rm $SANDBOX_NAME"
    exit 1
  fi
  ok "Sandbox '$SANDBOX_NAME' exists — attaching (preserves Hermes memory and installed deps)."
  exec sbx run "$SANDBOX_NAME"
else
  exec sbx run --name "$SANDBOX_NAME" --kit "$KIT_PATH" shell
fi
