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

# The tarball and its checksum manifest are always fetched from the same
# base URL, so this does not defend against a compromised or redirected
# host — checksum verification only catches transport corruption between
# a URL and what actually arrives, not a bad-faith host serving a
# consistent, self-signed pair. What this function catches is a base URL
# with no scheme at all (a plain typo, or an override with the scheme
# accidentally dropped), and it makes a plain-http override loud rather
# than silent, since SHOWMESH_PLUGIN_ARTIFACT_BASE_URL enforces no scheme
# by itself and curl/wget will follow whatever they are given.
sm_check_base_url_scheme() {
    local _sm_url
    _sm_url="$1"
    case "$_sm_url" in
        https://*)
            return 0
            ;;
        http://*)
            sm_log "artifact base URL uses plain http, not https: $_sm_url — only expected for a bench or test override; the default host is always https"
            return 0
            ;;
        *)
            sm_log_err "artifact base URL has no recognized http:// or https:// scheme: $_sm_url"
            return 1
            ;;
    esac
}

# Downloads $1 (a URL) to $2 (a destination path), using curl if present and
# falling back to wget. Fails loudly, with the URL in the message, rather
# than leaving a partial or missing file for a later step to trip over.
#
# Timeouts default to a foreground, human-initiated install's budget (10s
# to connect, 120s total) but are overridable via SM_DOWNLOAD_CONNECT_TIMEOUT
# and SM_DOWNLOAD_MAX_TIME. preStart.sh's boot-time repair path sets both
# much tighter, because that context blocks fppd starting and must not eat
# minutes of a networkless boot on retries the default budget would allow.
sm_download() {
    local _sm_url _sm_dest _sm_curl _sm_wget _sm_connect_timeout _sm_max_time
    _sm_url="$1"
    _sm_dest="$2"
    _sm_connect_timeout="${SM_DOWNLOAD_CONNECT_TIMEOUT:-10}"
    _sm_max_time="${SM_DOWNLOAD_MAX_TIME:-120}"

    _sm_curl=$(sm_resolve_bin curl /usr/bin/curl /bin/curl 2>/dev/null)
    if [ -n "$_sm_curl" ]; then
        if "$_sm_curl" -fsSL --connect-timeout "$_sm_connect_timeout" --max-time "$_sm_max_time" -o "$_sm_dest" "$_sm_url"; then
            return 0
        fi
        sm_log_err "download failed via curl: $_sm_url"
        return 1
    fi

    _sm_wget=$(sm_resolve_bin wget /usr/bin/wget /bin/wget 2>/dev/null)
    if [ -n "$_sm_wget" ]; then
        if "$_sm_wget" -q --timeout="$_sm_max_time" -O "$_sm_dest" "$_sm_url"; then
            return 0
        fi
        sm_log_err "download failed via wget: $_sm_url"
        return 1
    fi

    sm_log_err "neither curl nor wget found; cannot download $_sm_url"
    return 1
}
