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
    local _sm_lock_file _sm_grep _sm_sed _sm_line _sm_count
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

    _sm_count=$("$_sm_grep" -c '^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$_sm_lock_file" 2>/dev/null)
    _sm_count="${_sm_count:-0}"
    if [ "$_sm_count" -eq 0 ]; then
        sm_log_err "artifacts.lock.json at $_sm_lock_file has no top-level \"version\" field"
        return 1
    fi
    if [ "$_sm_count" -gt 1 ]; then
        sm_log_err "artifacts.lock.json at $_sm_lock_file has $_sm_count lines matching a line-start \"version\" field; refusing a lock this parser cannot read unambiguously (a pretty-printed or otherwise reformatted lock can put a per-artifact \"version\" key at line-start too, indistinguishable here from the top-level one)"
        return 1
    fi

    _sm_line=$("$_sm_grep" -m 1 -o '^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$_sm_lock_file")

    printf '%s\n' "$_sm_line" | "$_sm_sed" -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
}

# Prints the sha256 recorded for exactly $2 (an exact filename) in lock
# file $1. Matched by finding the OBJECT that contains that literal
# "filename" key/value pair and reading "sha256" back off that same
# object, which is why artifacts.lock.json keeps artifact objects
# unnested (no object contains another) rather than pretty-printed across
# several: the co-occurrence within one object boundary is what lets this
# stay a grep/sed job instead of needing a real JSON parser, which an FPP
# host may not have.
#
# The stream is normalized first so every object stands on its own line
# regardless of how the lock happens to be formatted (one object per
# line, this repository's own convention, or every object minified onto
# a single physical line): flattened to one line, then split at every
# "},{" object boundary. Since objects never nest, a boundary at a "}"
# immediately followed by "," and "{" is unambiguous, and this is what
# keeps a match confined to exactly the object naming the requested
# filename instead of reading into a neighbouring artifact's fields when
# several objects share one physical line.
sm_lock_sha256() {
    local _sm_lock_file _sm_filename _sm_grep _sm_sed _sm_tr _sm_marker
    local _sm_flat _sm_objects _sm_count _sm_object _sm_rest _sm_hash
    local _sm_sha_matches _sm_sha_count
    _sm_lock_file="$1"
    _sm_filename="$2"
    _sm_grep=$(sm_resolve_bin grep /usr/bin/grep /bin/grep) || return 1
    _sm_sed=$(sm_resolve_bin sed /usr/bin/sed /bin/sed) || return 1
    _sm_tr=$(sm_resolve_bin tr /usr/bin/tr /bin/tr) || return 1

    if [ ! -f "$_sm_lock_file" ]; then
        sm_log_err "artifacts.lock.json not found at $_sm_lock_file"
        return 1
    fi
    if [ ! -r "$_sm_lock_file" ]; then
        sm_log_err "artifacts.lock.json not readable at $_sm_lock_file"
        return 1
    fi

    _sm_flat=$("$_sm_tr" '\n' ' ' < "$_sm_lock_file")
    _sm_objects=$(printf '%s' "$_sm_flat" | "$_sm_sed" -E 's/\}[[:space:]]*,[[:space:]]*\{/}\
{/g')

    _sm_marker="\"filename\": \"$_sm_filename\""

    # Counts OCCURRENCES of the marker, not matching LINES. `grep -Fc`
    # counts matching LINES, which undercounts two duplicate entries that
    # share one physical, minified line as a single match: a single
    # object with a duplicated "filename" key on one line passed this
    # guard silently for exactly that reason. `grep -Fo` instead prints
    # each occurrence on its own output line, one match per line even
    # when several matches share one input line, so counting the LINES
    # of that output counts occurrences correctly regardless of how many
    # matches started out sharing a physical line.
    _sm_count=$(printf '%s\n' "$_sm_objects" | "$_sm_grep" -Fo "$_sm_marker" | "$_sm_grep" -Fc "$_sm_marker" 2>/dev/null)
    _sm_count="${_sm_count:-0}"
    if [ "$_sm_count" -eq 0 ]; then
        sm_log_err "artifacts.lock.json has no entry for $_sm_filename"
        return 1
    fi
    if [ "$_sm_count" -gt 1 ]; then
        sm_log_err "artifacts.lock.json has $_sm_count entries naming $_sm_filename; refusing an ambiguous lock rather than picking one"
        return 1
    fi

    _sm_object=$(printf '%s\n' "$_sm_objects" | "$_sm_grep" -F "$_sm_marker")

    # This entry's own object is isolated to one line now, so a neighbour
    # sharing the original physical line can no longer be mistaken for
    # it. Within it, "sha256" is demanded to come AFTER "filename": this
    # repository generates and commits its own lock in exactly that key
    # order, and a regenerated lock that reorders an object's keys is not
    # a shape this parser guesses at — see the empty-result branch below.
    #
    # More than one "sha256" occurrence within this one isolated entry,
    # for example a nested object under some other key that happens to
    # carry its own "sha256" field, is refused rather than resolved by
    # picking the first match: that used to silently return the NESTED
    # value at exit 0 for an entry shaped like
    # { "filename": "X", "meta": { "sha256": "…" }, "sha256": "…" },
    # never the entry's own top-level hash, with no indication anything
    # was wrong. `grep -o` again prints one occurrence per output line
    # (see the marker count above), so counting those lines catches this
    # the same way.
    _sm_rest="${_sm_object#*"$_sm_marker"}"
    _sm_sha_matches=$(printf '%s\n' "$_sm_rest" | "$_sm_grep" -o '"sha256"[[:space:]]*:[[:space:]]*"[^"]*"')
    _sm_sha_count=$(printf '%s\n' "$_sm_sha_matches" | "$_sm_grep" -Fc '"sha256"' 2>/dev/null)
    _sm_sha_count="${_sm_sha_count:-0}"

    if [ "$_sm_sha_count" -eq 0 ]; then
        if printf '%s\n' "$_sm_object" | "$_sm_grep" -q '"sha256"'; then
            sm_log_err "artifacts.lock.json entry for $_sm_filename has a \"sha256\" field that does not come after \"filename\" in the source text; refusing a lock this parser cannot read unambiguously rather than guessing at a different key order"
        else
            sm_log_err "artifacts.lock.json entry for $_sm_filename has no sha256 field"
        fi
        return 1
    fi
    if [ "$_sm_sha_count" -gt 1 ]; then
        sm_log_err "artifacts.lock.json entry for $_sm_filename has $_sm_sha_count \"sha256\" fields within its own entry (possibly one nested inside another key); refusing an ambiguous lock rather than picking one"
        return 1
    fi

    # Exactly one "sha256" occurrence within this entry, but that alone
    # does not prove it is the entry's OWN field: an entry shaped like
    # { "filename": "X", "meta": { "sha256": "…" } }, with no top-level
    # "sha256" at all, has exactly one match too, and this used to return
    # that nested value at exit 0 as if it were the entry's own hash. The
    # match's brace depth relative to the entry object (counted in the
    # text before it) tells the two cases apart: a real top-level field
    # sits at depth 0, one nested inside "meta" (or any other object-
    # valued key) sits at depth 1 or deeper. This is the same "nested,
    # not top-level" defect as the sha_count-gt-1 case above, just with
    # the top-level field additionally missing so nothing is left to
    # outnumber the nested one.
    _sm_sha_before=$(printf '%s\n' "$_sm_rest" | "$_sm_sed" -E 's/"sha256"[[:space:]]*:[[:space:]]*"[^"]*".*/ /')
    _sm_sha_opens=$(printf '%s' "$_sm_sha_before" | "$_sm_tr" -dc '{')
    _sm_sha_closes=$(printf '%s' "$_sm_sha_before" | "$_sm_tr" -dc '}')
    if [ "${#_sm_sha_opens}" -gt "${#_sm_sha_closes}" ]; then
        sm_log_err "artifacts.lock.json entry for $_sm_filename has its only \"sha256\" field nested inside another key, not at the entry's own level; refusing rather than treating it as the entry's hash"
        return 1
    fi

    _sm_hash=$(printf '%s\n' "$_sm_sha_matches" | "$_sm_sed" -E 's/.*:[[:space:]]*"([^"]*)"/\1/')

    # A "sha256" field that matched (so it DID come after "filename", and
    # there is exactly one of it) but whose value is the empty string is
    # a different, more specific problem than either branch above: the
    # field is present, in the right place, just empty. Reporting it as
    # "does not come after filename", which the old check for -z
    # "$_sm_hash" could not tell apart from this case, described
    # something that was not actually true about the source text.
    if [ -z "$_sm_hash" ]; then
        sm_log_err "artifacts.lock.json entry for $_sm_filename has an empty sha256 value"
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
