#!/usr/bin/env bash
# install.sh: Install Open Design desktop integration for Linux.

set -euo pipefail

SKIP_CHECKS=0
FORCE_REBUILD=0
REQUESTED_BROWSER=""

usage() {
  cat <<'EOF'
Usage: ./install.sh [--browser <name>] [--rebuild] [--skip-checks]

  --browser <name>  Select browser: google-chrome, chromium, brave,
                    brave-origin, microsoft-edge, or auto.
  --rebuild         Force a fresh production build of Open Design.
  --skip-checks     Skip system dependency and repository build steps.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --browser)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "Error: --browser requires a value." >&2
        exit 2
      fi
      REQUESTED_BROWSER="$2"
      shift 2
      ;;
    --browser=*)
      REQUESTED_BROWSER="${1#*=}"
      shift
      ;;
    --rebuild) FORCE_REBUILD=1; shift ;;
    --skip-checks) SKIP_CHECKS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Error: Unknown option '$1'." >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_RESET=$'\033[0m'
else
  C_BOLD=""
  C_DIM=""
  C_GREEN=""
  C_RED=""
  C_YELLOW=""
  C_CYAN=""
  C_RESET=""
fi

if [ "$(uname -s)" != "Linux" ]; then
  echo "${C_RED}Error:${C_RESET} This installer only supports Linux." >&2
  exit 1
fi

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  echo "${C_RED}Error:${C_RESET} Do not run install.sh as root or with sudo." >&2
  echo "       Run './install.sh' as your regular desktop user." >&2
  exit 1
fi

USER_PATH="${PATH:-}"
NODE_SHIM_DIR="$HOME/.local/share/open-design/bin"
APP_NODE24_DIR="$HOME/.local/share/open-design/node-v24"
USING_FEDORA_NODE24_SHIM=0

prepend_dir_to_path() {
  local d="${1%/}"
  [ -n "$d" ] && [ -d "$d" ] || return 0
  local cleaned=":$PATH:"
  cleaned="${cleaned//:$d:/:}"
  cleaned="${cleaned#:}"
  cleaned="${cleaned%:}"
  if [ -n "$cleaned" ]; then
    PATH="$d:$cleaned"
  else
    PATH="$d"
  fi
}

refresh_user_node_paths() {
  if [ -d "$HOME/.config/open-design/node-bin" ] && [ ! -L "$HOME/.config/open-design/node-bin" ]; then
    rm -f "$HOME/.config/open-design/node-bin/node" "$HOME/.config/open-design/node-bin/pnpm" "$HOME/.config/open-design/node-bin/pnpx" "$HOME/.config/open-design/node-bin/corepack" 2>/dev/null || true
    rmdir "$HOME/.config/open-design/node-bin" 2>/dev/null || true
  fi

  prepend_dir_to_path "${PNPM_HOME:-$HOME/.local/share/pnpm}"
  prepend_dir_to_path "$HOME/.local/bin"
  prepend_dir_to_path "$NODE_SHIM_DIR"
  prepend_dir_to_path "$APP_NODE24_DIR/bin"

  local cand=""
  for cand in \
    $(ls -d "$HOME"/.nvm/versions/node/v24.*/bin 2>/dev/null | sort -V | tail -n 1 || true) \
    $(ls -d "$HOME"/.local/share/mise/installs/node/24*/bin 2>/dev/null | sort -V | tail -n 1 || true) \
    $(ls -d "$HOME"/.local/share/fnm/node-versions/v24.*/installation/bin 2>/dev/null | sort -V | tail -n 1 || true); do
    prepend_dir_to_path "$cand"
  done

  # Expose Fedora's versioned /usr/bin/node-24 in our private shim directory when needed
  if [ -x "/usr/bin/node-24" ]; then
    if ! command -v node >/dev/null 2>&1 || ! node -e 'process.exit(parseInt(process.versions.node, 10) === 24 ? 0 : 1)' >/dev/null 2>&1; then
      mkdir -p "$NODE_SHIM_DIR"
      chmod 700 "$HOME/.local/share/open-design" "$NODE_SHIM_DIR" 2>/dev/null || true
      ln -sf "/usr/bin/node-24" "$NODE_SHIM_DIR/node"
      prepend_dir_to_path "$NODE_SHIM_DIR"
    fi
    if [ "$(command -v node 2>/dev/null || true)" = "$NODE_SHIM_DIR/node" ]; then
      USING_FEDORA_NODE24_SHIM=1
    fi
  fi

  # Ensure pnpm/pnpx/corepack shims execute under the active Node 24 runtime in PATH
  # rather than a hardcoded #!/usr/bin/node shebang (e.g. Fedora RPM nodejs-corepack).
  if command -v python3 >/dev/null 2>&1 && command -v node >/dev/null 2>&1 && node -e 'process.exit(parseInt(process.versions.node, 10) === 24 ? 0 : 1)' >/dev/null 2>&1; then
    python3 -I - "$NODE_SHIM_DIR" <<'PYSHIM' 2>/dev/null || true
import os, re, shlex, shutil, subprocess, sys
shim_dir = sys.argv[1]
WRAP_LINES = [
    "#!/usr/bin/env sh",
    "# open-design node24 shim",
]

def is_valid_pnpm_target(real_target, name="pnpm"):
    try:
        cp_js = resolve_corepack_js(real_target) if name == "pnpm" else None
        cmd = ["node", cp_js, "pnpm@10.33.2", "--version"] if cp_js else ["node", real_target, "--version"]
        env = os.environ.copy()
        env["COREPACK_ENABLE_DOWNLOAD_PROMPT"] = "0"
        res = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=8)
        if res.returncode != 0:
            return False
        m = re.match(r"^(\d+)\.(\d+)\.(\d+)", res.stdout.strip())
        v = tuple(map(int, m.groups())) if m else ()
        return (10, 33, 2) <= v < (11, 0, 0)
    except Exception:
        return False

def resolve_corepack_js(real_target):
    d = os.path.dirname(real_target)
    for cand in (os.path.join(d, "corepack.js"), os.path.join(os.path.dirname(d), "dist", "corepack.js")):
        if os.path.isfile(cand):
            return cand
    return None

def write_wrapper(dest, real_target):
    os.makedirs(shim_dir, mode=0o700, exist_ok=True)
    try:
        os.chmod(os.path.dirname(shim_dir), 0o700)
        os.chmod(shim_dir, 0o700)
    except OSError:
        pass
    if os.path.lexists(dest):
        os.unlink(dest)
    cp_js = resolve_corepack_js(real_target) if os.path.basename(dest) == "pnpm" else None
    if cp_js:
        exec_line = f'COREPACK_ENABLE_DOWNLOAD_PROMPT=0 exec node {shlex.quote(cp_js)} pnpm@10.33.2 "$@"'
    else:
        exec_line = f'exec node {shlex.quote(real_target)} "$@"'
    body = "\n".join(WRAP_LINES + [exec_line, ""])
    with open(dest, "w", encoding="utf-8") as out:
        out.write(body)
    os.chmod(dest, 0o755)

for name in ("pnpm", "pnpx", "corepack"):
    shim_p = os.path.join(shim_dir, name)
    if os.path.islink(shim_p):
        real_t = os.path.realpath(shim_p)
        if os.path.isfile(real_t):
            try:
                with open(real_t, "rb") as f:
                    first = f.readline()
                if first.startswith(b"#!") and b"node" in first:
                    write_wrapper(shim_p, real_t)
            except OSError:
                pass
        else:
            try:
                os.unlink(shim_p)
            except OSError:
                pass
    elif os.path.isfile(shim_p):
        try:
            with open(shim_p, "r", encoding="utf-8", errors="ignore") as f:
                lines = [l.strip() for l in f.read(512).splitlines()]
            if len(lines) >= 3 and lines[1] == "# open-design node24 shim" and "exec node " in lines[2]:
                after_exec = lines[2].split("exec node ", 1)[1]
                cmd_parts = shlex.split(after_exec)
                if cmd_parts and not os.path.isfile(cmd_parts[0]):
                    os.unlink(shim_p)
                elif name == "pnpm" and cmd_parts and "pnpm@10.33.2" not in lines[2] and resolve_corepack_js(cmd_parts[0]):
                    write_wrapper(shim_p, cmd_parts[0])
        except OSError:
            pass

    if not os.path.exists(shim_p):
        found = shutil.which(name)
        if found:
            real_f = os.path.realpath(found)
            if os.path.isfile(real_f):
                try:
                    with open(real_f, "rb") as f:
                        first = f.readline()
                    if first.startswith(b"#!"):
                        toks = first[2:].decode("utf-8", errors="ignore").strip().split()
                        if toks and os.path.basename(toks[0]) != "env" and "node" in os.path.basename(toks[0]):
                            if name == "corepack" or is_valid_pnpm_target(real_f, name):
                                write_wrapper(shim_p, real_f)
                except OSError:
                    pass
PYSHIM
    if [ -d "$NODE_SHIM_DIR" ]; then
      prepend_dir_to_path "$NODE_SHIM_DIR"
    fi
  fi

  # Append generic version-manager shims as fallbacks after system PATH
  local dir=""
  for dir in \
    "$HOME/.local/share/fnm/current/bin" \
    "$HOME/.local/share/mise/shims" \
    "$HOME/.asdf/shims" \
    "$HOME/.volta/bin" \
    $(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -n 1 || true); do
    if [ -n "$dir" ] && [ -d "$dir" ]; then
      case ":$PATH:" in
        *":$dir:"*) ;;
        *) PATH="$PATH:$dir" ;;
      esac
    fi
  done
  export PATH
  hash -r 2>/dev/null || true
}
refresh_user_node_paths

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_TARGET="$HOME/.local/bin/open-design"
ICON_TARGET="$HOME/.local/share/icons/hicolor/512x512/apps/open_design.png"
UPDATER_ICON_TARGET="$HOME/.local/share/icons/hicolor/512x512/apps/open_design_updater.png"
DESKTOP_TARGET="$HOME/.local/share/applications/open_design.desktop"
UPDATER_DESKTOP_TARGET="$HOME/.local/share/applications/org.opendesign.Updater.desktop"
CONFIG_DIR="$HOME/.config/open-design"
CONFIG_FILE="$CONFIG_DIR/config"
DEFAULT_PWA_DIR="$HOME/.config/open-design-pwa"
UPSTREAM_URL="https://github.com/nexu-io/open-design.git"

LOADER_PID=""
LOADER_LOG=""
TERM_RESIZED=0
CACHED_COLS=80

cleanup() {
  if [ -t 1 ]; then
    printf "\033[?7h" 2>/dev/null || true
    tput cnorm 2>/dev/null || true
  fi
  if [ -n "${LOADER_LOG:-}" ] && [ -f "$LOADER_LOG" ]; then
    rm -f "$LOADER_LOG"
  fi
}

on_interrupt() {
  if [ -n "${LOADER_PID:-}" ]; then
    kill -TERM -"$LOADER_PID" 2>/dev/null || pkill -TERM -P "$LOADER_PID" 2>/dev/null || true
    kill -TERM "$LOADER_PID" 2>/dev/null || true
    wait "$LOADER_PID" 2>/dev/null || true
  fi
  cleanup
  printf "\n%sInstallation cancelled.%s\n" "$C_YELLOW" "$C_RESET" >&2
  exit 130
}

get_term_cols() {
  local cols=""
  if [ -t 1 ]; then
    cols="$(stty size </dev/tty 2>/dev/null | cut -d' ' -f2 || true)"
  fi
  if [ -z "$cols" ] || ! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -le 0 ]; then
    cols="${COLUMNS:-80}"
  fi
  printf '%s' "$cols"
}

CACHED_COLS="$(get_term_cols)"

trap cleanup EXIT
trap on_interrupt INT TERM
trap 'TERM_RESIZED=1; CACHED_COLS="$(get_term_cols)"' WINCH

run_with_loader() {
  local active_msg="$1"
  local done_msg="$2"
  shift 2
  LOADER_LOG="$(mktemp "${TMPDIR:-/tmp}/open-design-install.XXXXXX")"
  local start_ts=$SECONDS

  if [ -t 1 ]; then
    set -m
    "$@" </dev/null >"$LOADER_LOG" 2>&1 &
    LOADER_PID=$!
    set +m
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local tick=0
    CACHED_COLS="$(get_term_cols)"
    tput civis 2>/dev/null || true
    printf "\033[?7l" 2>/dev/null || true
    while kill -0 "$LOADER_PID" 2>/dev/null; do
      if [ "$TERM_RESIZED" -eq 1 ] || [ $((tick % 10)) -eq 0 ]; then
        TERM_RESIZED=0
        CACHED_COLS="$(get_term_cols)"
      fi
      local f="${frames[$((tick % 10))]}"
      local elapsed=$((SECONDS - start_ts))
      local suffix="... [${elapsed}s]"
      local cols="${CACHED_COLS:-80}"
      local max_msg=$((cols - ${#suffix} - 6))
      local shown_msg="$active_msg"
      if [ "$max_msg" -lt 4 ]; then
        shown_msg=""
        suffix="[${elapsed}s]"
      elif [ "${#shown_msg}" -gt "$max_msg" ]; then
        shown_msg="${shown_msg:0:$max_msg}"
      fi
      if [ -n "$shown_msg" ]; then
        printf "\r\033[2K  %s%s%s %s... %s[%ds]%s\r" "$C_CYAN" "$f" "$C_RESET" "$shown_msg" "$C_DIM" "$elapsed" "$C_RESET"
      else
        printf "\r\033[2K  %s%s%s %s%s%s\r" "$C_CYAN" "$f" "$C_RESET" "$C_DIM" "$suffix" "$C_RESET"
      fi
      sleep 0.08 || true
      tick=$((tick + 1))
    done
    printf "\033[?7h" 2>/dev/null || true
    tput cnorm 2>/dev/null || true
    local rc=0
    while :; do
      rc=0
      wait "$LOADER_PID" || rc=$?
      if [ "$rc" -eq 156 ] && kill -0 "$LOADER_PID" 2>/dev/null; then
        continue
      fi
      break
    done
    LOADER_PID=""
    local total_s=$((SECONDS - start_ts))
    if [ "$rc" -eq 0 ]; then
      printf "\r\033[2K  %s✓%s %s %s(%ds)%s\n" "$C_GREEN" "$C_RESET" "$done_msg" "$C_DIM" "$total_s" "$C_RESET"
      rm -f "$LOADER_LOG"
      LOADER_LOG=""
      return 0
    else
      printf "\r\033[2K  %s✗%s %s failed %s(%ds)%s\n" "$C_RED" "$C_RESET" "$active_msg" "$C_DIM" "$total_s" "$C_RESET" >&2
      cat "$LOADER_LOG" >&2
      rm -f "$LOADER_LOG"
      LOADER_LOG=""
      return "$rc"
    fi
  else
    printf "  → %s...\n" "$active_msg"
    if "$@" </dev/null >"$LOADER_LOG" 2>&1; then
      printf "  ✓ %s\n" "$done_msg"
      rm -f "$LOADER_LOG"
      LOADER_LOG=""
      return 0
    else
      local rc=$?
      printf "  ✗ %s failed\n" "$active_msg" >&2
      cat "$LOADER_LOG" >&2
      rm -f "$LOADER_LOG"
      LOADER_LOG=""
      return "$rc"
    fi
  fi
}

valid_port() {
  local p="${1//[[:space:]]/}"
  case "$p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$((10#$p))" -ge 1 ] && [ "$((10#$p))" -le 65535 ]
}

valid_host() {
  local h="${1//[[:space:]]/}"
  [ "$h" = "127.0.0.1" ] || [ "$h" = "localhost" ]
}

# Load existing configuration (if present)
FILE_REPO="$HOME/open-design"
FILE_HOST="127.0.0.1"
FILE_PORT="3000"
FILE_BROWSER=""
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
      OPEN_DESIGN_HOST)    valid_host "$val" && FILE_HOST="$val" ;;
      OPEN_DESIGN_PORT)    valid_port "$val" && FILE_PORT="$val" ;;
      OPEN_DESIGN_BROWSER) FILE_BROWSER="$val" ;;
      OPEN_DESIGN_PWA_DIR) FILE_PWA_DIR="${val/#\~/$HOME}" ;;
    esac
  done < "$CONFIG_FILE"
fi

CFG_REPO="${OPEN_DESIGN_REPO:-$FILE_REPO}"
CFG_REPO="${CFG_REPO/#\~/$HOME}"
CFG_HOST="${FILE_HOST//[[:space:]]/}"
if [ -n "${OPEN_DESIGN_HOST:-}" ] && valid_host "$OPEN_DESIGN_HOST"; then
  CFG_HOST="${OPEN_DESIGN_HOST//[[:space:]]/}"
fi
CFG_PORT="${FILE_PORT//[[:space:]]/}"
if [ -n "${OPEN_DESIGN_PORT:-}" ] && valid_port "$OPEN_DESIGN_PORT"; then
  CFG_PORT="${OPEN_DESIGN_PORT//[[:space:]]/}"
fi
CFG_BROWSER="${OPEN_DESIGN_BROWSER:-}"
CFG_PWA_DIR="${OPEN_DESIGN_PWA_DIR:-$FILE_PWA_DIR}"
CFG_PWA_DIR="${CFG_PWA_DIR/#\~/$HOME}"

canonical_path() {
  python3 -I -c 'import os, sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$1" 2>/dev/null || printf '%s' "${1%/}"
}

paths_overlap() {
  local r1 r2
  r1="$(canonical_path "$1")"
  r2="$(canonical_path "$2")"
  [ "$r1" = "$r2" ] || [[ "$r1" == "$r2/"* ]] || [[ "$r2" == "$r1/"* ]]
}

REAL_HOME="$(canonical_path "$HOME")"
REAL_CFG_REPO="$(canonical_path "$CFG_REPO")"
case "$REAL_CFG_REPO" in
  ""|"/"|"$REAL_HOME"|"$REAL_HOME/.config"|"$REAL_HOME/.local"|"$REAL_HOME/.local/share")
    CFG_REPO="$HOME/open-design"
    ;;
esac
if paths_overlap "$CFG_REPO" "$CONFIG_DIR" || paths_overlap "$CFG_REPO" "$DEFAULT_PWA_DIR" || paths_overlap "$CFG_REPO" "$HOME/.local/share/open-design"; then
  echo "${C_YELLOW}Warning:${C_RESET} OPEN_DESIGN_REPO cannot overlap with Open Design config or profile directories; using ~/open-design." >&2
  CFG_REPO="$HOME/open-design"
fi

REAL_CFG_PWA="$(canonical_path "$CFG_PWA_DIR")"
case "$REAL_CFG_PWA" in
  ""|"/"|"$REAL_HOME"|"$REAL_HOME/.config"|"$REAL_HOME/.local"|"$REAL_HOME/.local/share")
    CFG_PWA_DIR="$DEFAULT_PWA_DIR"
    ;;
esac
if [ -L "${CFG_PWA_DIR%/}" ]; then
  echo "${C_RED}Error:${C_RESET} Configured profile directory '$CFG_PWA_DIR' must not be a symlink." >&2
  exit 1
fi
if paths_overlap "$CFG_PWA_DIR" "$CFG_REPO" || paths_overlap "$CFG_PWA_DIR" "$HOME/open-design" || paths_overlap "$CFG_PWA_DIR" "$CONFIG_DIR" || paths_overlap "$CFG_PWA_DIR" "$HOME/.local/share/open-design"; then
  echo "${C_YELLOW}Warning:${C_RESET} OPEN_DESIGN_PWA_DIR cannot overlap with the repository or config directories; using ~/.config/open-design-pwa." >&2
  CFG_PWA_DIR="$DEFAULT_PWA_DIR"
fi

is_native_browser_bin() {
  local p
  p="$(command -v "$1" 2>/dev/null || true)"
  [ -n "$p" ] && [ -x "$p" ] || return 1
  case "$p" in
    /snap/*|*/snap/*|*flatpak*) return 1 ;;
  esac
  local real_p
  real_p="$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")"
  case "$real_p" in
    /snap/*|*/snap/*|*flatpak*) return 1 ;;
  esac
  if [ -f "$p" ] && head -c 512 "$p" 2>/dev/null | grep -qiE '/snap/|snap run|flatpak'; then
    return 1
  fi
  return 0
}

has_chrome() {
  is_native_browser_bin google-chrome-stable || is_native_browser_bin google-chrome
}
has_chromium() {
  is_native_browser_bin chromium-browser || is_native_browser_bin chromium
}
has_brave_std() {
  is_native_browser_bin brave-browser || is_native_browser_bin brave
}
has_brave_origin() {
  [ -x "/opt/brave.com/brave-origin/brave" ] || is_native_browser_bin brave-origin-stable || is_native_browser_bin brave-origin
}
has_edge() {
  is_native_browser_bin microsoft-edge-stable || is_native_browser_bin microsoft-edge
}

is_browser_installed() {
  case "${1:-}" in
    google-chrome)  has_chrome ;;
    chromium)       has_chromium ;;
    brave)          has_brave_std ;;
    brave-origin)   has_brave_origin ;;
    microsoft-edge) has_edge ;;
    *) return 1 ;;
  esac
}

desktop_to_browser() {
  case "${1:-}" in
    *google-chrome*|*chrome*) has_chrome && echo "google-chrome" && return ;;
    *chromium*)               has_chromium && echo "chromium" && return ;;
    *brave*origin*)           has_brave_origin && echo "brave-origin" && return ;;
    *brave*)
      if has_brave_std; then echo "brave"; return; fi
      if has_brave_origin; then echo "brave-origin"; return; fi
      ;;
    *microsoft-edge*|*msedge*) has_edge && echo "microsoft-edge" && return ;;
  esac
  echo ""
}

detect_default_desktop() {
  local desktop=""
  if command -v xdg-settings >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      desktop="$(timeout 2 xdg-settings get default-web-browser 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    else
      desktop="$(xdg-settings get default-web-browser 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    fi
  fi
  if [ -z "$desktop" ] && command -v xdg-mime >/dev/null 2>&1; then
    if command -v timeout >/dev/null 2>&1; then
      desktop="$(timeout 2 xdg-mime query default x-scheme-handler/http 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    else
      desktop="$(xdg-mime query default x-scheme-handler/http 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    fi
  fi
  printf '%s' "$desktop"
}

browser_label() {
  case "$1" in
    google-chrome)  echo "Google Chrome" ;;
    chromium)       echo "Chromium" ;;
    brave)          echo "Brave Browser" ;;
    brave-origin)   echo "Brave Origin" ;;
    microsoft-edge) echo "Microsoft Edge" ;;
    *) echo "$1" ;;
  esac
}

AVAILABLE_BROWSERS=()
AVAILABLE_LABELS=()
for candidate in google-chrome chromium brave brave-origin microsoft-edge; do
  if is_browser_installed "$candidate"; then
    AVAILABLE_BROWSERS+=("$candidate")
    AVAILABLE_LABELS+=("$(browser_label "$candidate")")
  fi
done

has_python310() {
  command -v python3 >/dev/null 2>&1 && \
  python3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)" >/dev/null 2>&1
}

has_gi_deps() {
  has_python310 && \
  python3 -c "import gi; gi.require_version('Gtk', '4.0'); gi.require_version('Adw', '1'); from gi.repository import Gtk, Adw; import cairo" >/dev/null 2>&1
}

has_node24() {
  command -v node >/dev/null 2>&1 && \
  node -e 'process.exit(parseInt(process.versions.node, 10) === 24 ? 0 : 1)' >/dev/null 2>&1
}

is_user_managed_node() {
  local node_path
  node_path="$(command -v node 2>/dev/null || true)"
  case "$node_path" in
    "$HOME"/*) return 0 ;;
    *) return 1 ;;
  esac
}

run_with_node24() {
  local target_bin="$1"
  shift
  [ -n "$target_bin" ] || return 1
  local real_bin
  real_bin="$(readlink -f "$target_bin" 2>/dev/null || printf '%s' "$target_bin")"
  if [ -f "$real_bin" ] && head -n 1 "$real_bin" 2>/dev/null | grep -q '^#!.*node'; then
    node "$real_bin" "$@"
  else
    "$target_bin" "$@"
  fi
}

has_valid_pnpm() {
  has_node24 && command -v pnpm >/dev/null 2>&1 && \
  python3 -I - <<'PYPNPM' >/dev/null 2>&1
import os, re, shutil, subprocess, sys, tempfile

pnpm_bin = shutil.which("pnpm")
if not pnpm_bin:
    sys.exit(1)

real_pnpm = os.path.realpath(pnpm_bin)
if os.path.isfile(real_pnpm):
    try:
        with open(real_pnpm, "rb") as f:
            first = f.readline()
        if first.startswith(b"#!"):
            toks = first[2:].decode("utf-8", errors="ignore").strip().split()
            if toks and os.path.basename(toks[0]) != "env" and "node" in os.path.basename(toks[0]):
                interp = toks[0]
                r = subprocess.run([interp, "--version"], capture_output=True, text=True, timeout=3)
                m_n = re.match(r"^v?(\d+)\.", r.stdout.strip())
                if not m_n or int(m_n.group(1)) != 24:
                    sys.exit(1)
    except Exception:
        sys.exit(1)

fd, probe = tempfile.mkstemp(prefix="od-n24-", suffix=".cjs", dir="/tmp")
with os.fdopen(fd, "w", encoding="utf-8") as pf:
    pf.write("if (parseInt(process.versions.node, 10) !== 24) { process.exit(42); }\n")
os.chmod(probe, 0o600)
try:
    env = os.environ.copy()
    prev_opts = env.get("NODE_OPTIONS", "").strip()
    env["NODE_OPTIONS"] = f"{prev_opts} --require {probe}".strip()
    res = subprocess.run([pnpm_bin, "--version"], env=env, capture_output=True, text=True, timeout=8)
    if res.returncode != 0:
        sys.exit(1)
    m = re.match(r"^(\d+)\.(\d+)\.(\d+)", res.stdout.strip())
    v = tuple(map(int, m.groups())) if m else ()
    sys.exit(0 if (10, 33, 2) <= v < (11, 0, 0) else 1)
finally:
    try:
        os.unlink(probe)
    except OSError:
        pass
PYPNPM
}

MISSING_ITEMS=()
collect_missing_deps() {
  MISSING_ITEMS=()
  if ! command -v git >/dev/null 2>&1; then
    MISSING_ITEMS+=("git")
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    MISSING_ITEMS+=("python3 3.10+")
  elif ! has_python310; then
    MISSING_ITEMS+=("python3 3.10+ (found $(python3 --version 2>/dev/null || echo unknown))")
  elif ! has_gi_deps; then
    MISSING_ITEMS+=("PyGObject, GTK4, Libadwaita, and pycairo")
  fi
  if ! command -v notify-send >/dev/null 2>&1; then
    MISSING_ITEMS+=("libnotify (notify-send)")
  fi
  if ! command -v node >/dev/null 2>&1; then
    MISSING_ITEMS+=("Node.js 24.x LTS (not found)")
  elif ! has_node24; then
    MISSING_ITEMS+=("Node.js 24.x LTS (found $(node --version 2>/dev/null || echo unknown))")
  fi
  if ! command -v pnpm >/dev/null 2>&1; then
    MISSING_ITEMS+=("pnpm 10.x (>=10.33.2, not found)")
  elif ! has_valid_pnpm; then
    MISSING_ITEMS+=("pnpm 10.x (>=10.33.2, found $(pnpm --version 2>/dev/null || echo unknown))")
  fi
  [ "${#MISSING_ITEMS[@]}" -eq 0 ]
}

print_manual_dep_hints() {
  if ! has_node24 || ! has_valid_pnpm; then
    echo "  To install Node.js 24 LTS and pnpm manually:" >&2
    if command -v pacman >/dev/null 2>&1; then
      echo "    sudo pacman -S --needed nodejs-lts-krypton npm && npm install -g --prefix ~/.local/share/open-design pnpm@10.33.2" >&2
    elif command -v dnf >/dev/null 2>&1; then
      echo "    sudo dnf install nodejs24 nodejs-corepack && mkdir -p ~/.local/share/open-design/bin && ln -sf /usr/bin/node-24 ~/.local/share/open-design/bin/node && PATH=\"\$HOME/.local/share/open-design/bin:\$PATH\" /usr/bin/node-24 /usr/bin/corepack enable --install-directory ~/.local/share/open-design/bin pnpm && PATH=\"\$HOME/.local/share/open-design/bin:\$PATH\" /usr/bin/node-24 /usr/bin/corepack prepare pnpm@10.33.2 --activate" >&2
    else
      echo "    Install Node.js 24 LTS via nvm/fnm/mise (or NodeSource) and activate pnpm 10.33.2+ via Corepack." >&2
    fi
  fi
}

offer_package_install() {
  [ -t 0 ] || return 1

  local pkg_mgr=""
  local pkgs=()
  if command -v dnf >/dev/null 2>&1; then
    pkg_mgr="dnf"
    command -v git >/dev/null 2>&1 || pkgs+=("git")
    has_python310 || pkgs+=("python3")
    has_gi_deps || pkgs+=("python3-gobject" "gtk4" "libadwaita" "python3-cairo")
    command -v notify-send >/dev/null 2>&1 || pkgs+=("libnotify")
    if ! has_node24 && ! is_user_managed_node; then
      pkgs+=("nodejs24")
    fi
    if ! has_valid_pnpm && ! command -v corepack >/dev/null 2>&1; then
      pkgs+=("nodejs-corepack")
    fi
  elif command -v pacman >/dev/null 2>&1; then
    pkg_mgr="pacman"
    command -v git >/dev/null 2>&1 || pkgs+=("git")
    has_python310 || pkgs+=("python")
    has_gi_deps || pkgs+=("python-gobject" "gtk4" "libadwaita" "python-cairo")
    command -v notify-send >/dev/null 2>&1 || pkgs+=("libnotify")
    if ! has_node24 && ! is_user_managed_node; then
      pkgs+=("nodejs-lts-krypton")
    fi
    if ! has_valid_pnpm && ! command -v corepack >/dev/null 2>&1 && ! command -v npm >/dev/null 2>&1; then
      pkgs+=("npm")
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    pkg_mgr="apt-get"
    command -v git >/dev/null 2>&1 || pkgs+=("git")
    has_python310 || pkgs+=("python3")
    has_gi_deps || pkgs+=("python3-gi" "python3-gi-cairo" "gir1.2-gtk-4.0" "gir1.2-adw-1")
    command -v notify-send >/dev/null 2>&1 || pkgs+=("libnotify-bin")
  fi

  local prompted=0
  if [ "${#pkgs[@]}" -gt 0 ] && command -v sudo >/dev/null 2>&1; then
    prompted=1
    local cmd_str=""
    case "$pkg_mgr" in
      dnf)     cmd_str="sudo dnf install ${pkgs[*]}" ;;
      pacman)  cmd_str="sudo pacman -S --needed ${pkgs[*]}" ;;
      apt-get) cmd_str="sudo apt-get install ${pkgs[*]}" ;;
    esac
    printf "  Install missing packages with '%s'? [Y/n]: " "$cmd_str"
    local reply=""
    read -r reply || reply=""
    case "$reply" in
      ""|[yY]|[yY][eE][sS])
        local pkg_rc=0
        case "$pkg_mgr" in
          dnf)     sudo dnf install "${pkgs[@]}" || pkg_rc=$? ;;
          pacman)  sudo pacman -S --needed "${pkgs[@]}" || pkg_rc=$? ;;
          apt-get) sudo apt-get install "${pkgs[@]}" || pkg_rc=$? ;;
        esac
        if [ "$pkg_rc" -ne 0 ]; then
          echo "${C_RED}Error:${C_RESET} System package installation failed. Fix the package manager error above, then re-run ./install.sh." >&2
          exit 1
        fi
        refresh_user_node_paths
        ;;
      *)
        echo "Installation cancelled." >&2
        exit 1
        ;;
    esac
  fi

  local nvm_sh="${NVM_DIR:-$HOME/.nvm}/nvm.sh"
  if ! has_node24; then
    local nm_label=""
    local nm_kind=""
    if command -v mise >/dev/null 2>&1; then
      nm_label="mise install node@24"
      nm_kind="mise"
    elif command -v fnm >/dev/null 2>&1; then
      nm_label="fnm install 24"
      nm_kind="fnm"
    elif [ -s "$nvm_sh" ]; then
      nm_label="nvm install 24"
      nm_kind="nvm"
    fi
    if [ -n "$nm_kind" ]; then
      prompted=1
      printf "  Install Node.js 24 LTS with '%s'? [Y/n]: " "$nm_label"
      local nm_reply=""
      read -r nm_reply || nm_reply=""
      case "$nm_reply" in
        ""|[yY]|[yY][eE][sS])
          case "$nm_kind" in
            mise) mise install node@24 || return 1 ;;
            fnm)  fnm install 24 || return 1 ;;
            nvm)  bash -c ". \"$nvm_sh\" && nvm install 24 --no-use" || bash -c ". \"$nvm_sh\" && nvm install 24" || return 1 ;;
          esac
          refresh_user_node_paths
          ;;
        *)
          echo "Installation cancelled." >&2
          exit 1
          ;;
      esac
    elif has_python310; then
      prompted=1
      printf "  Download isolated Node.js 24 LTS for Open Design (~/.local/share/open-design/node-v24)? [Y/n]: "
      local dl_reply=""
      read -r dl_reply || dl_reply=""
      case "$dl_reply" in
        ""|[yY]|[yY][eE][sS])
          install_isolated_node24() {
            python3 - "$APP_NODE24_DIR" <<'PY'
import hashlib, os, platform, shutil, sys, tarfile, tempfile, urllib.request

dest_dir = sys.argv[1]
mach = platform.machine().lower()
arch = "x64" if mach in ("x86_64", "amd64") else ("arm64" if mach in ("aarch64", "arm64") else "")
if not arch:
    sys.exit(f"Unsupported architecture: {mach}")

# Pinned Node.js 24 LTS releases and official PGP-signed SHA256 digests
PINNED_RELEASES = {
    "v24.11.0": {
        "x64": "b3c071cdf47aab867c3b2aa287257df12ec5d7c962bf922b32fd33226c4295fd",
        "arm64": "4786d00c4d259d3ff0b2328307f764ef3ced65f2d6e9502d433e68d66238509d",
    },
    "v24.22.1": {
        "x64": "eb6728e77c576a35162c122c45ccadf224d89ff00abc8dae46cc2897c6002d7c",
        "arm64": "33c37be234ba8bee041961047b19160f4d7d0f164e8e246f78bdd10feff148b3",
    },
}

node_ver = os.environ.get("OPEN_DESIGN_NODE24_VERSION", "v24.22.1").strip()
if not node_ver.startswith("v"):
    node_ver = "v" + node_ver
expected_sha = os.environ.get("OPEN_DESIGN_NODE24_SHA256", "").strip() or PINNED_RELEASES.get(node_ver, {}).get(arch, "")
if not expected_sha:
    sys.exit(f"No pinned SHA256 digest configured for Node.js {node_ver} ({arch}); set OPEN_DESIGN_NODE24_SHA256.")

tar_name = f"node-{node_ver}-linux-{arch}.tar.gz"
download_url = f"https://nodejs.org/dist/{node_ver}/{tar_name}"

tmp_dir = tempfile.mkdtemp(prefix="open-design-node24-")
try:
    tar_path = os.path.join(tmp_dir, tar_name)
    with urllib.request.urlopen(download_url, timeout=120) as resp, open(tar_path, "wb") as out:
        shutil.copyfileobj(resp, out)
    actual_sha = hashlib.sha256(open(tar_path, "rb").read()).hexdigest()
    if actual_sha.lower() != expected_sha.lower():
        sys.exit("SHA256 checksum mismatch for " + tar_name)
    with tarfile.open(tar_path, "r:gz") as tf:
        for member in tf.getmembers():
            member_path = os.path.abspath(os.path.join(tmp_dir, member.name))
            if not member_path.startswith(os.path.abspath(tmp_dir) + os.sep):
                sys.exit("Refusing to extract archive with unsafe path: " + member.name)
        tf.extractall(tmp_dir)
    extracted_root = os.path.join(tmp_dir, tar_name[:-len(".tar.gz")])
    os.makedirs(os.path.dirname(dest_dir), mode=0o700, exist_ok=True)
    if os.path.exists(dest_dir):
        shutil.rmtree(dest_dir)
    shutil.move(extracted_root, dest_dir)
finally:
    shutil.rmtree(tmp_dir, ignore_errors=True)
PY
          }
          run_with_loader \
            "Downloading Node.js 24 LTS runtime" \
            "Installed isolated Node.js 24 LTS runtime" \
            install_isolated_node24
          refresh_user_node_paths
          ;;
        *)
          echo "Installation cancelled." >&2
          exit 1
          ;;
      esac
    fi
  fi

  if has_node24 && ! has_valid_pnpm && { command -v corepack >/dev/null 2>&1 || command -v npm >/dev/null 2>&1; }; then
    prompted=1
    printf "  Install isolated pnpm 10.33.2 for Open Design (~/.local/share/open-design/bin)? [Y/n]: "
    local cp_reply=""
    read -r cp_reply || cp_reply=""
    case "$cp_reply" in
      ""|[yY]|[yY][eE][sS])
        mkdir -p "$NODE_SHIM_DIR"
        chmod 700 "$HOME/.local/share/open-design" "$NODE_SHIM_DIR" 2>/dev/null || true
        if command -v corepack >/dev/null 2>&1; then
          run_with_node24 "$(command -v corepack)" enable --install-directory "$NODE_SHIM_DIR" pnpm >/dev/null 2>&1 || return 1
          refresh_user_node_paths
          run_with_node24 "$(command -v corepack)" prepare pnpm@10.33.2 --activate >/dev/null 2>&1 || return 1
          refresh_user_node_paths
        else
          run_with_node24 "$(command -v npm)" install --global --prefix "$HOME/.local/share/open-design" pnpm@10.33.2 >/dev/null 2>&1 || return 1
          refresh_user_node_paths
        fi
        hash -r 2>/dev/null || true
        ;;
      *)
        echo "Installation cancelled." >&2
        exit 1
        ;;
    esac
  fi

  [ "$prompted" -eq 1 ]
}

echo "${C_BOLD}Open Design Desktop Installer${C_RESET}"
echo ""
echo "${C_DIM}[1/4]${C_RESET} Checking system requirements..."

if [ "$SKIP_CHECKS" -eq 0 ]; then
  if ! collect_missing_deps; then
    echo "  Missing required dependencies:"
    for item in "${MISSING_ITEMS[@]}"; do
      echo "    - $item"
    done
    if offer_package_install; then
      if ! collect_missing_deps; then
        joined_missing=""
        printf -v joined_missing '%s, ' "${MISSING_ITEMS[@]}"
        joined_missing="${joined_missing%, }"
        echo "${C_RED}Error:${C_RESET} Required dependencies are still missing ($joined_missing)." >&2
        print_manual_dep_hints
        exit 1
      fi
    else
      print_manual_dep_hints
      echo "${C_RED}Error:${C_RESET} Install the missing dependencies above, then re-run ./install.sh." >&2
      exit 1
    fi
  fi
  if [ "$USING_FEDORA_NODE24_SHIM" -eq 1 ]; then
    echo "  ${C_GREEN}✓${C_RESET} GTK4, Libadwaita, libnotify, Git, Node.js ($(node --version) via /usr/bin/node-24), and pnpm ($(pnpm --version)) verified"
  else
    echo "  ${C_GREEN}✓${C_RESET} GTK4, Libadwaita, libnotify, Git, Node.js ($(node --version)), and pnpm ($(pnpm --version)) verified"
  fi
else
  if [ -f "$CONFIG_DIR/build-stamp" ]; then
    case "$(cat "$CONFIG_DIR/build-stamp" 2>/dev/null || true)" in
      pending:*)
        echo "${C_RED}Error:${C_RESET} Cannot use '--skip-checks' while a previous build or update is incomplete." >&2
        echo "       Re-run './install.sh' without '--skip-checks' to repair the build." >&2
        exit 1
        ;;
    esac
  fi
  if [ -f "$CFG_REPO/.open-design-build-stamp" ]; then
    case "$(cat "$CFG_REPO/.open-design-build-stamp" 2>/dev/null || true)" in
      pending:*)
        echo "${C_RED}Error:${C_RESET} Cannot use '--skip-checks' while a previous build or update is incomplete." >&2
        echo "       Re-run './install.sh' without '--skip-checks' to repair the build." >&2
        exit 1
        ;;
    esac
  fi
  echo "  ${C_GREEN}✓${C_RESET} Prerequisite checks skipped"
fi

echo "${C_DIM}[2/4]${C_RESET} Configuring browser..."

if [ -z "$REQUESTED_BROWSER" ] && [ -n "$CFG_BROWSER" ]; then
  REQUESTED_BROWSER="$CFG_BROWSER"
fi

DEFAULT_DESKTOP="$(detect_default_desktop)"
SYS_DEFAULT_BROWSER="$(desktop_to_browser "$DEFAULT_DESKTOP")"
SELECTED_BROWSER=""
SELECT_REASON=""
EXPLICIT_AUTO=0

if [ "$REQUESTED_BROWSER" = "auto" ]; then
  REQUESTED_BROWSER=""
  EXPLICIT_AUTO=1
fi

if [ -n "$REQUESTED_BROWSER" ]; then
  if is_browser_installed "$REQUESTED_BROWSER"; then
    SELECTED_BROWSER="$REQUESTED_BROWSER"
    SELECT_REASON="requested"
  else
    case "${REQUESTED_BROWSER,,}" in
      *firefox*)
        echo "${C_RED}Error:${C_RESET} Firefox on Linux does not support standalone '--app' window mode." >&2
        ;;
      *)
        echo "${C_RED}Error:${C_RESET} Browser '$REQUESTED_BROWSER' is not installed or is not supported." >&2
        echo "Supported options: google-chrome, chromium, brave, brave-origin, microsoft-edge, auto" >&2
        ;;
    esac
    if [ "${#AVAILABLE_BROWSERS[@]}" -gt 0 ]; then
      echo "Installed supported browsers on this system: ${AVAILABLE_BROWSERS[*]}" >&2
    else
      echo "Install Google Chrome, Chromium, Brave, Brave Origin, or Microsoft Edge first." >&2
    fi
    exit 1
  fi
fi

if [ -z "$SELECTED_BROWSER" ] && [ "$EXPLICIT_AUTO" -eq 0 ] && [ -n "$FILE_BROWSER" ] && [ "$FILE_BROWSER" != "auto" ]; then
  if is_browser_installed "$FILE_BROWSER"; then
    SELECTED_BROWSER="$FILE_BROWSER"
    SELECT_REASON="previous"
  fi
fi

if [ -z "$SELECTED_BROWSER" ] && [ -n "$SYS_DEFAULT_BROWSER" ]; then
  SELECTED_BROWSER="$SYS_DEFAULT_BROWSER"
  SELECT_REASON="default"
fi

if [ -z "$SELECTED_BROWSER" ]; then
  if [ "${#AVAILABLE_BROWSERS[@]}" -eq 0 ]; then
    echo "${C_RED}Error:${C_RESET} No supported Chromium-based browser found." >&2
    echo "Install Google Chrome, Chromium, Brave, Brave Origin, or Microsoft Edge, then re-run ./install.sh." >&2
    exit 1
  elif [ "${#AVAILABLE_BROWSERS[@]}" -eq 1 ] || [ "$EXPLICIT_AUTO" -eq 1 ] || [ ! -t 0 ]; then
    SELECTED_BROWSER="${AVAILABLE_BROWSERS[0]}"
    SELECT_REASON="auto"
  else
    echo "  Select a Chromium-based browser for the app window:"
    DEFAULT_IDX=1
    for i in "${!AVAILABLE_BROWSERS[@]}"; do
      printf "    %d) %s\n" "$((i + 1))" "${AVAILABLE_LABELS[$i]}"
    done
    printf "  Choice [1-%d] (Enter for %s): " "${#AVAILABLE_BROWSERS[@]}" "${AVAILABLE_LABELS[0]}"
    choice=""
    read -r choice || choice=""
    choice="$(echo "${choice:-}" | tr -d '[:space:]')"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#AVAILABLE_BROWSERS[@]}" ]; then
      DEFAULT_IDX="$choice"
    fi
    SELECTED_BROWSER="${AVAILABLE_BROWSERS[$((DEFAULT_IDX - 1))]}"
    SELECT_REASON="selected"
  fi
fi

SELECTED_LABEL="$(browser_label "$SELECTED_BROWSER")"
case "$SELECT_REASON" in
  default)   echo "  ${C_GREEN}✓${C_RESET} Browser: $SELECTED_LABEL ${C_DIM}(system default)${C_RESET}" ;;
  previous)  echo "  ${C_GREEN}✓${C_RESET} Browser: $SELECTED_LABEL ${C_DIM}(saved configuration)${C_RESET}" ;;
  *)         echo "  ${C_GREEN}✓${C_RESET} Browser: $SELECTED_LABEL" ;;
esac

is_owned_pwa_dir() {
  local raw="${1%/}"
  case "$raw" in
    ""|*".."*) return 1 ;;
  esac
  [ -d "$raw" ] && [ ! -L "$raw" ] || return 1
  local target
  target="$(cd "$raw" 2>/dev/null && pwd -P || true)"
  local clean_repo="${CFG_REPO%/}"
  if [ -d "$clean_repo" ]; then
    clean_repo="$(cd "$clean_repo" 2>/dev/null && pwd -P || printf '%s' "$clean_repo")"
  fi
  case "$target" in
    ""|/|"$HOME"|"$HOME/.config"|"$CONFIG_DIR"|"$CONFIG_DIR/"*|"$HOME/open-design"|"$HOME/open-design/"*|"$clean_repo"|"$clean_repo/"*)
      return 1
      ;;
    */open-design*|*/open_design*) ;;
    *) return 1 ;;
  esac
  case "$clean_repo" in
    "$target"|"$target/"*) return 1 ;;
  esac
  case "$HOME/open-design" in
    "$target"|"$target/"*) return 1 ;;
  esac
  [ ! -e "$target/.git" ] && [ -f "$target/.open-design-profile" ]
}

STOP_RUNNER="$SCRIPT_DIR/open-design"
if [ ! -x "$STOP_RUNNER" ] && [ -x "$BIN_TARGET" ]; then
  STOP_RUNNER="$BIN_TARGET"
fi

PREV_RESOLVED_BROWSER="$FILE_BROWSER"
if [ "$PREV_RESOLVED_BROWSER" = "auto" ]; then
  PREV_RESOLVED_BROWSER="${SYS_DEFAULT_BROWSER:-${AVAILABLE_BROWSERS[0]:-}}"
fi
RESET_PWA_ON_SWITCH=0
if [ -n "$PREV_RESOLVED_BROWSER" ] && [ "$PREV_RESOLVED_BROWSER" != "$SELECTED_BROWSER" ]; then
  RESET_PWA_ON_SWITCH=1
  if [ -x "$STOP_RUNNER" ]; then
    echo "  → Stopping previous browser session..."
    if ! "$STOP_RUNNER" --stop --quiet >/dev/null 2>&1; then
      echo "${C_RED}Error:${C_RESET} Could not stop the running Open Design session before switching browsers." >&2
      exit 1
    fi
  fi
fi

echo "${C_DIM}[3/4]${C_RESET} Preparing Open Design repository & production build..."

resolve_latest_tag() {
  local target_repo="$1"
  local remote_ref="$2"
  python3 - "$target_repo" "$remote_ref" <<'PY'
import os, re, subprocess, sys
repo, remote = sys.argv[1], sys.argv[2]
def parse_ver(t):
    raw = t.strip()
    for p in ("open-design-v", "v"):
        if raw.startswith(p):
            raw = raw[len(p):]
            break
    main_p, sep, pre_p = raw.partition("-")
    nums = [int(m.group(1)) if (m := re.match(r"^(\d+)", x)) else 0 for x in main_p.split(".")]
    while len(nums) < 3:
        nums.append(0)
    pre = tuple((0, int(p)) if p.isdigit() else (1, p.lower()) for p in re.findall(r"\d+|[A-Za-z]+", pre_p)) if sep else ()
    return (nums[0], nums[1], nums[2], 0 if sep else 1, pre)

tags = []
try:
    cmd = ["git", "ls-remote", "--tags", "--refs", remote, "refs/tags/open-design-v*"]
    cwd = repo if os.path.isdir(repo) else None
    res = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=15)
    if res.returncode == 0:
        tags = [l.split("refs/tags/", 1)[-1].strip() for l in res.stdout.splitlines() if "refs/tags/open-design-v" in l]
except Exception:
    pass
if not tags and os.path.isdir(repo):
    try:
        res = subprocess.run(["git", "tag", "-l", "open-design-v*"], cwd=repo, capture_output=True, text=True, timeout=5)
        tags = [t.strip() for t in res.stdout.splitlines() if t.strip()]
    except Exception:
        pass
pool = [t for t in tags if re.match(r"^open-design-v\d+\.\d+\.\d+$", t)]
api_override = os.environ.get("OPEN_DESIGN_RELEASES_API", "").strip()
if pool and (api_override or "nexu-io/open-design" in remote):
    import json, urllib.request
    rel_url = api_override or "https://api.github.com/repos/nexu-io/open-design/releases?per_page=30"
    try:
        req = urllib.request.Request(
            rel_url,
            headers={"Accept": "application/vnd.github+json", "User-Agent": "open-design-desktop-linux"},
        )
        with urllib.request.urlopen(req, timeout=6) as resp:
            rel_data = json.loads(resp.read().decode("utf-8", errors="replace"))
        if isinstance(rel_data, dict):
            rel_data = [rel_data]
        published = {
            r.get("tag_name", "").strip()
            for r in rel_data
            if isinstance(r, dict) and not r.get("draft") and not r.get("prerelease") and r.get("tag_name")
        }
        verified = [t for t in pool if t in published]
        if verified or api_override:
            pool = verified
    except Exception:
        if api_override:
            pool = []
if pool:
    pool.sort(key=parse_ver)
    print(pool[-1])
PY
}

DISPLAY_VER=""

if [ "$SKIP_CHECKS" -eq 0 ]; then
  REMOTE_TAG=""
  if [ ! -e "$CFG_REPO/.git" ]; then
    REMOTE_TAG="$(resolve_latest_tag "$CFG_REPO" "$UPSTREAM_URL")"
    if [ -n "$REMOTE_TAG" ]; then
      CLEAN_REMOTE_VER="${REMOTE_TAG#open-design-}"
      run_with_loader \
        "Cloning Open Design ($CLEAN_REMOTE_VER)" \
        "Cloned Open Design ($CLEAN_REMOTE_VER)" \
        git clone --depth=1 --branch "$REMOTE_TAG" "$UPSTREAM_URL" "$CFG_REPO"
    else
      run_with_loader \
        "Cloning Open Design repository" \
        "Cloned Open Design repository" \
        git clone --depth=1 "$UPSTREAM_URL" "$CFG_REPO"
    fi
    LATEST_TAG="$REMOTE_TAG"
  else
    LATEST_TAG="$(resolve_latest_tag "$CFG_REPO" "origin")"
  fi

  CURRENT_TAG="$(git -C "$CFG_REPO" describe --tags --exact-match --match "open-design-v*" 2>/dev/null || true)"
  rm -f "$CFG_REPO/.open-design-build-stamp" 2>/dev/null || true
  BUILD_STAMP_FILE="$CONFIG_DIR/build-stamp"
  STAMP_TAG=""
  if [ -f "$BUILD_STAMP_FILE" ]; then
    STAMP_TAG="$(cat "$BUILD_STAMP_FILE" 2>/dev/null || true)"
  fi
  NEEDS_BUILD="$FORCE_REBUILD"

  if [ -n "$LATEST_TAG" ] && [ "$CURRENT_TAG" != "$LATEST_TAG" ]; then
    NEEDS_BUILD=1
  fi
  if [ ! -d "$CFG_REPO/node_modules" ] || [ ! -f "$CFG_REPO/apps/web/.next/BUILD_ID" ] || [ ! -d "$CFG_REPO/apps/daemon/dist" ]; then
    NEEDS_BUILD=1
  elif [[ "$STAMP_TAG" == pending:* ]]; then
    NEEDS_BUILD=1
  elif [ -n "$STAMP_TAG" ] && [ -n "$CURRENT_TAG" ] && [ "$STAMP_TAG" != "$CURRENT_TAG" ]; then
    NEEDS_BUILD=1
  fi

  if [ "$NEEDS_BUILD" -eq 1 ] && [ -x "$STOP_RUNNER" ]; then
    if ! "$STOP_RUNNER" --stop --quiet >/dev/null 2>&1; then
      echo "${C_RED}Error:${C_RESET} Could not stop the running Open Design session before building." >&2
      exit 1
    fi
  fi

  if [ -n "$LATEST_TAG" ] && [ "$CURRENT_TAG" != "$LATEST_TAG" ]; then
    DIRTY_TREE="$(git -C "$CFG_REPO" status --porcelain 2>/dev/null || true)"
    if [ -n "$DIRTY_TREE" ]; then
      echo "${C_RED}Error:${C_RESET} Uncommitted or untracked local files detected in $CFG_REPO." >&2
      echo "       Commit, stash, or remove your local changes in $CFG_REPO before updating." >&2
      exit 1
    fi
    CLEAN_VER="${LATEST_TAG#open-design-}"
    align_repo_to_tag() {
      if ! git -C "$CFG_REPO" rev-parse -q --verify "refs/tags/$LATEST_TAG" >/dev/null 2>&1; then
        git -C "$CFG_REPO" fetch --depth=1 origin "refs/tags/$LATEST_TAG:refs/tags/$LATEST_TAG" --force -q || \
          git -C "$CFG_REPO" fetch --tags --force -q
      fi
      git -C "$CFG_REPO" checkout -f "$LATEST_TAG" --quiet
    }
    run_with_loader \
      "Aligning repository to release $CLEAN_VER" \
      "Checked out release $CLEAN_VER" \
      align_repo_to_tag
    CURRENT_TAG="$LATEST_TAG"
  fi

  ACTIVE_VER="${CURRENT_TAG#open-design-v}"
  DISPLAY_VER="${CURRENT_TAG#open-design-}"
  if [ -z "$DISPLAY_VER" ]; then
    DISPLAY_VER="latest"
  fi

  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"

  if [ "$NEEDS_BUILD" -eq 1 ]; then
    printf 'pending:%s\n' "${CURRENT_TAG:-unknown}" > "$BUILD_STAMP_FILE" 2>/dev/null || true
    install_deps() {
      (cd "$CFG_REPO" && npm_config_engine_strict=false ONNXRUNTIME_NODE_INSTALL_CUDA="${ONNXRUNTIME_NODE_INSTALL_CUDA:-skip}" ELECTRON_SKIP_BINARY_DOWNLOAD="${ELECTRON_SKIP_BINARY_DOWNLOAD:-1}" pnpm install --frozen-lockfile --prefer-offline)
    }
    build_daemon() {
      (
        cd "$CFG_REPO" && \
        NODE_OPTIONS="--max-old-space-size=4096" \
        OD_APP_VERSION="${ACTIVE_VER:-}" \
        OD_RELEASE_CHANNEL="stable" \
        pnpm --filter @open-design/daemon build
      )
    }
    build_web() {
      (
        cd "$CFG_REPO" && \
        NODE_OPTIONS="--max-old-space-size=4096" \
        OD_APP_VERSION="${ACTIVE_VER:-}" \
        OD_RELEASE_CHANNEL="stable" \
        OD_WEB_OUTPUT_MODE="server" \
        pnpm --filter @open-design/web build
      )
    }
    run_with_loader \
      "Installing workspace dependencies" \
      "Installed workspace dependencies" \
      install_deps
    run_with_loader \
      "Building daemon service (@open-design/daemon)" \
      "Built daemon service (@open-design/daemon)" \
      build_daemon
    run_with_loader \
      "Building production web interface (@open-design/web)" \
      "Built production web interface ($DISPLAY_VER)" \
      build_web
    if [ -n "$CURRENT_TAG" ]; then
      printf '%s\n' "$CURRENT_TAG" > "$BUILD_STAMP_FILE" 2>/dev/null || true
    else
      rm -f "$BUILD_STAMP_FILE" 2>/dev/null || true
    fi
  else
    if [ -n "$CURRENT_TAG" ] && [ ! -f "$BUILD_STAMP_FILE" ]; then
      printf '%s\n' "$CURRENT_TAG" > "$BUILD_STAMP_FILE" 2>/dev/null || true
    fi
    echo "  ${C_GREEN}✓${C_RESET} Production build already up to date ($DISPLAY_VER)"
  fi
else
  if [ -f "$CONFIG_DIR/build-stamp" ]; then
    case "$(cat "$CONFIG_DIR/build-stamp" 2>/dev/null || true)" in
      pending:*)
        echo "${C_RED}Error:${C_RESET} Cannot use '--skip-checks' while a previous build or update is incomplete." >&2
        echo "       Re-run './install.sh' without '--skip-checks' to repair the build." >&2
        exit 1
        ;;
    esac
  fi
  echo "  ${C_GREEN}✓${C_RESET} Repository build skipped"
fi

echo "${C_DIM}[4/4]${C_RESET} Installing desktop integration..."

case "$SELECTED_BROWSER" in
  google-chrome)      STARTUP_WM_CLASS="chrome-${CFG_HOST}__-Default" ;;
  chromium)           STARTUP_WM_CLASS="chromium-${CFG_HOST}__-Default" ;;
  brave|brave-origin) STARTUP_WM_CLASS="brave-${CFG_HOST}__-Default" ;;
  microsoft-edge)     STARTUP_WM_CLASS="msedge-${CFG_HOST}__-Default" ;;
  *)                  STARTUP_WM_CLASS="open_design" ;;
esac

if [ "$RESET_PWA_ON_SWITCH" -eq 1 ]; then
  PROFILE_RESET_DONE=0
  for dir in "$DEFAULT_PWA_DIR" "$CFG_PWA_DIR"; do
    if [ -z "$dir" ]; then
      continue
    fi
    if is_owned_pwa_dir "$dir"; then
      rm -rf -- "$dir"
      PROFILE_RESET_DONE=1
    fi
  done
  if [ "$PROFILE_RESET_DONE" -eq 1 ]; then
    echo "  ${C_GREEN}✓${C_RESET} Reset isolated app profile for $SELECTED_LABEL"
  fi
fi

DISPLAY_REPO="${CFG_REPO/#$HOME/\~}"
DISPLAY_PWA_DIR="${CFG_PWA_DIR/#$HOME/\~}"

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
{
  printf '# Open Design Desktop Configuration\n'
  printf 'OPEN_DESIGN_REPO=%s\n' "$DISPLAY_REPO"
  printf 'OPEN_DESIGN_HOST=%s\n' "$CFG_HOST"
  printf 'OPEN_DESIGN_PORT=%s\n' "$CFG_PORT"
  printf 'OPEN_DESIGN_BROWSER=%s\n' "$SELECTED_BROWSER"
  printf 'OPEN_DESIGN_PWA_DIR=%s\n' "$DISPLAY_PWA_DIR"
} > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

EXEC_VALUE="$BIN_TARGET"
case "$EXEC_VALUE" in
  *[[:space:]]*) EXEC_VALUE="\"$EXEC_VALUE\"" ;;
esac
ESCAPED_EXEC="$(printf '%s' "$EXEC_VALUE" | sed -e 's/[\/&|]/\\&/g')"
ESCAPED_WM_CLASS="$(printf '%s' "$STARTUP_WM_CLASS" | sed -e 's/[\/&|]/\\&/g')"
ESCAPED_ICON="$(printf '%s' "$ICON_TARGET" | sed -e 's/[\/&|]/\\&/g')"

mkdir -p "$HOME/.local/bin"
install -m 755 "$SCRIPT_DIR/open-design" "$BIN_TARGET"

mkdir -p "$HOME/.local/share/icons/hicolor/512x512/apps"
install -m 644 "$SCRIPT_DIR/assets/icon.png" "$ICON_TARGET"
install -m 644 "$SCRIPT_DIR/assets/icon.png" "$HOME/.local/share/icons/open_design.png"
if [ -f "$SCRIPT_DIR/assets/readme-logo.png" ]; then
  install -m 644 "$SCRIPT_DIR/assets/readme-logo.png" "$UPDATER_ICON_TARGET"
  install -m 644 "$SCRIPT_DIR/assets/readme-logo.png" "$HOME/.local/share/icons/open_design_updater.png"
fi

mkdir -p "$HOME/.local/share/applications"
sed \
  -e "s|@EXEC_PATH@|$ESCAPED_EXEC|g" \
  -e "s|@ICON_PATH@|$ESCAPED_ICON|g" \
  -e "s|@STARTUP_WM_CLASS@|$ESCAPED_WM_CLASS|g" \
  "$SCRIPT_DIR/open-design.desktop" > "$DESKTOP_TARGET"
chmod 644 "$DESKTOP_TARGET"

cat <<EOF > "$UPDATER_DESKTOP_TARGET"
[Desktop Entry]
Version=1.0
Type=Application
Name=Open Design Updater
GenericName=Update Manager
Comment=Native update manager for Open Design
Icon=$UPDATER_ICON_TARGET
Exec=$EXEC_VALUE --update
Terminal=false
Categories=Graphics;2DGraphics;
StartupWMClass=org.opendesign.Updater
NoDisplay=true
EOF
chmod 644 "$UPDATER_DESKTOP_TARGET"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
fi

echo "  ${C_GREEN}✓${C_RESET} Saved configuration to ~/.config/open-design/config"
echo "  ${C_GREEN}✓${C_RESET} Installed launcher and icons"

if [ -t 0 ]; then
  read -r -t 0.01 -n 10000 _ </dev/tty 2>/dev/null || true
fi

IN_USER_PATH=0
case ":$USER_PATH:" in
  *":$HOME/.local/bin:"*|*":$HOME/.local/bin/:"*) IN_USER_PATH=1 ;;
  *)
    echo "  ${C_YELLOW}!${C_RESET} ~/.local/bin is not in PATH ${C_DIM}(desktop launcher still works)${C_RESET}"
    ;;
esac

echo ""
if [ -n "$DISPLAY_VER" ]; then
  echo "${C_BOLD}Installation complete!${C_RESET} Open Design ($DISPLAY_VER) is configured with $SELECTED_LABEL."
else
  echo "${C_BOLD}Installation complete!${C_RESET} Open Design is configured with $SELECTED_LABEL."
fi
if [ "$IN_USER_PATH" -eq 1 ]; then
  echo "Launch it from your application launcher, dock, or terminal (${C_BOLD}open-design${C_RESET})."
else
  echo "Launch it from your application launcher, dock, or terminal (${C_BOLD}~/.local/bin/open-design${C_RESET})."
fi
