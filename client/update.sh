#!/usr/bin/env bash
# DRUZHBODOM_UPDATER_SELFUPDATE_V1
set -euo pipefail

ORIGINAL_ARGS=("$@")
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"

GITHUB_REPO="${GITHUB_REPO:-idontknowhowbut/valheim-modpack-druzhbodom}"
APP_NAME="valheim-druzhbodom"
XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_ROOT="$XDG_DATA_HOME/$APP_NAME"
CONFIG_ROOT="$XDG_CONFIG_HOME/$APP_NAME"
CONFIG_FILE="$CONFIG_ROOT/launcher.conf"
STATE_FILE="$STATE_ROOT/modpack-state.json"

NO_LAUNCH=0
FORCE_UPDATE=0
ENABLE_LOW_SPEC=0
DISABLE_LOW_SPEC=0
SKIP_SELF_UPDATE=0
STEAM_MODE=0
STEAM_ARGS=()

while (($#)); do
  case "$1" in
    --no-launch)
      NO_LAUNCH=1
      shift
      ;;
    --force)
      FORCE_UPDATE=1
      shift
      ;;
    --enable-low-spec)
      ENABLE_LOW_SPEC=1
      shift
      ;;
    --disable-low-spec)
      DISABLE_LOW_SPEC=1
      shift
      ;;
    --skip-self-update)
      SKIP_SELF_UPDATE=1
      shift
      ;;
    --steam)
      STEAM_MODE=1
      shift
      STEAM_ARGS=("$@")
      break
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if ((ENABLE_LOW_SPEC && DISABLE_LOW_SPEC)); then
  echo 'ERROR: use either --enable-low-spec or --disable-low-spec, not both.' >&2
  exit 2
fi

step() {
  printf '\n==> %s\n' "$1"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

need_cmd curl
need_cmd unzip
need_cmd sha256sum

# Info-ZIP unzip returns exit code 1 for non-fatal warnings. Older releases of
# our publisher created Windows-style ZIP entry names with backslashes, which
# triggers exactly that warning on Linux even though extraction succeeds.
# Accept rc=1 so existing releases remain installable; rc>1 is a real error.
extract_zip() {
  local archive="$1"
  local destination="$2"
  local overwrite="${3:-0}"
  local rc=0

  if ((overwrite)); then
    unzip -qo "$archive" -d "$destination" || rc=$?
  else
    unzip -q "$archive" -d "$destination" || rc=$?
  fi

  if ((rc > 1)); then
    die "Failed to extract ZIP (unzip exit code $rc): $archive"
  fi

  if ((rc == 1)); then
    echo 'WARNING: ZIP was extracted with a non-fatal warning; continuing.' >&2
  fi
}

self_update() {
  ((SKIP_SELF_UPDATE)) && return 0

  local remote_url="https://raw.githubusercontent.com/$GITHUB_REPO/main/client/update.sh"
  local tmp
  tmp="$(mktemp -t druzhbodom-self-update.XXXXXX.sh)"

  step 'Checking launcher update'
  if ! curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp" "$remote_url"; then
    echo 'WARNING: launcher self-update check failed; continuing with the current script.' >&2
    rm -f "$tmp"
    return 0
  fi

  if ! grep -q 'DRUZHBODOM_UPDATER_SELFUPDATE_V1' "$tmp"; then
    echo 'WARNING: remote launcher file is not recognized; continuing with the current script.' >&2
    rm -f "$tmp"
    return 0
  fi

  if cmp -s "$SCRIPT_PATH" "$tmp"; then
    echo 'Launcher is up to date.'
    rm -f "$tmp"
    return 0
  fi

  cp -f "$SCRIPT_PATH" "$SCRIPT_PATH.backup" 2>/dev/null || true
  if ! cp -f "$tmp" "$SCRIPT_PATH"; then
    echo 'WARNING: failed to replace launcher script; continuing with the current script.' >&2
    rm -f "$tmp"
    return 0
  fi
  chmod u+x "$SCRIPT_PATH"
  rm -f "$tmp"

  echo 'Launcher updated. Restarting with the new script...'
  exec "$SCRIPT_PATH" --skip-self-update "${ORIGINAL_ARGS[@]}"
}

self_update

mkdir -p "$STATE_ROOT" "$CONFIG_ROOT"

find_steam_root() {
  local candidates=(
    "$HOME/.local/share/Steam"
    "$HOME/.steam/steam"
    "$HOME/.steam/root"
  )
  local p
  for p in "${candidates[@]}"; do
    if [[ -x "$p/steam.sh" || -x "$p/steam" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

find_valheim_dir() {
  local steam_root="$1"
  local candidate="$steam_root/steamapps/common/Valheim"
  if [[ -x "$candidate/valheim.x86_64" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  local vdf="$steam_root/steamapps/libraryfolders.vdf"
  if [[ -f "$vdf" ]]; then
    while IFS= read -r lib; do
      [[ -z "$lib" ]] && continue
      candidate="$lib/steamapps/common/Valheim"
      if [[ -x "$candidate/valheim.x86_64" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(
      sed -nE 's/^[[:space:]]*"path"[[:space:]]*"([^"]+)".*/\1/p; s/^[[:space:]]*"[0-9]+"[[:space:]]*"([^"]+)".*/\1/p' "$vdf" \
        | sed 's#\\\\#\\#g'
    )
  fi
  return 1
}

write_config() {
  local profile_dir="$1"
  local game_dir="$2"
  local steam_root="$3"
  local addons="${4:-}"
  cat > "$CONFIG_FILE" <<EOF
PROFILE_DIR=$(printf '%q' "$profile_dir")
GAME_DIR=$(printf '%q' "$game_dir")
STEAM_ROOT=$(printf '%q' "$steam_root")
ADDONS=$(printf '%q' "$addons")
EOF
}

first_run_config() {
  echo "First run detected."
  local default_profile="$STATE_ROOT/profile"
  printf 'Default modpack directory: %s\n' "$default_profile"
  read -r -p 'Use this directory? [Y/n] ' answer
  local profile_dir
  if [[ -z "${answer:-}" || "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    profile_dir="$default_profile"
  else
    read -r -p 'Enter the full directory for the modpack profile: ' profile_dir
    [[ -n "$profile_dir" ]] || die 'Profile directory cannot be empty.'
    profile_dir="${profile_dir/#\~/$HOME}"
  fi

  local steam_root=""
  local game_dir=""
  steam_root="$(find_steam_root || true)"
  if [[ -n "$steam_root" ]]; then
    game_dir="$(find_valheim_dir "$steam_root" || true)"
  fi

  if [[ -n "$game_dir" ]]; then
    printf 'Found Valheim: %s\n' "$game_dir"
    read -r -p 'Use this installation? [Y/n] ' answer
    if [[ -n "${answer:-}" && ! "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
      game_dir=""
    fi
  fi

  if [[ -z "$game_dir" ]]; then
    read -r -p 'Enter Valheim directory (contains valheim.x86_64): ' game_dir
    game_dir="${game_dir/#\~/$HOME}"
    [[ -x "$game_dir/valheim.x86_64" ]] || die "valheim.x86_64 not found: $game_dir"
  fi

  if [[ -z "$steam_root" ]]; then
    read -r -p 'Enter Steam root directory: ' steam_root
    steam_root="${steam_root/#\~/$HOME}"
  fi

  local addons=""
  read -r -p 'Enable low-spec optimization addon? [y/N] ' answer
  if [[ "${answer:-}" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    addons='low-spec'
  fi

  mkdir -p "$(dirname "$profile_dir")"
  write_config "$profile_dir" "$game_dir" "$steam_root" "$addons"
}

if [[ ! -f "$CONFIG_FILE" ]]; then
  first_run_config
fi

# Config migration for launcher.conf created before addon support.
if ! grep -q '^ADDONS=' "$CONFIG_FILE"; then
  echo 'Launcher config was created before addon support.'
  read -r -p 'Enable low-spec optimization addon? [y/N] ' answer
  if [[ "${answer:-}" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    printf 'ADDONS=%q\n' 'low-spec' >> "$CONFIG_FILE"
  else
    printf 'ADDONS=%q\n' '' >> "$CONFIG_FILE"
  fi
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"
: "${PROFILE_DIR:?PROFILE_DIR missing from config}"
: "${GAME_DIR:?GAME_DIR missing from config}"
: "${STEAM_ROOT:?STEAM_ROOT missing from config}"
ADDONS="${ADDONS:-}"

if ((ENABLE_LOW_SPEC)); then
  ADDONS='low-spec'
  write_config "$PROFILE_DIR" "$GAME_DIR" "$STEAM_ROOT" "$ADDONS"
  echo 'Low-spec addon: enabled'
elif ((DISABLE_LOW_SPEC)); then
  ADDONS=''
  write_config "$PROFILE_DIR" "$GAME_DIR" "$STEAM_ROOT" "$ADDONS"
  echo 'Low-spec addon: disabled'
fi

printf 'Selected addons: %s\n' "${ADDONS:-<none>}"

json_get() {
  local file="$1"
  local key="$2"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$key" <<'PY'
import json, sys
with open(sys.argv[1], 'r', encoding='utf-8-sig') as f:
    data = json.load(f)
value = data
for part in sys.argv[2].split('.'):
    value = value[part]
print(value)
PY
  else
    # Manifest is generated by our own publisher and values queried here are scalars.
    sed -nE 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"?([^",}]+)"?.*/\1/p' "$file" | head -n1
  fi
}

TEMP_DIR="$(mktemp -d -t druzhbodom-update.XXXXXX)"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

step 'Checking latest GitHub Release'
MANIFEST_URL="https://github.com/$GITHUB_REPO/releases/latest/download/manifest.json"
curl -fL --retry 3 --connect-timeout 15 -o "$TEMP_DIR/manifest.json" "$MANIFEST_URL"
REMOTE_VERSION="$(json_get "$TEMP_DIR/manifest.json" version)"
PROFILE_ASSET="$(json_get "$TEMP_DIR/manifest.json" profileAsset)"
EXPECTED_SHA="$(json_get "$TEMP_DIR/manifest.json" profileSha256 | tr '[:upper:]' '[:lower:]')"

LOCAL_VERSION=""
LOCAL_ADDONS=""
if [[ -f "$STATE_FILE" ]]; then
  LOCAL_VERSION="$(json_get "$STATE_FILE" version 2>/dev/null || true)"
  LOCAL_ADDONS="$(json_get "$STATE_FILE" addonsCsv 2>/dev/null || true)"
fi

PROFILE_HEALTHY=0
if [[ -f "$PROFILE_DIR/BepInEx/core/BepInEx.Preloader.dll" ]]; then
  PROFILE_HEALTHY=1
fi

install_profile() {
  local archive="$TEMP_DIR/client-profile.zip"
  local url="https://github.com/$GITHUB_REPO/releases/latest/download/$PROFILE_ASSET"

  step "Downloading modpack $REMOTE_VERSION"
  curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "$archive" "$url"

  step 'Verifying SHA256'
  local actual_sha
  actual_sha="$(sha256sum "$archive" | awk '{print tolower($1)}')"
  [[ "$actual_sha" == "$EXPECTED_SHA" ]] || die "SHA256 mismatch. Expected $EXPECTED_SHA, got $actual_sha"

  local staging="${PROFILE_DIR}.__new"
  local backup="${PROFILE_DIR}.backup"
  rm -rf "$staging"
  mkdir -p "$staging"

  step 'Extracting new profile'
  extract_zip "$archive" "$staging"

  if [[ "$ADDONS" == *"low-spec"* ]]; then
    command -v python3 >/dev/null 2>&1 || die 'python3 is required when the low-spec addon is enabled.'
    local addon_asset addon_sha addon_archive addon_url addon_actual_sha
    addon_asset="$(json_get "$TEMP_DIR/manifest.json" 'addons.low-spec.asset')"
    addon_sha="$(json_get "$TEMP_DIR/manifest.json" 'addons.low-spec.sha256' | tr '[:upper:]' '[:lower:]')"
    [[ -n "$addon_asset" && -n "$addon_sha" ]] || die 'Selected addon low-spec is not available in this release.'

    addon_archive="$TEMP_DIR/addon-low-spec.zip"
    addon_url="https://github.com/$GITHUB_REPO/releases/latest/download/$addon_asset"
    step 'Downloading addon: low-spec'
    curl -fL --retry 3 --connect-timeout 15 --progress-bar -o "$addon_archive" "$addon_url"

    step 'Verifying addon SHA256: low-spec'
    addon_actual_sha="$(sha256sum "$addon_archive" | awk '{print tolower($1)}')"
    [[ "$addon_actual_sha" == "$addon_sha" ]] || die "Addon low-spec SHA256 mismatch. Expected $addon_sha, got $addon_actual_sha"

    step 'Merging addon into profile: low-spec'
    extract_zip "$addon_archive" "$staging" 1
  fi

  [[ -f "$staging/BepInEx/core/BepInEx.Preloader.dll" ]] || die 'Downloaded profile has no BepInEx/core/BepInEx.Preloader.dll'

  step 'Switching profile'
  rm -rf "$backup"
  local old_moved=0
  if [[ -e "$PROFILE_DIR" ]]; then
    mv "$PROFILE_DIR" "$backup"
    old_moved=1
  fi

  if ! mv "$staging" "$PROFILE_DIR"; then
    if ((old_moved)) && [[ ! -e "$PROFILE_DIR" && -e "$backup" ]]; then
      mv "$backup" "$PROFILE_DIR"
    fi
    die 'Failed to switch to new profile.'
  fi

  cat > "$STATE_FILE" <<EOF
{
  "version": "$REMOTE_VERSION",
  "profileSha256": "$EXPECTED_SHA",
  "addonsCsv": "$ADDONS"
}
EOF
  echo "Installed modpack $REMOTE_VERSION"
}

if ((FORCE_UPDATE)) || ((PROFILE_HEALTHY == 0)) || [[ "$LOCAL_VERSION" != "$REMOTE_VERSION" ]] || [[ "$LOCAL_ADDONS" != "$ADDONS" ]]; then
  echo "Local:  ${LOCAL_VERSION:-<none>}"
  echo "Remote: $REMOTE_VERSION"
  if [[ "$LOCAL_ADDONS" != "$ADDONS" ]]; then
    echo "Addon selection changed: installed=[${LOCAL_ADDONS:-}], desired=[${ADDONS:-}]"
  fi
  install_profile
else
  echo "Modpack $LOCAL_VERSION is up to date."
fi

if ((NO_LAUNCH)); then
  exit 0
fi

find_bepinex_launcher() {
  local p
  for p in "$PROFILE_DIR/start_game_bepinex.sh" "$PROFILE_DIR/run_bepinex.sh"; do
    if [[ -f "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

BEPINEX_LAUNCHER="$(find_bepinex_launcher || true)"
[[ -n "$BEPINEX_LAUNCHER" ]] || die 'BepInEx Linux launch script not found in the profile.'
chmod u+x "$BEPINEX_LAUNCHER"

step 'Starting Valheim with the external BepInEx profile'
if ((STEAM_MODE)); then
  # Preferred Linux integration:
  # Steam launch options: "/absolute/path/update.sh" --steam %command%
  exec "$BEPINEX_LAUNCHER" "${STEAM_ARGS[@]}"
else
  # Convenient direct launch. Steam should already be running.
  exec "$BEPINEX_LAUNCHER" "$GAME_DIR/valheim.x86_64"
fi
