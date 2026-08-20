# shellcheck shell=bash
#
# Anonymous container-registry tag queries for `stacks bump`.
#
# Every function here prints candidate tags one per line, unfiltered and
# unsorted. Filtering (against the per-image regex from stack.conf) and
# selection (`sort -V | tail -1`) happen in newest_tag below.

# Cap on paginated fetches. Docker Hub carries thousands of tags for popular
# images (traefik has >2500), so this bounds a bump run.
: "${REGISTRY_MAX_PAGES:=25}"

# Emitted on stdout by a _tags_* function that hit the page cap with pages still
# to go. newest_tag turns it into a hard error rather than letting a partial tag
# list masquerade as a complete one.
#
# This matters more than it looks: the OCI /tags/list endpoint returns tags in
# arbitrary order, and page 1 of docker.io/library/traefik contains ZERO v3.x.y
# tags. A truncated walk that quietly returns what it found would report
# "up to date" forever and never surface a security update.
readonly REGISTRY_TRUNCATED_SENTINEL='__registry_truncated__'


# An array, not a string: relying on unquoted word splitting would break the
# moment this file is sourced by a shell that does not split (zsh) or an option
# ever needs to contain a space.
REGISTRY_CURL_OPTS=(--silent --show-error --location --max-time 30 --retry 2)

_curl() {
  curl "${REGISTRY_CURL_OPTS[@]}" "$@"
}

# --- Docker Hub -------------------------------------------------------------
# Ordered by last_updated, so the interesting tags land on the first pages.
_tags_dockerhub() {
  local repo=$1 url page=0
  url="https://hub.docker.com/v2/repositories/$repo/tags?page_size=100&ordering=last_updated"
  while [[ -n $url && $url != null ]] && (( page < REGISTRY_MAX_PAGES )); do
    local body
    body=$(_curl "$url") || return 1
    jq -r '.results[]?.name' <<<"$body"
    url=$(jq -r '.next // ""' <<<"$body")
    page=$(( page + 1 ))
  done
  [[ -n $url && $url != null ]] && printf '%s\n' "$REGISTRY_TRUNCATED_SENTINEL"
  return 0
}

# --- Quay.io ----------------------------------------------------------------
_tags_quay() {
  local repo=$1 page=1
  while (( page <= REGISTRY_MAX_PAGES )); do
    local body
    body=$(_curl "https://quay.io/api/v1/repository/$repo/tag/?onlyActiveTags=true&limit=100&page=$page") || return 1
    jq -r '.tags[]?.name' <<<"$body"
    if [[ $(jq -r '.has_additional // false' <<<"$body") != true ]]; then
      return 0
    fi
    page=$(( page + 1 ))
  done
  printf '%s\n' "$REGISTRY_TRUNCATED_SENTINEL"
  return 0
}

# --- Generic OCI distribution API (ghcr.io, registry.k8s.io, private, ...) ---
#
# Anonymous pull tokens: hit /v2/ unauthenticated, read the realm+service out of
# the WWW-Authenticate challenge, exchange for a pull-scoped token, then list
# tags. /tags/list is NOT date-ordered, which is exactly why the semver sort in
# newest_tag is load-bearing rather than cosmetic.
_tags_oci() {
  local host=$1 repo=$2
  local challenge realm service token

  # A GET, not a HEAD: ghcr.io answers HEAD /v2/ with 405 and no
  # WWW-Authenticate header at all, so a HEAD-based probe silently finds no
  # realm and every ghcr lookup comes back empty.
  challenge=$(_curl -o /dev/null --dump-header - "https://$host/v2/" \
    | tr -d '\r' \
    | sed -n 's/^[Ww][Ww][Ww]-[Aa]uthenticate: *//p') || return 1

  realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$challenge")
  service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$challenge")

  if [[ -n $realm ]]; then
    local token_url="$realm?scope=repository:$repo:pull"
    [[ -n $service ]] && token_url+="&service=$service"
    token=$(_curl "$token_url" | jq -r '.token // .access_token // ""') || return 1
  fi

  local auth=() url="https://$host/v2/$repo/tags/list?n=100" page=0
  [[ -n ${token:-} ]] && auth=(-H "Authorization: Bearer $token")

  while [[ -n $url ]] && (( page < REGISTRY_MAX_PAGES )); do
    local hdr body next
    hdr=$(mktemp) || return 1
    body=$(_curl "${auth[@]}" --dump-header "$hdr" "$url") || { rm -f "$hdr"; return 1; }
    jq -r '.tags[]?' <<<"$body"
    # RFC 5988 Link header carries the next page as a path, not a full URL.
    next=$(tr -d '\r' <"$hdr" | sed -n 's/^[Ll]ink: *<\([^>]*\)>.*rel="next".*/\1/p')
    rm -f "$hdr"
    if [[ -n $next ]]; then
      url="https://$host${next}"
    else
      url=''
    fi
    page=$(( page + 1 ))
  done
  [[ -n $url ]] && printf '%s\n' "$REGISTRY_TRUNCATED_SENTINEL"
  return 0
}

# --- Dispatch ---------------------------------------------------------------

# registry_tags <image-ref-without-tag>
#   traefik              -> Docker Hub library/traefik
#   grafana/grafana      -> Docker Hub grafana/grafana
#   ghcr.io/ns/name      -> OCI on ghcr.io
#   quay.io/ns/name      -> Quay API
#   host:5000/ns/name    -> OCI on that host
registry_tags() {
  local ref=$1 first=${1%%/*}

  # A leading segment is a registry host only if it looks like one: contains a
  # dot or a colon, or is literally localhost. Otherwise it is a Hub namespace.
  if [[ $ref != */* ]]; then
    _tags_dockerhub "library/$ref"
  elif [[ $first == *.* || $first == *:* || $first == localhost ]]; then
    local host=$first repo=${ref#*/}
    case $host in
      docker.io|index.docker.io)
        [[ $repo == */* ]] || repo="library/$repo"
        _tags_dockerhub "$repo" ;;
      quay.io) _tags_quay "$repo" ;;
      *)       _tags_oci "$host" "$repo" ;;
    esac
  else
    _tags_dockerhub "$ref"
  fi
}

# newest_tag <image-ref> <extended-regex>
#
# Prints the highest version-sorted tag matching the regex. Returns non-zero --
# with a diagnostic on stderr -- if the registry was unreachable, if the tag list
# was truncated, or if nothing matched. Never returns success with a guess.
#
# Selection is by `sort -V`, never by registry ordering. Docker Hub's
# ordering=last_updated puts Windows rebuilds of old branches first, so the most
# recently pushed tag is routinely not the newest version.
newest_tag() {
  local ref=$1 pattern=$2 tags matched count
  tags=$(registry_tags "$ref") || { err_registry "$ref" "registry request failed"; return 1; }

  if grep -qxF -- "$REGISTRY_TRUNCATED_SENTINEL" <<<"$tags"; then
    err_registry "$ref" \
      "tag list truncated at REGISTRY_MAX_PAGES=$REGISTRY_MAX_PAGES; refusing to guess. Raise it and retry."
    return 1
  fi

  count=$(grep -c . <<<"$tags")
  [[ $count -gt 0 ]] || { err_registry "$ref" "registry returned no tags"; return 1; }

  # sort -V handles a leading 'v' correctly (v3.9.2 < v3.10.0 < v10.1.0), so the
  # tags need no stripping or decoration before sorting.
  matched=$(grep -E -- "$pattern" <<<"$tags" | sort -u | sort -V | tail -n1)
  if [[ -z $matched ]]; then
    err_registry "$ref" "no tag matched /$pattern/ out of $count fetched (bad regex?)"
    return 1
  fi
  printf '%s\n' "$matched"
}

err_registry() {
  printf 'registry error (%s): %s\n' "$1" "$2" >&2
}
