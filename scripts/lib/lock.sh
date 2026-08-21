#!/bin/sh
# Looks up the expected SHA-256 for a release artifact from this
# repository's own committed artifacts.lock.json, the trust anchor
# sm_install_binary verifies a download against.
#
# A downloaded tarball and a downloaded SHA256SUMS manifest both come from
# the same base URL (see sm_artifact_base_url in fetch.sh); a compromised
# or redirected host can make that pair agree with itself regardless of
# what either actually contains, so a checksum check against a downloaded
# manifest defends against transport corruption only, not against a bad
# host. artifacts.lock.json ships inside this repository's own checked-out
# tree, which arrives on the FPP host under FPP's control (clone, then run
# this script), not over curl, so it is the one hash source a compromised
# download host cannot also serve.
#
# A missing, malformed, or version-mismatched lock refuses the install
# outright; there is no fallback to an unpinned hash.
#
# Requires scripts/lib/common.sh to already be sourced.

sm_lock_path() {
    # $1 = plugin directory
    printf '%s\n' "$1/artifacts.lock.json"
}

# Prints the lock file's top-level "version" field.
#
# Anchored to the START of a line, not just matched anywhere in the file:
# this repository's own lock format writes every top-level key on its own
# line ("  \"version\": \"0.1.0\","), while each per-artifact object is a
# single compact line ("    { \"filename\": ..., \"sha256\": ... }"); see
# sm_lock_sha256 below for why. A "version" key that ended up inside one
# of those artifact objects would sit in the middle of that object's line,
# never at the line's start, regardless of whether that object happens to
# appear before or after the top-level "version" key in the raw text. So
# anchoring on line-start is what actually targets the top-level field
# specifically; picking the first match in file order (what this function
# used to do) is only correct by accident, for exactly one key ordering.
sm_lock_version() {
    local _sm_lock_file _sm_grep _sm_sed _sm_line
    _sm_lock_file="$1"
    _sm_grep=$(sm_resolve_bin grep /usr/bin/grep /bin/grep) || return 1
    _sm_sed=$(sm_resolve_bin sed /usr/bin/sed /bin/sed) || return 1

    if [ ! -f "$_sm_lock_file" ]; then
        sm_log_err "artifacts.lock.json not found at $_sm_lock_file"
        return 1
    fi
    if [ ! -r "$_sm_lock_file" ]; then
        sm_log_err "artifacts.lock.json not readable at $_sm_lock_file"
        return 1
    fi

    _sm_line=$("$_sm_grep" -m 1 -o '^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$_sm_lock_file")
    if [ -z "$_sm_line" ]; then
        sm_log_err "artifacts.lock.json at $_sm_lock_file has no top-level \"version\" field"
        return 1
    fi

    printf '%s\n' "$_sm_line" | "$_sm_sed" -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
}

# Prints the sha256 recorded for exactly $2 (an exact filename) in lock
# file $1. Matched by finding the line that contains that literal
# "filename" key/value pair and reading "sha256" back off that same line,
# which is why artifacts.lock.json keeps one artifact object per line
# rather than pretty-printed across several: the co-occurrence on one line
# is what lets this stay a grep/sed job instead of needing a real JSON
# parser, which an FPP host may not have.
sm_lock_sha256() {
    local _sm_lock_file _sm_filename _sm_grep _sm_sed _sm_count _sm_line _sm_hash
    _sm_lock_file="$1"
    _sm_filename="$2"
    _sm_grep=$(sm_resolve_bin grep /usr/bin/grep /bin/grep) || return 1
    _sm_sed=$(sm_resolve_bin sed /usr/bin/sed /bin/sed) || return 1

    if [ ! -f "$_sm_lock_file" ]; then
        sm_log_err "artifacts.lock.json not found at $_sm_lock_file"
        return 1
    fi
    if [ ! -r "$_sm_lock_file" ]; then
        sm_log_err "artifacts.lock.json not readable at $_sm_lock_file"
        return 1
    fi

    _sm_count=$("$_sm_grep" -Fc "\"filename\": \"$_sm_filename\"" "$_sm_lock_file" 2>/dev/null)
    _sm_count="${_sm_count:-0}"
    if [ "$_sm_count" -eq 0 ]; then
        sm_log_err "artifacts.lock.json has no entry for $_sm_filename"
        return 1
    fi
    if [ "$_sm_count" -gt 1 ]; then
        sm_log_err "artifacts.lock.json has $_sm_count entries naming $_sm_filename; refusing an ambiguous lock rather than picking one"
        return 1
    fi

    # Even though the filename count check above confirms only one LINE
    # contains this filename, a minified lock file can put every artifact
    # object on one single physical line, in which case that "line" also
    # contains every OTHER artifact's "sha256" key, and grep -o emits one
    # output line per match, not per input line: "-m 1" does not limit
    # that (it caps matching INPUT lines, and there is only one to begin
    # with here), so it would not help. `sed -n '1p'` after -o is what
    # actually keeps only the first extracted match, and validating that
    # single value below is what keeps a minified lock from producing more
    # than one hash out of a check meant to name exactly one.
    _sm_line=$("$_sm_grep" -F "\"filename\": \"$_sm_filename\"" "$_sm_lock_file")
    _sm_hash=$(printf '%s\n' "$_sm_line" | "$_sm_grep" -o '"sha256"[[:space:]]*:[[:space:]]*"[^"]*"' | "$_sm_sed" -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | "$_sm_sed" -n '1p')
    if [ -z "$_sm_hash" ]; then
        sm_log_err "artifacts.lock.json entry for $_sm_filename has no sha256 field"
        return 1
    fi

    if ! printf '%s' "$_sm_hash" | "$_sm_grep" -Eq '^[0-9a-f]{64}$'; then
        sm_log_err "artifacts.lock.json entry for $_sm_filename has a malformed sha256 value: $_sm_hash"
        return 1
    fi

    printf '%s\n' "$_sm_hash"
}

# $1 = plugin directory, $2 = version being installed, $3 = exact tarball
# filename to verify. Refuses rather than falling back if the lock file is
# missing, malformed, or pinned to a version other than $2.
sm_lock_expected_sha256() {
    local _sm_plugin_dir _sm_version _sm_filename _sm_lock_file _sm_lock_version
    _sm_plugin_dir="$1"
    _sm_version="$2"
    _sm_filename="$3"
    _sm_lock_file=$(sm_lock_path "$_sm_plugin_dir")

    _sm_lock_version=$(sm_lock_version "$_sm_lock_file") || return 1
    if [ "$_sm_lock_version" != "$_sm_version" ]; then
        sm_log_err "artifacts.lock.json is pinned to version $_sm_lock_version, but this install is for $_sm_version; refusing rather than trusting a lock for a different release"
        return 1
    fi

    sm_lock_sha256 "$_sm_lock_file" "$_sm_filename"
}
