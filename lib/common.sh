# shellcheck shell=bash
#
# Shared helpers for bin/stacks. Sourced, never executed directly.

STACKS_DIR="$REPO_ROOT/stacks"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s%s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

require_cmd() {
  local missing=()
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} )); then
    die "missing required command(s): ${missing[*]}
  Ubuntu: see docs/bootstrap.md    macOS: brew install ${missing[*]}"
  fi
}

require_docker() {
  require_cmd docker
  docker compose version >/dev/null 2>&1 \
    || die "'docker compose' (Compose v2+) is not available; the legacy docker-compose binary is not supported"
}

# ---------------------------------------------------------------------------
# Stack discovery and metadata
#
# Every stack directory holds a stack.conf of shell key=value assignments. It is
# sourced in a subshell and the fields we care about are echoed back on a single
# NUL-free line, so a malformed or hostile conf can neither clobber the CLI's
# own variables nor abort it.
# ---------------------------------------------------------------------------

# all_stack_names: every directory under stacks/ holding a docker-compose.yml,
# excluding names that start with '_' (e.g. _template).
all_stack_names() {
  local d name
  for d in "$STACKS_DIR"/*/; do
    [[ -d $d ]] || continue
    name=$(basename "$d")
    [[ $name == _* ]] && continue
    [[ -f "$d/docker-compose.yml" || -f "$d/docker-compose.yaml" ]] || continue
    printf '%s\n' "$name"
  done
}

# stack_meta <name> -> sets globals: SM_ORDER SM_ENABLED SM_DESCRIPTION
#                                    SM_NETWORKS SM_WAIT SM_PROJECT SM_IMAGES
stack_meta() {
  local name=$1 dir="$STACKS_DIR/$1" raw
  [[ -d $dir ]] || die "no such stack: $name"

  # Defaults applied inside the subshell so a conf can override them but an
  # absent conf still yields sane values.
  raw=$(
    set +eu
    ORDER=50 ENABLED=1 DESCRIPTION='' NETWORKS='' WAIT=0 PROJECT="$name" IMAGES=''
    if [[ -f "$dir/stack.conf" ]]; then
      # shellcheck disable=SC1091
      . "$dir/stack.conf" >/dev/null 2>&1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ORDER" "$ENABLED" "$DESCRIPTION" "$NETWORKS" "$WAIT" "$PROJECT"
    printf '%s' "$IMAGES"
  ) || die "failed to read $dir/stack.conf"

  IFS=$'\t' read -r SM_ORDER SM_ENABLED SM_DESCRIPTION SM_NETWORKS SM_WAIT SM_PROJECT \
    <<<"$(head -n1 <<<"$raw")"
  SM_IMAGES=$(tail -n +2 <<<"$raw")

  [[ $SM_ORDER  =~ ^[0-9]+$ ]] || die "$name: ORDER must be an integer, got '$SM_ORDER'"
  [[ $SM_ENABLED =~ ^[01]$  ]] || die "$name: ENABLED must be 0 or 1, got '$SM_ENABLED'"
  [[ -n $SM_PROJECT ]] || SM_PROJECT=$name
}

# resolve_stacks [name...] -> ordered stack names on stdout.
#
# With no arguments: every *enabled* stack, ascending ORDER, ties alphabetical.
# With arguments: exactly those stacks in ORDER, including disabled ones (naming
# a stack explicitly is an override of ENABLED=0).
resolve_stacks() {
  local names=() n
  if (( $# )); then
    for n in "$@"; do
      [[ -d "$STACKS_DIR/$n" ]] || die "no such stack: $n (try 'stacks status')"
      names+=("$n")
    done
  else
    while IFS= read -r n; do
      [[ -n $n ]] || continue
      stack_meta "$n"
      if [[ $SM_ENABLED == 0 ]]; then
        warn "skipping disabled stack: $n"
        continue
      fi
      names+=("$n")
    done < <(all_stack_names)
  fi

  (( ${#names[@]} )) || return 0

  for n in "${names[@]}"; do
    stack_meta "$n"
    printf '%s\t%s\n' "$SM_ORDER" "$n"
  done | sort -k1,1n -k2,2 | cut -f2
}

# read_stack_list <array-name> [stack...] -- resolve_stacks into a named array.
#
# Deliberately not `mapfile`: that is a bash 4 builtin, and macOS still ships
# bash 3.2 as /bin/bash. Since this repo gets edited from a Mac and run on
# Ubuntu, a while-read loop keeps one script working in both places -- and this
# was found the hard way, by running the CLI under `env -i` to imitate systemd.
read_stack_list() {
  local __name=$1; shift
  local __line
  eval "$__name=()"
  while IFS= read -r __line; do
    [[ -n $__line ]] || continue
    eval "$__name+=(\"\$__line\")"
  done < <(resolve_stacks "$@")
}

# ---------------------------------------------------------------------------
# Networks
# ---------------------------------------------------------------------------

# Shared networks are declared `external: true` by the stacks that use them, so
# something has to create them first. Doing it here -- driven by NETWORKS= in
# stack.conf, before every `up` -- means there is no hidden ordering dependency:
# whichever stack comes up first, the network already exists.
ensure_networks() {
  local net
  for net in $1; do
    if ! docker network inspect "$net" >/dev/null 2>&1; then
      log "creating external network '$net'"
      docker network create "$net" >/dev/null
    fi
  done
}

# ---------------------------------------------------------------------------
# Compose invocation
#
# Secrets never touch the disk: `sops exec-env` decrypts straight into the
# environment of the compose child process. That covers both paths at once --
# ${VAR} interpolation in docker-compose.yml, and `environment: [VAR]`
# pass-through into the container -- because ambient environment wins over
# --env-file for interpolation.
#
# --env-file .env supplies the non-secret pinned tags. Passing it explicitly
# suppresses Compose's automatic ./.env loading, which is fine since it is the
# same file; being explicit keeps the behaviour obvious.
# ---------------------------------------------------------------------------

# sh_quote <string> -- wrap for safe reuse inside a POSIX sh command string.
#
# Deliberately not bash's `printf %q`: sops exec-env runs its command through
# /bin/sh (dash on Ubuntu), and %q emits bash-only $'...' syntax for control
# characters. Single-quote wrapping with '\'' escaping is portable for every
# possible input, newlines included.
sh_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

compose() {
  local name=$1; shift
  local dir="$STACKS_DIR/$name"

  stack_meta "$name"

  # --project-name explicitly, always. sops exec-env injects the secrets as
  # ambient environment at the highest interpolation precedence, so a stray
  # COMPOSE_PROJECT_NAME in a secrets file would otherwise silently split the
  # stack into a second project. -p outranks the environment.
  local args=(--project-name "$SM_PROJECT")
  [[ -f "$dir/.env" ]] && args+=(--env-file .env)

  if [[ -f "$dir/secrets.enc.env" ]]; then
    require_cmd sops
    # sops exec-env takes its command as one string and evaluates it with
    # /bin/sh -c, so each argument has to be quoted or `logs -f "my service"`
    # falls apart.
    local cmd='docker compose'
    local a
    for a in "${args[@]}" "$@"; do
      cmd+=" $(sh_quote "$a")"
    done
    ( cd "$dir" && sops exec-env secrets.enc.env "$cmd" )
  else
    ( cd "$dir" && docker compose "${args[@]}" "$@" )
  fi
}

# ---------------------------------------------------------------------------
# age key discovery
#
# sops looks for the default age keyfile under Go's os.UserConfigDir(), which is
# ~/Library/Application Support on macOS but ~/.config on Linux. Rather than make
# every operator remember that, probe the usual spots and export
# SOPS_AGE_KEY_FILE ourselves. An explicit SOPS_AGE_KEY_FILE always wins -- that
# is what the systemd unit sets on the VM.
# ---------------------------------------------------------------------------

find_age_key() {
  [[ -n ${SOPS_AGE_KEY:-} ]] && return 0
  if [[ -n ${SOPS_AGE_KEY_FILE:-} ]]; then
    [[ -f $SOPS_AGE_KEY_FILE ]] \
      || warn "SOPS_AGE_KEY_FILE points at a missing file: $SOPS_AGE_KEY_FILE"
    return 0
  fi
  local c
  for c in \
    /etc/isws-vm/age.key \
    "${XDG_CONFIG_HOME:-$HOME/.config}/sops/age/keys.txt" \
    "$HOME/Library/Application Support/sops/age/keys.txt"
  do
    if [[ -f $c ]]; then
      export SOPS_AGE_KEY_FILE="$c"
      return 0
    fi
  done
  return 0
}

find_age_key
