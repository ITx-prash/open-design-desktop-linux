#!/usr/bin/env bash
# uninstall.sh: Cleanly remove Open Design desktop integration.

set -euo pipefail

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  echo "Error: Do not run uninstall.sh as root or with sudo." >&2
  exit 1
fi

CLEAN_STATE=0
for arg in "$@"; do
  case "$arg" in
    --clean|--purge) CLEAN_STATE=1 ;;
    -h|--help)
      echo "Usage: ./uninstall.sh [--clean]"
      echo "  --clean   Also remove ~/.config/open-design and ~/.config/open-design-pwa"
      exit 0
      ;;
    *)
      echo "Error: Unknown option '$arg'." >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_TARGET="$HOME/.local/bin/open-design"
SHIM_DIR="$HOME/.local/share/open-design/bin"
APP_NODE24_DIR="$HOME/.local/share/open-design/node-v24"
APP_SHARE_DIR="$HOME/.local/share/open-design"
DESKTOP_TARGET="$HOME/.local/share/applications/open_design.desktop"
UPDATER_DESKTOP_TARGET="$HOME/.local/share/applications/org.opendesign.Updater.desktop"
ICON_TARGET="$HOME/.local/share/icons/hicolor/512x512/apps/open_design.png"
UPDATER_ICON_TARGET="$HOME/.local/share/icons/hicolor/512x512/apps/open_design_updater.png"
LEGACY_ICON_TARGET="$HOME/.local/share/icons/open_design.png"
LEGACY_UPDATER_ICON_TARGET="$HOME/.local/share/icons/open_design_updater.png"
CONFIG_DIR="$HOME/.config/open-design"
CONFIG_FILE="$CONFIG_DIR/config"
DEFAULT_PWA_DIR="$HOME/.config/open-design-pwa"
DEFAULT_REPO="$HOME/open-design"
FILE_REPO="$DEFAULT_REPO"
FILE_PWA_DIR="$DEFAULT_PWA_DIR"

if [ -f "$CONFIG_FILE" ]; then
  while IFS='=' read -r raw_key raw_val; do
    key="$(echo "${raw_key:-}" | tr -d '[:space:]')"
    val="$(echo "${raw_val:-}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^[\"']//;s/[\"']\$//")"
    if [ -z "$key" ] || [[ "$key" == \#* ]] || [ -z "$val" ]; then
      continue
    fi
    case "$key" in
      OPEN_DESIGN_REPO)    FILE_REPO="${val/#\~/$HOME}" ;;
      OPEN_DESIGN_PWA_DIR) FILE_PWA_DIR="${val/#\~/$HOME}" ;;
    esac
  done < "$CONFIG_FILE"
fi

REPO_DIR="${OPEN_DESIGN_REPO:-$FILE_REPO}"
REPO_DIR="${REPO_DIR/#\~/$HOME}"
REPO_DIR="${REPO_DIR%/}"
[ -z "$REPO_DIR" ] && REPO_DIR="$DEFAULT_REPO"

PWA_DIR="${OPEN_DESIGN_PWA_DIR:-$FILE_PWA_DIR}"
PWA_DIR="${PWA_DIR/#\~/$HOME}"
PWA_DIR="${PWA_DIR%/}"

canonical_path() {
  python3 -I -c 'import os, sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$1" 2>/dev/null || printf '%s' "${1%/}"
}

paths_overlap() {
  local r1 r2
  r1="$(canonical_path "$1")"
  r2="$(canonical_path "$2")"
  [ "$r1" = "$r2" ] || [[ "$r1" == "$r2/"* ]] || [[ "$r2" == "$r1/"* ]]
}

if [ -n "$PWA_DIR" ]; then
  if paths_overlap "$PWA_DIR" "$CONFIG_DIR" || paths_overlap "$PWA_DIR" "$DEFAULT_REPO" || paths_overlap "$PWA_DIR" "$REPO_DIR" || paths_overlap "$PWA_DIR" "$APP_SHARE_DIR"; then
    PWA_DIR=""
  fi
fi

is_safe_managed_dir() {
  local raw="${1%/}"
  [ -n "$raw" ] && [ -d "$raw" ] && [ ! -L "$raw" ] || return 1
  local target
  target="$(canonical_path "$raw")"
  if paths_overlap "$target" "$REPO_DIR" || paths_overlap "$target" "$DEFAULT_REPO" || paths_overlap "$target" "$DEFAULT_PWA_DIR"; then
    return 1
  fi
  if [ -n "$PWA_DIR" ] && paths_overlap "$target" "$PWA_DIR"; then
    return 1
  fi
  [ ! -e "$target/.git" ]
}

is_safe_config_dir() {
  is_safe_managed_dir "$CONFIG_DIR"
}

is_owned_pwa_dir() {
  local raw="${1%/}"
  case "$raw" in
    ""|*".."*) return 1 ;;
  esac
  [ -d "$raw" ] && [ ! -L "$raw" ] || return 1
  local target clean_repo clean_def_repo
  target="$(cd "$raw" 2>/dev/null && pwd -P || true)"
  clean_repo="$(canonical_path "$REPO_DIR")"
  clean_def_repo="$(canonical_path "$DEFAULT_REPO")"
  case "$target" in
    ""|/|"$HOME"|"$HOME/.config"|"$CONFIG_DIR"|"$CONFIG_DIR/"*|"$DEFAULT_REPO"|"$DEFAULT_REPO/"*|"$clean_repo"|"$clean_repo/"*)
      return 1
      ;;
    */open-design*|*/open_design*) ;;
    *) return 1 ;;
  esac
  case "$clean_repo" in
    "$target"|"$target/"*) return 1 ;;
  esac
  case "$clean_def_repo" in
    "$target"|"$target/"*) return 1 ;;
  esac
  [ ! -e "$target/.git" ] && [ -f "$target/.open-design-profile" ]
}

INTEGRATION_FILES=(
  "$BIN_TARGET"
  "$DESKTOP_TARGET"
  "$UPDATER_DESKTOP_TARGET"
  "$ICON_TARGET"
  "$UPDATER_ICON_TARGET"
  "$LEGACY_ICON_TARGET"
  "$LEGACY_UPDATER_ICON_TARGET"
)

FOUND=0
for file in "${INTEGRATION_FILES[@]}"; do
  if [ -e "$file" ]; then
    FOUND=1
  fi
done
if [ -d "$SHIM_DIR" ] || [ -d "$APP_SHARE_DIR/lib" ] || [ -d "$APP_NODE24_DIR" ] || [ -d "$CONFIG_DIR/node-bin" ]; then
  FOUND=1
fi

STATE_EXISTS=0
if is_safe_config_dir; then
  STATE_EXISTS=1
elif is_owned_pwa_dir "$DEFAULT_PWA_DIR"; then
  STATE_EXISTS=1
elif [ -n "$PWA_DIR" ] && [ "$PWA_DIR" != "$DEFAULT_PWA_DIR" ] && is_owned_pwa_dir "$PWA_DIR"; then
  STATE_EXISTS=1
fi

is_update_active() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -I - "$CONFIG_DIR" <<'PY' >/dev/null 2>&1
import fcntl, os, sys
cfg_dir = sys.argv[1]
rt_dir = os.environ.get("XDG_RUNTIME_DIR")
dirs = [rt_dir, cfg_dir] if (rt_dir and os.path.isdir(rt_dir)) else [cfg_dir]
for d in dirs:
    p = os.path.join(d, "open-design-updating.lock")
    if os.path.exists(p):
        try:
            with open(p, "a+", encoding="utf-8") as f:
                fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(f.fileno(), fcntl.LOCK_UN)
        except (BlockingIOError, OSError):
            sys.exit(0)
sys.exit(1)
PY
    return $?
  elif command -v flock >/dev/null 2>&1; then
    local lock_cand
    for lock_cand in "${XDG_RUNTIME_DIR:-$CONFIG_DIR}/open-design-updating.lock" "$CONFIG_DIR/open-design-updating.lock"; do
      if [ -e "$lock_cand" ] && ! flock -n "$lock_cand" true >/dev/null 2>&1; then
        return 0
      fi
    done
  fi
  return 1
}

if is_update_active; then
  echo "Error: Open Design is currently updating. Wait for the update to finish or cancel it before uninstalling." >&2
  exit 1
fi

if [ "$FOUND" -eq 0 ] && { [ "$CLEAN_STATE" -eq 0 ] || [ "$STATE_EXISTS" -eq 0 ]; }; then
  echo "Open Design desktop integration is not installed."
  exit 0
fi

if [ "$CLEAN_STATE" -eq 1 ] && [ "$STATE_EXISTS" -eq 1 ] && [ ! -t 0 ]; then
  echo "Error: '--clean' requires interactive confirmation in a terminal." >&2
  exit 1
fi

STOP_BIN=""
if [ -x "$SCRIPT_DIR/open-design" ]; then
  STOP_BIN="$SCRIPT_DIR/open-design"
elif [ -x "$BIN_TARGET" ]; then
  STOP_BIN="$BIN_TARGET"
fi

if [ -n "$STOP_BIN" ]; then
  echo "Stopping Open Design..."
  if ! "$STOP_BIN" --stop --quiet >/dev/null 2>&1; then
    if is_update_active; then
      echo "Error: Open Design is currently updating. Wait for the update to finish or cancel it before uninstalling." >&2
      exit 1
    fi
    echo "Warning: Could not confirm all Open Design processes stopped; proceeding with uninstallation." >&2
  fi
fi

if [ "$FOUND" -eq 1 ]; then
  echo "Removing desktop integration..."
  for file in "${INTEGRATION_FILES[@]}"; do
    rm -f -- "$file"
  done
  if is_safe_managed_dir "$SHIM_DIR"; then
    rm -f -- "$SHIM_DIR/node" "$SHIM_DIR/pnpm" "$SHIM_DIR/pnpx" "$SHIM_DIR/corepack" 2>/dev/null || true
  fi
  if is_safe_managed_dir "$CONFIG_DIR/node-bin"; then
    rm -f -- "$CONFIG_DIR/node-bin/node" "$CONFIG_DIR/node-bin/pnpm" "$CONFIG_DIR/node-bin/pnpx" "$CONFIG_DIR/node-bin/corepack" 2>/dev/null || true
  fi
  if is_safe_managed_dir "$APP_SHARE_DIR/lib/node_modules/pnpm"; then
    rm -rf -- "$APP_SHARE_DIR/lib/node_modules/pnpm" 2>/dev/null || true
  fi
  if is_safe_managed_dir "$APP_NODE24_DIR"; then
    rm -rf -- "$APP_NODE24_DIR" 2>/dev/null || true
  fi
  rmdir "$SHIM_DIR" "$CONFIG_DIR/node-bin" "$APP_SHARE_DIR/lib/node_modules" "$APP_SHARE_DIR/lib" "$APP_SHARE_DIR" 2>/dev/null || true
fi

rm -f "${XDG_RUNTIME_DIR:-/tmp}/open-design-update.lock" \
      "${XDG_RUNTIME_DIR:-/tmp}/open-design-updating.lock" \
      "${XDG_RUNTIME_DIR:-/tmp}/open-design-server.pid" \
      "${XDG_RUNTIME_DIR:-/tmp}/open-design-start.lock" \
      "$CONFIG_DIR/open-design-update.lock" \
      "$CONFIG_DIR/open-design-updating.lock" \
      "$CONFIG_DIR/open-design-server.pid" \
      "$CONFIG_DIR/open-design-start.lock" \
      "$CONFIG_DIR/server.log" 2>/dev/null || true

if [ "$CLEAN_STATE" -eq 1 ] && [ "$STATE_EXISTS" -eq 1 ]; then
  DO_CLEAN=0
  if [ -t 0 ]; then
    echo ""
    echo "The following project state will be removed:"
    if is_safe_config_dir; then
      echo "  $CONFIG_DIR"
    fi
    if is_owned_pwa_dir "$DEFAULT_PWA_DIR"; then
      echo "  $DEFAULT_PWA_DIR"
    fi
    if [ -n "$PWA_DIR" ] && [ "$PWA_DIR" != "$DEFAULT_PWA_DIR" ] && is_owned_pwa_dir "$PWA_DIR"; then
      echo "  $PWA_DIR"
    fi
    printf "Remove this state? [y/N]: "
    confirm=""
    read -r confirm || confirm=""
    case "$confirm" in
      [yY]|[yY][eE][sS]) DO_CLEAN=1 ;;
    esac
  else
    echo "Error: '--clean' requires interactive confirmation in a terminal." >&2
    exit 1
  fi

  if [ "$DO_CLEAN" -eq 1 ]; then
    if is_safe_config_dir; then
      rm -rf -- "$CONFIG_DIR"
    fi
    if is_owned_pwa_dir "$DEFAULT_PWA_DIR"; then
      rm -rf -- "$DEFAULT_PWA_DIR"
    fi
    if [ -n "$PWA_DIR" ] && [ "$PWA_DIR" != "$DEFAULT_PWA_DIR" ] && is_owned_pwa_dir "$PWA_DIR"; then
      rm -rf -- "$PWA_DIR"
    fi
    echo "Removed configuration and isolated app profile."
  else
    echo "Preserved configuration and isolated app profile."
  fi
elif [ "$FOUND" -eq 1 ] && [ "$STATE_EXISTS" -eq 1 ]; then
  echo "Open Design desktop integration removed (run './uninstall.sh --clean' to also remove config and app profile)."
else
  echo "Open Design desktop integration removed."
fi

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
fi
