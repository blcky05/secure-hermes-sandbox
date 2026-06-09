#!/usr/bin/env bash
# refresh-corp-ca.sh
#
# Extracts trusted CA certificates from the host and writes them as a PEM
# bundle to presidio/corp-ca.crt so the Docker build can inject them into
# the presidio-analyzer image.
#
# Strategy (in order of preference):
#   1. WSL / PowerShell available  → export all non-expired certs from the
#      Windows LocalMachine\Root and LocalMachine\CA stores.
#   2. Linux system bundle          → copy /etc/ssl/certs/ca-certificates.crt.
#
# Run this once before `docker compose build` (or `./setup.sh`).
# presidio/corp-ca.crt is gitignored; re-run whenever the host CA store changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_FILE="$SCRIPT_DIR/presidio/corp-ca.crt"
POWERSHELL="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"

if [[ -x "$POWERSHELL" ]]; then
    echo "Detected WSL — exporting CA certificates from Windows certificate store..."
    echo "  Sources : Cert:\\LocalMachine\\Root + Cert:\\LocalMachine\\CA"
    echo "  Filter  : not yet expired"
    echo "  Output  : $OUT_FILE"
    echo ""

    WIN_OUT_FILE="$(wslpath -w "$OUT_FILE")"

    TMPPS1=$(mktemp /mnt/c/Windows/Temp/export-corp-certs-XXXXXX.ps1)
    trap 'rm -f "$TMPPS1"' EXIT

    # Single-quote heredoc: bash variables are NOT expanded; PowerShell variables survive intact.
    cat > "$TMPPS1" << 'PSEOF'
$out = "";
$stores = @("Root", "CA");
foreach ($store in $stores) {
    foreach ($cert in (Get-ChildItem -Path "Cert:\LocalMachine\$store")) {
        if ($cert.NotAfter -gt (Get-Date)) {
            $b64 = [Convert]::ToBase64String($cert.RawData, "InsertLineBreaks");
            $out += "# " + $cert.Subject + "`n-----BEGIN CERTIFICATE-----`n" + $b64 + "`n-----END CERTIFICATE-----`n`n"
        }
    }
}
if ($out -eq "") { Write-Error "No certificates found in LocalMachine store"; exit 1 }
OUTFILE_PLACEHOLDER
$count = ($out -split "BEGIN CERTIFICATE").Count - 1;
Write-Host "Exported $count certificate(s)"
PSEOF

    WIN_TMPPS1="$(wslpath -w "$TMPPS1")"
    sed -i "s|OUTFILE_PLACEHOLDER|\[System.IO.File\]::WriteAllText('${WIN_OUT_FILE//\\/\\\\}', \$out);|" "$TMPPS1"

    "$POWERSHELL" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$WIN_TMPPS1"

else
    echo "PowerShell not found — falling back to system CA bundle."
    SYSTEM_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
    if [[ ! -f "$SYSTEM_BUNDLE" ]]; then
        echo "ERROR: $SYSTEM_BUNDLE not found. Cannot extract CA certificates." >&2
        exit 1
    fi
    cp "$SYSTEM_BUNDLE" "$OUT_FILE"
    COUNT=$(grep -c "BEGIN CERTIFICATE" "$OUT_FILE")
    echo "Copied $COUNT certificate(s) from $SYSTEM_BUNDLE → $OUT_FILE"
fi

echo ""
echo "Verifying bundle..."
if command -v openssl &>/dev/null; then
    COUNT=$(grep -c "BEGIN CERTIFICATE" "$OUT_FILE" || true)
    echo "  $COUNT certificate(s) in $OUT_FILE — OK"
fi
echo ""
echo "Done. Run 'docker compose build presidio-analyzer' (or './setup.sh') to apply."
