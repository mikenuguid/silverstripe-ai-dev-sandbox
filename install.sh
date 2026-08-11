#!/usr/bin/env bash
# ai-dev-sandbox installer.
#
# Installs a hardened devcontainer with a network airlock into a project.
#
#   ./install.sh --project /path/to/project [--preset php-mysql] [--interactive] [--force]
#
# Safe to re-run: an existing sandbox.conf or allowlist.txt is never clobbered.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT=""
PRESET="php-mysql"
INTERACTIVE=0
FORCE=0

die()  { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
info() { echo "  $*"; }

PRESET_FROM_FLAG=0

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project)     [ $# -ge 2 ] || die "--project requires a value"
                   PROJECT="$2"; shift 2 ;;
    --preset)      [ $# -ge 2 ] || die "--preset requires a value"
                   PRESET="$2"; PRESET_FROM_FLAG=1; shift 2 ;;
    --interactive) INTERACTIVE=1;    shift ;;
    --force)       FORCE=1;          shift ;;
    -h|--help)     usage 0 ;;
    *) die "unknown option '$1'" ;;
  esac
done

[ -n "$PROJECT" ] || usage
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd)" || die "no such directory: $PROJECT"
DEVDIR="$PROJECT/.devcontainer"

# Honour the PRESET recorded in an existing sandbox.conf when --preset was not
# given. Otherwise re-running the installer on a project would silently
# regenerate it from the default preset and replace a working stack.
if [ "$PRESET_FROM_FLAG" = "0" ] && [ -f "$DEVDIR/sandbox.conf" ]; then
  _p="$(grep -E '^[[:space:]]*PRESET=' "$DEVDIR/sandbox.conf" | head -1 | cut -d= -f2- \
        | sed 's/[[:space:]]*#.*$//' | tr -d '[:space:]"')"
  [ -n "$_p" ] && PRESET="$_p"
fi
case "$PRESET" in
  *[!a-z0-9._-]*|'') die "invalid preset name '$PRESET'" ;;
esac
PRESET_DIR="$SELF_DIR/presets/$PRESET"
[ -d "$PRESET_DIR" ] || die "unknown preset '$PRESET' (looked in $PRESET_DIR)"

# --- preflight ---------------------------------------------------------------
echo "Preflight"
command -v docker >/dev/null 2>&1 || die "docker not found. Install Docker first."
if docker info >/dev/null 2>&1; then
  info "docker: reachable"
elif getent group docker | grep -qw "$(id -un)"; then
  warn "docker daemon unreachable, but you are in the 'docker' group — log out and back in."
else
  die "cannot reach the Docker daemon. Try: sudo usermod -aG docker $(id -un), then log out and back in."
fi

command -v devcontainer >/dev/null 2>&1 \
  && info "devcontainer CLI: present" \
  || warn "devcontainer CLI not found — 'ccnet up' will not work. Install: npm i -g @devcontainers/cli"

[ -d "$PROJECT/.git" ] || warn "$PROJECT is not a git repository."

if [ -d "$DEVDIR" ] && [ "$FORCE" != "1" ]; then
  # Generated files are always refreshed; config files never are. Only refuse if
  # there is a .devcontainer we did not create, to avoid trampling someone's own.
  [ -f "$DEVDIR/sandbox.conf" ] \
    || die "$DEVDIR exists but has no sandbox.conf — not an ai-dev-sandbox install. Use --force to overwrite."
fi

# --- config ------------------------------------------------------------------
# sandbox.conf is PARSED, never sourced. It lives inside the project, which the
# sandboxed process can write to; sourcing it would let that process execute
# arbitrary commands on the HOST the next time you ran this installer.
declare -A CONF

read_conf() {
  local file="$1" line key val
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    key="$(echo "$key" | tr -d '[:space:]')"
    case "$key" in
      PRESET|PHP_VERSION|NODE_VERSION|MYSQL_VERSION|TZ|HTTP_PORT|DOCROOT|DB_NAME|DB_PASSWORD) ;;
      SANDBOX_VOLUMES|EXTRA_ENV)
        # Multi-line quoted value: accumulate until the closing quote.
        if [ "${val:0:1}" = '"' ] && [ "${val: -1}" != '"' -o ${#val} -eq 1 ]; then
          val="${val:1}"
          local more
          while IFS= read -r more || [ -n "$more" ]; do
            more="${more%$'\r'}"
            if [ "${more: -1}" = '"' ]; then val+=$'\n'"${more%\"}"; break; fi
            val+=$'\n'"$more"
          done
        fi
        ;;
      *) warn "ignoring unrecognised key '$key' in $(basename "$file")"; continue ;;
    esac
    val="${val#\"}"; val="${val%\"}"
    # Strip a trailing inline comment, but only when whitespace precedes the '#'
    # so that a value legitimately containing '#' (a password, say) survives.
    val="$(printf '%s' "$val" | sed 's/[[:space:]]\+#.*$//; s/[[:space:]]*$//; s/^[[:space:]]*//')"
    CONF["$key"]="$val"
  done < "$file"
}

# Preset defaults first, then the project's own file overrides them.
read_conf "$PRESET_DIR/defaults.conf"

mkdir -p "$DEVDIR"

if [ ! -f "$DEVDIR/sandbox.conf" ]; then
  cp "$SELF_DIR/templates/sandbox.conf.example" "$DEVDIR/sandbox.conf"
  info "created .devcontainer/sandbox.conf"
else
  info "kept existing .devcontainer/sandbox.conf"
fi

if [ ! -f "$DEVDIR/allowlist.txt" ]; then
  cp "$SELF_DIR/templates/allowlist.txt.example" "$DEVDIR/allowlist.txt"
  info "created .devcontainer/allowlist.txt"
else
  info "kept existing .devcontainer/allowlist.txt"
fi

# Read the project's own config BEFORE prompting. Doing it afterwards meant the
# prompts defaulted to preset values rather than the project's, and the rewrite
# below dropped every key it did not prompt for — silently discarding EXTRA_ENV
# and any customised SANDBOX_VOLUMES, contradicting "never clobbered" above.
read_conf "$DEVDIR/sandbox.conf"

if [ "$INTERACTIVE" = "1" ]; then
  echo "Interactive setup (blank keeps the current value)"
  for k in PHP_VERSION NODE_VERSION MYSQL_VERSION HTTP_PORT DOCROOT TZ; do
    read -r -p "  $k [${CONF[$k]:-}]: " ans
    [ -n "$ans" ] && CONF["$k"]="$ans"
  done
  {
    echo "# ai-dev-sandbox — written by install.sh --interactive"
    echo "PRESET=$PRESET"
    for k in PHP_VERSION NODE_VERSION MYSQL_VERSION TZ HTTP_PORT DOCROOT DB_NAME DB_PASSWORD; do
      echo "$k=${CONF[$k]:-}"
    done
    printf 'SANDBOX_VOLUMES="%s"\n' "${CONF[SANDBOX_VOLUMES]:-}"
    # Preserve anything not prompted for, rather than dropping it.
    [ -n "${CONF[EXTRA_ENV]:-}" ] && printf 'EXTRA_ENV="%s"\n' "${CONF[EXTRA_ENV]}"
  } > "$DEVDIR/sandbox.conf"
  info "wrote .devcontainer/sandbox.conf"
fi

# --- validate ----------------------------------------------------------------
# Values from sandbox.conf are interpolated into the generated Dockerfile and
# compose file, and that Dockerfile is then BUILT. sandbox.conf lives inside the
# project, so the sandboxed process can edit it — an unvalidated value is a way
# to get arbitrary content into a build the host runs. Constrain every scalar to
# a conservative character set.
# NOTE: these are globs, not regexes. A positive pattern like '[A-Za-z0-9._-]*'
# would be useless — '*' matches ANY string, so it accepts almost everything.
# Test for the presence of a DISALLOWED character instead.
check() {
  local key="$1" bad="$2" val="${CONF[$1]:-}"
  [ -z "$val" ] && return 0
  case "$val" in
    *[$bad]*) die "invalid $key='$val' in sandbox.conf — disallowed character" ;;
  esac
}
check PHP_VERSION   '!A-Za-z0-9._-'
check NODE_VERSION  '!0-9'
check MYSQL_VERSION '!A-Za-z0-9._-'
check TZ            '!A-Za-z0-9_+/-'
check DB_NAME       '!A-Za-z0-9_'
check DB_PASSWORD   '!A-Za-z0-9._-'
check DOCROOT       '!A-Za-z0-9._/-'
check HTTP_PORT     '!0-9'

case "${CONF[DOCROOT]:-}" in
  /*|*..*) die "DOCROOT must be a relative path without '..'" ;;
esac
_p="${CONF[HTTP_PORT]:-8080}"
{ [ "$_p" -ge 1 ] && [ "$_p" -le 65535 ]; } 2>/dev/null \
  || die "HTTP_PORT must be between 1 and 65535 (got '$_p')"

# --- derive the generated blocks ---------------------------------------------
# One list drives the Dockerfile mkdir list AND the compose volumes, so they
# cannot disagree. When they do, Docker seeds the volume as root-owned and the
# failure surfaces much later as an unwritable directory.
MKDIR_LIST=""
VOLUME_MOUNTS=""
VOLUME_DECLS=""

while IFS= read -r path; do
  path="${path%%#*}"                                # allow comments in the list
  path="$(echo "$path" | tr -d '[:space:]')"
  [ -z "$path" ] && continue
  case "$path" in
    /*)   die "SANDBOX_VOLUMES entry '$path' must be relative to the project root" ;;
    *..*) die "SANDBOX_VOLUMES entry '$path' must not contain '..'" ;;
  esac
  # A stable, docker-safe volume name derived from the path. Underscores are
  # kept: stripping them would map node_modules and nodemodules to one name.
  name="$(echo "$path" | tr '/.' '--' | tr -cd '[:alnum:]_-' | sed 's/^-*//;s/-*$//')"
  [ -n "$name" ] || die "cannot derive a volume name from '$path'"
  MKDIR_LIST+=" /workspace/$path"
  VOLUME_MOUNTS+="      - $name:/workspace/$path"$'\n'
  VOLUME_DECLS+="  $name:"$'\n'
done <<< "${CONF[SANDBOX_VOLUMES]:-}"

MKDIR_LIST="${MKDIR_LIST# }"
VOLUME_MOUNTS="${VOLUME_MOUNTS%$'\n'}"
VOLUME_DECLS="${VOLUME_DECLS%$'\n'}"
[ -n "$MKDIR_LIST" ] || die "SANDBOX_VOLUMES is empty — at least one generated directory is required"

# Warn early if the chosen host port is already taken. Otherwise the image
# builds fine and the failure only appears at start, as an opaque
# "Bind for 0.0.0.0:PORT failed: port is already allocated". Every project
# installed from the same defaults would otherwise collide on 8080.
_port="${CONF[HTTP_PORT]:-8080}"
# NOTE: the probe runs in a subshell, so fd 3 closes with it — do NOT try to
# close it here. `exec 3<&- 2>/dev/null` would apply that stderr redirection to
# the whole script, silently discarding every later warning.
if (exec 3<>"/dev/tcp/127.0.0.1/$_port") 2>/dev/null; then
  warn "port $_port is already in use — set a different HTTP_PORT in sandbox.conf,"
  warn "or the container will fail to start with 'port is already allocated'."
fi

EXTRA_ENV=""
if [ -n "${CONF[EXTRA_ENV]:-}" ]; then
  while IFS= read -r line; do
    [ -z "${line//[[:space:]]/}" ] && continue
    EXTRA_ENV+="      $(echo "$line" | sed 's/^[[:space:]]*//')"$'\n'
  done <<< "${CONF[EXTRA_ENV]}"
  EXTRA_ENV="${EXTRA_ENV%$'\n'}"
fi

# --- render ------------------------------------------------------------------
# Pure bash substitution rather than sed: values never need escaping, and
# multi-line blocks substitute cleanly.
render() {
  local src="$1" dest="$2" content
  content="$(cat "$src")"
  content="${content//@@PHP_VERSION@@/${CONF[PHP_VERSION]:-8.4}}"
  content="${content//@@NODE_VERSION@@/${CONF[NODE_VERSION]:-20}}"
  content="${content//@@MYSQL_VERSION@@/${CONF[MYSQL_VERSION]:-8.4}}"
  content="${content//@@TZ@@/${CONF[TZ]:-UTC}}"
  content="${content//@@HTTP_PORT@@/${CONF[HTTP_PORT]:-8080}}"
  content="${content//@@DOCROOT@@/${CONF[DOCROOT]:-public}}"
  content="${content//@@DB_NAME@@/${CONF[DB_NAME]:-db}}"
  content="${content//@@DB_PASSWORD@@/${CONF[DB_PASSWORD]:-root}}"
  content="${content//@@USER_UID@@/$(id -u)}"
  content="${content//@@USER_GID@@/$(id -g)}"
  content="${content//@@PROJECT_NAME@@/$(basename "$PROJECT")}"
  content="${content//@@MKDIR_LIST@@/$MKDIR_LIST}"
  content="${content//@@VOLUME_MOUNTS@@/$VOLUME_MOUNTS}"
  content="${content//@@VOLUME_DECLS@@/$VOLUME_DECLS}"
  content="${content//@@EXTRA_ENV@@/$EXTRA_ENV}"
  printf '%s\n' "$content" > "$dest"
}

echo "Generating"
render "$PRESET_DIR/Dockerfile.tmpl"          "$DEVDIR/Dockerfile"
render "$PRESET_DIR/docker-compose.yml.tmpl"  "$DEVDIR/docker-compose.yml"
render "$SELF_DIR/templates/devcontainer.json.tmpl" "$DEVDIR/devcontainer.json"
info "Dockerfile, docker-compose.yml, devcontainer.json"

# Core files are copied verbatim — never templated. They carry the security
# guarantee and must be identical in every install.
for f in init-firewall.sh net-open.sh net-close.sh zshrc; do
  cp "$SELF_DIR/core/$f" "$DEVDIR/$f"
done
chmod 0755 "$DEVDIR"/init-firewall.sh "$DEVDIR"/net-open.sh "$DEVDIR"/net-close.sh
info "core: init-firewall.sh, net-open.sh, net-close.sh, zshrc"

# --- ccnet -------------------------------------------------------------------
BINDIR="${CCNET_BINDIR:-$HOME/.local/bin}"
mkdir -p "$BINDIR"
cp "$SELF_DIR/bin/ccnet" "$BINDIR/ccnet"
chmod 0755 "$BINDIR/ccnet"
info "ccnet installed to $BINDIR/ccnet"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) warn "$BINDIR is not on your PATH. Add: export PATH=\"\$PATH:$BINDIR\"" ;;
esac

cat <<EOF

Installed into $PROJECT

Next steps
  1. Review .devcontainer/sandbox.conf and allowlist.txt
  2. cd $PROJECT && ccnet up
  3. ccnet open            # host terminal — needed to install dependencies
  4. ccnet shell           # then install deps inside
  5. ccnet close           # before any unattended run
  6. ccnet status          # should read: closed ... (enforced)

Changing configuration later
  allowlist.txt   edit, then 'ccnet rebuild' (copied into the image verbatim)
  sandbox.conf    edit, re-run this installer, THEN 'ccnet rebuild' — its values
                  are compiled into the generated Dockerfile and compose file, so
                  a rebuild alone quietly gives you the old stack back.
  See docs/configuration.md.
EOF
