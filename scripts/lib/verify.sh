#!/bin/sh
# Checksum verification for the downloaded release artifact.
#
# Verification is not optional: a `chmod +x` of a downloaded file with no
# checksum check is a Best-practice-severity finding that blocks a first
# listing in FPP's plugin registry, and clearing it is what this file is
# for.
#
# sm_verify_checksum below verifies a tarball against a checksum manifest
# also fetched over the network. Be precise about what that buys and what
# it does not: the tarball and its checksum manifest are fetched from the
# same base URL (see sm_artifact_base_url in fetch.sh), there is no digest
# pinned anywhere in this repository independent of that fetch, and no
# second origin cross-checks either file. So it is NOT a defense against a
# compromised or redirected host serving a consistent, self-signed pair of
# bad bytes and a matching bad manifest — a host controlling both files
# can make them agree with each other regardless of what they actually
# contain. What it genuinely catches is transport corruption and a
# tampered-in-transit tarball that no longer matches a manifest fetched
# (and trusted) as a separate step.
#
# That same-origin gap is exactly why sm_install_binary does not use
# sm_verify_checksum as its actual trust gate. It instead verifies with
# sm_verify_sha256 below, against a hash sourced from this repository's
# own committed artifacts.lock.json (see lib/lock.sh) rather than from
# anything fetched over curl. sm_verify_checksum stays here because it is
# still a real, useful check, just not a sufficient one on its own.
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

# Computes the actual sha256 of $1 (a downloaded file) and compares it to
# $2, an already-trusted expected hash. Unlike sm_verify_checksum above,
# this never reads a manifest fetched from the same host as the file it is
# checking; the expected hash must arrive from a source a compromised
# download host cannot also control: this repository's own
# artifacts.lock.json (see lib/lock.sh), not a downloaded SHA256SUMS.
#
# This function is the actual trust gate sm_install_binary relies on, so
# it validates its own $2 argument rather than trusting every caller to
# have done so first: every current caller does validate upstream (lock.sh
# itself refuses to return anything but a 64-hex value), but an empty or
# malformed expected hash reaching here by some future bug must fail
# closed on its own, not depend on `sha256sum` never coincidentally
# producing the same malformed string.
sm_verify_sha256() {
    local _sm_path _sm_expected _sm_grep _sm_sha256sum _sm_awk _sm_actual
    _sm_path="$1"
    _sm_expected="$2"

    if [ ! -f "$_sm_path" ]; then
        sm_log_err "file not found to verify: $_sm_path"
        return 1
    fi

    _sm_grep=$(sm_resolve_bin grep /usr/bin/grep /bin/grep) || return 1
    if ! printf '%s' "$_sm_expected" | "$_sm_grep" -Eq '^[0-9a-f]{64}$'; then
        sm_log_err "refusing to verify $_sm_path: expected-hash argument is not a non-empty 64-character hex string"
        return 1
    fi

    _sm_sha256sum=$(sm_resolve_bin sha256sum /usr/bin/sha256sum /bin/sha256sum /sbin/sha256sum) || return 1
    _sm_awk=$(sm_resolve_bin awk /usr/bin/awk /bin/awk) || return 1

    _sm_actual=$("$_sm_sha256sum" "$_sm_path" | "$_sm_awk" '{print $1}')

    if [ "$_sm_actual" != "$_sm_expected" ]; then
        sm_log_err "checksum mismatch for $_sm_path: expected $_sm_expected (from artifacts.lock.json), got $_sm_actual"
        return 1
    fi

    return 0
}
