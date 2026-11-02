#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="$SCRIPT_DIR/input"
OUTPUT_DIR="$SCRIPT_DIR/output"
RECIPE_DIR="$SCRIPT_DIR/recipe"
EXT_LIST="$SCRIPT_DIR/extensions.txt"

# Use colors only when writing to a terminal.
if [[ -t 1 ]]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    CYAN=$'\033[96m'
    RESET=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' RESET=''
fi

info()    { printf '%s[*]%s %s\n' "$CYAN" "$RESET" "$*"; }
success() { printf '%s[✓]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()    { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*"; }
error()   { printf '%s[-]%s %s\n' "$RED" "$RESET" "$*" >&2; }

# Check dependencies before using curl, xargs, or sudo.
required_tools=(curl jq mksquashfs rsync xorriso xargs sudo)
missing_tools=()

for cmd in "${required_tools[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing_tools+=("$cmd")
done

if ((${#missing_tools[@]})); then
    error "Missing required command(s): ${missing_tools[*]}"

    if [[ -f /etc/arch-release ]]; then
        packages=()
        declare -A seen_packages=()

        for cmd in "${missing_tools[@]}"; do
            case "$cmd" in
                mksquashfs) package=squashfs-tools ;;
                xorriso)    package=libisoburn ;;
                xargs)      package=findutils ;;
                *)          package="$cmd" ;;
            esac

            if [[ -z "${seen_packages[$package]+x}" ]]; then
                packages+=("$package")
                seen_packages["$package"]=1
            fi
        done

        printf '    Install with: %ssudo pacman -S --needed' "$CYAN"
        printf ' %q' "${packages[@]}"
        printf '%s\n' "$RESET"
    else
        printf "    Install the missing commands using your distribution's package manager.\n"
    fi

    exit 1
fi

# Prefer a system executable, then an existing bundled copy.
CUSTOMIZE_BIN="$(command -v sysrescue-customize 2>/dev/null || true)"

if [[ -z "$CUSTOMIZE_BIN" ]]; then
    CUSTOMIZE_BIN="$SCRIPT_DIR/bin/sysrescue-customize"

    if [[ ! -x "$CUSTOMIZE_BIN" ]] || ! bash -n "$CUSTOMIZE_BIN" 2>/dev/null; then
        info "Bundled sysrescue-customize is missing or invalid; fetching it..."
        mkdir -p "$SCRIPT_DIR/bin"

        tmp_bin="$(mktemp "$SCRIPT_DIR/bin/.sysrescue-customize.XXXXXX")"
        if curl -fsSL --retry 3 \
            "https://gitlab.com/systemrescue/systemrescue-sources/-/raw/main/airootfs/usr/share/sysrescue/bin/sysrescue-customize?inline=false" \
            -o "$tmp_bin" &&
           bash -n "$tmp_bin" 2>/dev/null; then
            chmod +x "$tmp_bin"
            mv -f -- "$tmp_bin" "$CUSTOMIZE_BIN"
        else
            rm -f -- "$tmp_bin"
            error "Failed to download a valid sysrescue-customize script."
            exit 1
        fi
    fi
fi


# Select the latest input ISO.
if [[ ! -d "$INPUT_DIR" ]]; then
    error "Input directory not found: $INPUT_DIR"
    exit 1
fi

LATEST_ISO="$(
    find "$INPUT_DIR" -maxdepth 1 -type f -name 'systemrescue-*.iso' |
        sort -V |
        tail -n 1
)"

if [[ -z "$LATEST_ISO" ]]; then
    error "No SystemRescue ISO found in $INPUT_DIR."
    printf '    Place an official systemrescue-*.iso file there.\n'
    exit 1
fi

ISO_BASENAME="$(basename -- "$LATEST_ISO" .iso)"
OUTPUT_ISO="$OUTPUT_DIR/${ISO_BASENAME}-custom-$(date +%Y%m%d).iso"
mkdir -p "$OUTPUT_DIR"

# Create and clean up a unique temporary workspace.
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sysrescue-build.XXXXXXXX")"
cleanup() {
    info "Cleaning temporary workspace..."
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR/iso_add"

# Copy static recipe overlay.
info "Staging base customizations..."
if [[ -d "$RECIPE_DIR/airootfs" ]]; then
    cp -a "$RECIPE_DIR/airootfs/." "$WORK_DIR/iso_add/"
fi

POLICIES_DIR="$WORK_DIR/iso_add/usr/lib/firefox/distribution"
EXT_TARGET_DIR="$WORK_DIR/iso_add/usr/lib/firefox/browser/extensions"
mkdir -p "$POLICIES_DIR" "$EXT_TARGET_DIR"

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

# Parse extensions, then resolve and download them with up to 10 workers.
if [[ -f "$EXT_LIST" ]]; then
    slugs=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Remove comments and surrounding whitespace.
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ /addon/([^/?#]+) ]]; then
            slugs+=("${BASH_REMATCH[1]}")
        else
            slugs+=("$line")
        fi
    done < "$EXT_LIST"

    if ((${#slugs[@]})); then
        info "Resolving and downloading ${#slugs[@]} Firefox extension(s), up to 10 at a time..."

        results=()
        mapfile -t results < <(
            printf '%s\0' "${slugs[@]}" |
                xargs -0 -r -P 10 -n 1 bash -c '
                    target_dir=$1
                    slug=$2

                    if [[ -t 2 ]]; then
                        CYAN=$'\''\033[96m'\''
                        GREEN=$'\''\033[32m'\''
                        YELLOW=$'\''\033[33m'\''
                        RESET=$'\''\033[0m'\''
                    else
                        CYAN="" GREEN="" YELLOW="" RESET=""
                    fi

                    printf "    %s[*]%s Fetching extension: %s\n" "$CYAN" "$RESET" "$slug" >&2

                    if meta=$(curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
                        "https://addons.mozilla.org/api/v5/addons/addon/${slug}/") &&
                    guid=$(jq -er ".guid // empty" <<<"$meta") &&
                    url=$(jq -er ".current_version.file.url // empty" <<<"$meta") &&
                    curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
                        "$url" -o "$target_dir/${guid}.xpi"; then
                        printf "    %s[✓]%s Downloaded extension: %s\n" "$GREEN" "$RESET" "$slug" >&2
                        jq -cn --arg slug "$slug" --arg guid "$guid" \
                            "{slug:\$slug,guid:\$guid,status:\"ok\"}"
                    else
                        printf "    %s[!]%s Could not resolve or download extension: %s\n" \
                            "$YELLOW" "$RESET" "$slug" >&2
                        jq -cn --arg slug "$slug" \
                            "{slug:\$slug,status:\"failed\"}"
                    fi
                ' _ "$EXT_TARGET_DIR"
        )

        # Update policy JSON.
        for result in "${results[@]}"; do
            [[ "$(jq -r '.status' <<<"$result")" == ok ]] || continue

            guid="$(jq -r '.guid' <<<"$result")"
            xpi_name="${guid}.xpi"
            encoded_xpi="${xpi_name//\{/%7B}"
            encoded_xpi="${encoded_xpi//\}/%7D}"

            POLICIES_JSON="$(
                jq \
                    --arg guid "$guid" \
                    --arg url "file:///usr/lib/firefox/browser/extensions/$encoded_xpi" \
                    '.policies.ExtensionSettings[$guid] = {
                        "installation_mode": "force_installed",
                        "install_url": $url
                    }' <<<"$POLICIES_JSON"
            )"
        done

    fi
fi

# Write the rendered policies.json.
jq '.' <<<"$POLICIES_JSON" > "$POLICIES_DIR/policies.json"

# Set permissions for the staged overlay.
chmod -R u=rwX,go=rX "$WORK_DIR/iso_add/"
if [[ -d "$WORK_DIR/iso_add/root" ]]; then
    chmod 700 "$WORK_DIR/iso_add/root"
fi

# Build the customized ISO.
info "Building ISO..."
sudo "$CUSTOMIZE_BIN" \
    --auto \
    --source="$LATEST_ISO" \
    --dest="$OUTPUT_ISO" \
    --recipe-dir="$WORK_DIR"

success "Build complete: $OUTPUT_ISO"
