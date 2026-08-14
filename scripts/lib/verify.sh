#!/bin/sh
# Checksum verification for the downloaded release artifact.
#
# Verification is not optional: a `chmod +x` of a downloaded file with no
# checksum check is a Best-practice-severity finding that blocks a first
# listing in FPP's plugin registry, and clearing it is what this file is
# for.
#
# Be precise about what this buys and what it does not. The tarball and
# its checksum manifest are fetched from the same base URL (see
# sm_artifact_base_url in fetch.sh), there is no digest pinned anywhere in
# this repository independent of that fetch, and no second origin cross-
# checks either file. So this is NOT a defense against a compromised or
# redirected host serving a consistent, self-signed pair of bad bytes and
# a matching bad manifest — a host controlling both files can make them
# agree with each other regardless of what they actually contain. What it
# genuinely catches is transport corruption and a tampered-in-transit
# tarball that no longer matches a manifest fetched (and trusted) as a
# separate step, which is exactly the registry finding it clears and no
# more than that.
#
# Requires scripts/lib/common.sh to already be sourced.

# Verifies that $1 (a downloaded tarball path) matches its entry in $2 (a
# downloaded SHA256SUMS-format manifest) for filename $3 (the exact basename
# expected, matched as the manifest line's final field so a prefix or
# substring match on a different tarball's line can never pass).
sm_verify_checksum() {
    local _sm_tarball _sm_sumsfile _sm_expected_name _sm_sha256sum _sm_awk _sm_expected_hash _sm_actual_hash
    _sm_tarball="$1"
    _sm_sumsfile="$2"
    _sm_expected_name="$3"

    # /sbin/sha256sum covers macOS dev/CI machines used to run this repo's
    # own tests; every deployed FPP host is Debian-based, where coreutils
    # puts it under /usr/bin (or /bin pre usr-merge).
    _sm_sha256sum=$(sm_resolve_bin sha256sum /usr/bin/sha256sum /bin/sha256sum /sbin/sha256sum) || return 1
    _sm_awk=$(sm_resolve_bin awk /usr/bin/awk /bin/awk) || return 1

    if [ ! -f "$_sm_sumsfile" ]; then
        sm_log_err "checksum manifest not found: $_sm_sumsfile"
        return 1
    fi

    if [ ! -f "$_sm_tarball" ]; then
        sm_log_err "downloaded artifact not found: $_sm_tarball"
        return 1
    fi

    # Standard `sha256sum` output is "<hex>  <filename>" (two spaces) or
    # "<hex> *<filename>" in binary mode. Match the filename as the line's
    # final field, stripping a leading "*", rather than grepping for the
    # name as a substring anywhere in the file.
    _sm_expected_hash=$("$_sm_awk" -v want="$_sm_expected_name" '
        {
            name = $NF
            sub(/^\*/, "", name)
            if (name == want) { print $1; found = 1 }
        }
        END { if (!found) exit 1 }
    ' "$_sm_sumsfile") || {
        sm_log_err "no checksum entry for $_sm_expected_name in $_sm_sumsfile"
        return 1
    }

    if [ -z "$_sm_expected_hash" ]; then
        sm_log_err "no checksum entry for $_sm_expected_name in $_sm_sumsfile"
        return 1
    fi

    _sm_actual_hash=$("$_sm_sha256sum" "$_sm_tarball" | "$_sm_awk" '{print $1}')

    if [ "$_sm_actual_hash" != "$_sm_expected_hash" ]; then
        sm_log_err "checksum mismatch for $_sm_expected_name: expected $_sm_expected_hash, got $_sm_actual_hash"
        return 1
    fi

    return 0
}
