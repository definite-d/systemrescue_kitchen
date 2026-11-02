#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="$SCRIPT_DIR/input"
OUTPUT_DIR="$SCRIPT_DIR/output"
RECIPE_DIR="$SCRIPT_DIR/recipe"
EXT_LIST="$SCRIPT_DIR/extensions.txt"
WORK_DIR="/tmp/sysrescue-build-$$"

# 1. Dependency checks
for cmd in sysrescue-customize curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[-] Error: Required tool '$cmd' is not installed."
        exit 1
    fi
done

# 2. Pick latest ISO
LATEST_ISO="$(find "$INPUT_DIR" -maxdepth 1 -type f -name "systemrescue-*.iso" | sort -V | tail -n 1)"
if [[ -z "$LATEST_ISO" ]]; then
    echo "[-] No ISO found in $INPUT_DIR. Please place an official SystemRescue ISO there."
    exit 1
fi

ISO_BASENAME="$(basename "$LATEST_ISO" .iso)"
OUTPUT_ISO="$OUTPUT_DIR/${ISO_BASENAME}-custom-$(date +%Y%m%d).iso"
mkdir -p "$OUTPUT_DIR"

# 3. Setup workspace & cleanup
mkdir -p "$WORK_DIR/iso_add"
cleanup() {
    echo "[*] Cleaning temporary workspace..."
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# 4. Copy static recipe overlay
echo "[*] Staging base customizations..."
if [[ -d "$RECIPE_DIR/airootfs" ]]; then
    cp -a "$RECIPE_DIR/airootfs/." "$WORK_DIR/iso_add/"
fi

# 5. Resolve and download Firefox extensions
POLICIES_DIR="$WORK_DIR/iso_add/usr/lib/firefox/distribution"
EXT_TARGET_DIR="$WORK_DIR/iso_add/usr/lib/firefox/browser/extensions"
mkdir -p "$POLICIES_DIR" "$EXT_TARGET_DIR"

# Base policies structure
POLICIES_JSON='{
  "policies": {
    "DisableAppUpdate": true,
    "ExtensionSettings": {
      "*": { "installation_mode": "allowed" }
    },
    "Preferences": {
      "general.smoothScroll": true,
      "layout.css.prefers-color-scheme.content-override": 0
    }
  }
}'

if [[ -f "$EXT_LIST" ]]; then
    echo "[*] Processing Firefox extensions from $EXT_LIST..."
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip comments and empty lines
        line="$(echo "$line" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue

        # Extract slug from URL or bare name
        SLUG="$(echo "$line" | sed -E 's|.*/addon/([^/?#]+).*|\1|')"
        echo "  -> Fetching metadata for '$SLUG'..."

        META_JSON="$(curl -sSL "https://addons.mozilla.org/api/v5/addons/addon/${SLUG}/")"
        
        GUID="$(echo "$META_JSON" | jq -r '.guid // empty')"
        DOWNLOAD_URL="$(echo "$META_JSON" | jq -r '.current_version.file.url // empty')"

        if [[ -z "$GUID" || -z "$DOWNLOAD_URL" ]]; then
            echo "  [!] Warning: Failed to resolve extension '$SLUG'. Skipping."
            continue
        fi

        XPI_NAME="${GUID}.xpi"
        echo "  -> Downloading: $XPI_NAME"
        curl -sSL "$DOWNLOAD_URL" -o "$EXT_TARGET_DIR/$XPI_NAME"

        # URL-encode curly braces for file:// scheme if present
        ENCODED_XPI="$(echo "$XPI_NAME" | sed -e 's/{/%7B/g' -e 's/}/%7D/g')"

        # Inject into ExtensionSettings using jq
        POLICIES_JSON="$(echo "$POLICIES_JSON" | jq \
            --arg guid "$GUID" \
            --arg url "file:///usr/lib/firefox/browser/extensions/$ENCODED_XPI" \
            '.policies.ExtensionSettings[$guid] = {
                "installation_mode": "force_installed",
                "install_url": $url
            }')"

    done < "$EXT_LIST"
fi

# Write out the rendered policies.json
echo "$POLICIES_JSON" | jq '.' > "$POLICIES_DIR/policies.json"

# 6. Set correct permissions
chmod -R u=rwX,go=rX "$WORK_DIR/iso_add/"
chmod 700 "$WORK_DIR/iso_add/root" 2>/dev/null || true

# 7. Invoke sysrescue-customize
echo "[*] Building ISO with sysrescue-customize..."
sudo sysrescue-customize \
    --source="$LATEST_ISO" \
    --dest="$OUTPUT_ISO" \
    --recipe-dir="$WORK_DIR"

echo "[✓] Build complete: $OUTPUT_ISO"