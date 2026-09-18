#!/usr/bin/env bash
#
# Regenerate sources.json from OpenAI's apt repository.
#
# The point of this script is that nothing it writes into sources.json is
# taken on trust from an unauthenticated fetch. The chain is:
#
#   openai-archive-keyring.asc     (in this repo, fingerprint asserted below)
#     -> dists/stable/InRelease    (detached-inline PGP signature, verified)
#          -> main/binary-$arch/Packages  (SHA256 listed in InRelease, checked)
#               -> pool/.../*.deb        (SHA256 listed in Packages, recorded)
#
# So the hash that ends up in sources.json is the hash OpenAI signed, not
# the hash of whatever bytes happened to come down the wire when the updater
# ran. The .deb itself is never downloaded here; Nix fetches it at build time
# and checks it against that signed hash.
#
set -euo pipefail

readonly REPO_URL="https://persistent.oaistatic.com/codex-app-prod/linux/deb"
readonly SUITE="stable"
readonly COMPONENT="main"

# Codex Linux Repository, RSA 4096, created 2026-08-05. OpenAI publishes it
# nowhere on its own; see the README for where this copy came from.
readonly KEY_FINGERPRINT="3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4"

# Debian architecture -> Nix system. The repository publishes no others.
readonly ARCHES=("amd64:x86_64-linux" "arm64:aarch64-linux")

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly KEYRING_ASC="$ROOT/openai-archive-keyring.asc"
readonly SOURCES_JSON="$ROOT/sources.json"

log() { printf '\033[0;32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require_tools() {
  local missing=()
  for tool in curl gpg gpgv jq nix sha256sum dpkg; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  [ ${#missing[@]} -eq 0 ] || die "missing required tools: ${missing[*]} (try: nix develop)"
}

fetch() {
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 --max-time 120 "$1"
}

# Refuse to proceed unless the key in this repository is the one we expect.
# Guards against a bad merge or a tampered checkout, not against upstream.
assert_pinned_key() {
  local fpr
  fpr="$(gpg --show-keys --with-colons "$KEYRING_ASC" | awk -F: '$1=="fpr" {print $10; exit}')"
  [ "$fpr" = "$KEY_FINGERPRINT" ] ||
    die "keyring fingerprint is $fpr, expected $KEY_FINGERPRINT"
  log "signing key $KEY_FINGERPRINT"
}

# Verify the inline signature and return the signed body on stdout.
verify_inrelease() {
  local inrelease="$1" keyring="$2"
  gpgv --keyring "$keyring" "$inrelease" 2>&1 >/dev/null |
    grep -q '^gpgv: Good signature' ||
    die "InRelease signature does not verify against the pinned key"

  # Strip the PGP armour to leave the signed body: everything between the
  # blank line after the "Hash:" headers and the signature block.
  awk '/^-----BEGIN PGP SIGNATURE-----$/ {exit} seen {print} /^$/ {seen=1}' "$inrelease"
}

# Field of a Release file's SHA256 section for a given path.
release_sha256() {
  local body="$1" path="$2"
  awk -v want="$path" '
    /^SHA256:/ {in_section = 1; next}
    /^[^ ]/ {in_section = 0}
    in_section && $3 == want {print $1; exit}
  ' <<<"$body"
}

# Highest version of chatgpt in a Packages index, by Debian version
# ordering rather than string ordering.
newest_version() {
  local packages="$1" newest=""
  while read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ -z "$newest" ] || dpkg --compare-versions "$candidate" gt "$newest"; then
      newest="$candidate"
    fi
  done < <(awk '/^Package: chatgpt$/ {p=1} p && /^Version: / {print $2; p=0}' <<<"$packages")
  [ -n "$newest" ] || die "no chatgpt package found in index"
  printf '%s' "$newest"
}

# One field from the stanza for a specific version.
stanza_field() {
  local packages="$1" version="$2" field="$3"
  awk -v version="$version" -v field="$field:" '
    BEGIN {RS = "\n\n"}
    $0 ~ ("(^|\n)Package: chatgpt\n") && $0 ~ ("(^|\n)Version: " version "\n") {
      n = split($0, lines, "\n")
      for (i = 1; i <= n; i++) if (index(lines[i], field) == 1) {
        print substr(lines[i], length(field) + 2)
        exit
      }
    }
  ' <<<"$packages"
}

main() {
  local check_only=false force=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check_only=true; shift ;;
      --force) force=true; shift ;;
      --help)
        cat <<'USAGE'
Usage: scripts/update.sh [--check] [--force]

Rewrites sources.json from OpenAI's signed apt repository.

  --check   Report whether an update is available and exit non-zero if one
            is, without writing anything.
  --force   Rewrite sources.json even when the pinned version is already the
            newest one, so that its contents can be compared against the
            signed index.
USAGE
        exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  require_tools
  assert_pinned_key

  local workdir
  workdir="$(mktemp -d)"
  # Expanded now, not at trap time: $workdir is a local that is out of scope
  # by the time the EXIT trap runs.
  # shellcheck disable=SC2064
  trap "rm -rf '$workdir'" EXIT

  gpg --dearmor <"$KEYRING_ASC" >"$workdir/keyring.gpg"

  log "fetching $REPO_URL/dists/$SUITE/InRelease"
  fetch "$REPO_URL/dists/$SUITE/InRelease" >"$workdir/InRelease"

  local release
  release="$(verify_inrelease "$workdir/InRelease" "$workdir/keyring.gpg")"
  log "InRelease signature verified"

  # A repository whose index has expired is a repository whose publisher has
  # stopped attesting to it. Warn rather than fail: a lapsed Valid-Until is
  # usually an upstream publishing hiccup, and the per-file hashes below are
  # still signed.
  local valid_until
  valid_until="$(awk -F': ' '/^Valid-Until: / {print $2; exit}' <<<"$release")"
  if [ -n "$valid_until" ] && [ "$(date -u +%s)" -gt "$(date -u -d "$valid_until" +%s)" ]; then
    warn "repository index expired at $valid_until"
  fi

  local current_version
  current_version="$(jq -r '.version' "$SOURCES_JSON" 2>/dev/null || echo "none")"

  local -A url_of hash_of size_of version_of
  local arch system

  for entry in "${ARCHES[@]}"; do
    arch="${entry%%:*}"
    system="${entry##*:}"

    local index_path="$COMPONENT/binary-$arch/Packages"
    local expected_sha
    expected_sha="$(release_sha256 "$release" "$index_path")"
    [ -n "$expected_sha" ] || die "InRelease lists no SHA256 for $index_path"

    log "fetching $index_path"
    fetch "$REPO_URL/dists/$SUITE/$index_path" >"$workdir/Packages.$arch"

    local actual_sha
    actual_sha="$(sha256sum "$workdir/Packages.$arch" | cut -d' ' -f1)"
    [ "$actual_sha" = "$expected_sha" ] ||
      die "$index_path hash mismatch: got $actual_sha, InRelease signed $expected_sha"

    local packages version filename size sha256
    packages="$(cat "$workdir/Packages.$arch")"
    version="$(newest_version "$packages")"
    filename="$(stanza_field "$packages" "$version" Filename)"
    size="$(stanza_field "$packages" "$version" Size)"
    sha256="$(stanza_field "$packages" "$version" SHA256)"

    [ -n "$filename" ] && [ -n "$size" ] && [ -n "$sha256" ] ||
      die "incomplete stanza for chatgpt $version on $arch"

    version_of[$system]="$version"
    url_of[$system]="$REPO_URL/$filename"
    size_of[$system]="$size"
    hash_of[$system]="$(nix hash convert --hash-algo sha256 --to sri "$sha256")"

    log "$arch: $version ($index_path verified against InRelease)"
  done

  # One version attribute covers both architectures, so a release that is
  # only half-published is not a release we can pin.
  local latest_version=""
  for entry in "${ARCHES[@]}"; do
    system="${entry##*:}"
    if [ -z "$latest_version" ]; then
      latest_version="${version_of[$system]}"
    elif [ "$latest_version" != "${version_of[$system]}" ]; then
      die "architectures disagree on the newest version: ${version_of[*]}"
    fi
  done

  log "current: $current_version, latest: $latest_version"

  if [ "$current_version" = "$latest_version" ] && [ "$force" = false ]; then
    log "already up to date"
    exit 0
  fi

  if [ "$check_only" = true ]; then
    log "update available: $current_version -> $latest_version"
    exit 1
  fi

  local json='{}'
  json="$(jq -n --arg version "$latest_version" '{version: $version, sources: {}}')"
  for entry in "${ARCHES[@]}"; do
    arch="${entry%%:*}"
    system="${entry##*:}"
    json="$(jq \
      --arg system "$system" \
      --arg debianArch "$arch" \
      --arg url "${url_of[$system]}" \
      --arg hash "${hash_of[$system]}" \
      --argjson size "${size_of[$system]}" \
      '.sources[$system] = {debianArch: $debianArch, url: $url, hash: $hash, size: $size}' \
      <<<"$json")"
  done

  printf '%s\n' "$json" >"$SOURCES_JSON"
  log "wrote $SOURCES_JSON at $latest_version"
}

main "$@"
