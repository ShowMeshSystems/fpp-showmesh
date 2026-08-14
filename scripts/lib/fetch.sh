#!/bin/sh
# Release artifact naming and download.
#
# The naming scheme, the tag format, and the default host are pinned across
# this repo and the repository that builds and publishes the binary; do not
# change them independently here. Only the host is meant to vary, and only
# through SHOWMESH_PLUGIN_ARTIFACT_BASE_URL — the bench uses that override to
# point at a local or test host, and everything else (filenames, manifest
# format, verification) is identical between bench and shipped.
#
# Requires scripts/lib/common.sh to already be sourced.

sm_artifact_tarball_name() {
    # $1 = version, $2 = arch (amd64 | arm64 | armv7)
    printf 'showmesh-fpp-plugin_%s_linux_%s.tar.gz\n' "$1" "$2"
}

sm_artifact_sums_name() {
    # $1 = version
    printf 'showmesh-fpp-plugin_%s_SHA256SUMS\n' "$1"
}

sm_artifact_base_url() {
    # $1 = version
    if [ -n "$SHOWMESH_PLUGIN_ARTIFACT_BASE_URL" ]; then
        printf '%s\n' "$SHOWMESH_PLUGIN_ARTIFACT_BASE_URL"
    else
        printf 'https://github.com/ShowMeshSystems/showmesh/releases/download/fpp-plugin-v%s\n' "$1"
    fi
}

# Downloads $1 (a URL) to $2 (a destination path), using curl if present and
# falling back to wget. Fails loudly, with the URL in the message, rather
# than leaving a partial or missing file for a later step to trip over.
sm_download() {
    local _sm_url _sm_dest _sm_curl _sm_wget
    _sm_url="$1"
    _sm_dest="$2"

    _sm_curl=$(sm_resolve_bin curl /usr/bin/curl /bin/curl 2>/dev/null)
    if [ -n "$_sm_curl" ]; then
        if "$_sm_curl" -fsSL --connect-timeout 10 --max-time 120 -o "$_sm_dest" "$_sm_url"; then
            return 0
        fi
        sm_log_err "download failed via curl: $_sm_url"
        return 1
    fi

    _sm_wget=$(sm_resolve_bin wget /usr/bin/wget /bin/wget 2>/dev/null)
    if [ -n "$_sm_wget" ]; then
        if "$_sm_wget" -q --timeout=120 -O "$_sm_dest" "$_sm_url"; then
            return 0
        fi
        sm_log_err "download failed via wget: $_sm_url"
        return 1
    fi

    sm_log_err "neither curl nor wget found; cannot download $_sm_url"
    return 1
}
