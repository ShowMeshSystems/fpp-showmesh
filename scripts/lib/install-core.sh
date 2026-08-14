#!/bin/sh
# Shared body of fpp_install.sh and fpp_upgrade.sh.
#
# Both entrypoints call sm_install_or_upgrade with the same arguments and it
# is written to be safe to re-run: FPP 9.x honours fpp_install.sh on every
# upgrade (it does not call fpp_upgrade.sh at all) while FPP 10 calls
# fpp_upgrade.sh first, so this body cannot assume it only ever runs once.
#
# Requires common.sh, arch.sh, fetch.sh, verify.sh, and commands.sh to
# already be sourced.

# Creates the plugin's state directory and the files the binary expects to
# find there, without overwriting anything that already exists. This runs on
# every install and every upgrade, so an existing credential or config must
# survive a re-run untouched.
sm_ensure_config_scaffold() {
    local _sm_configdir _sm_mkdir _sm_chown _sm_chmod _sm_credfile
    local _sm_name_default _sm_fname _sm_default _sm_fpath
    _sm_configdir=$(sm_config_dir)

    # /usr/sbin/chown is a macOS-only location, listed only so this repo's
    # own tests can run unmodified on a developer Mac; Debian FPP hosts
    # always resolve chown from /bin or /usr/bin, listed first.
    _sm_mkdir=$(sm_resolve_bin mkdir /bin/mkdir /usr/bin/mkdir) || return 1
    _sm_chown=$(sm_resolve_bin chown /bin/chown /usr/bin/chown /usr/sbin/chown) || return 1
    _sm_chmod=$(sm_resolve_bin chmod /bin/chmod /usr/bin/chmod) || return 1

    "$_sm_mkdir" -p "$_sm_configdir" || {
        sm_log_err "could not create config directory: $_sm_configdir"
        return 1
    }
    "$_sm_chown" fpp:fpp "$_sm_configdir"
    "$_sm_chmod" 0755 "$_sm_configdir"

    _sm_credfile=$(sm_credential_file)
    if [ ! -e "$_sm_credfile" ]; then
        : > "$_sm_credfile" || {
            sm_log_err "could not create credential file: $_sm_credfile"
            return 1
        }
        sm_log "created empty credential file at $_sm_credfile; it must be provisioned with a scheduler credential before the plugin can act"
    fi
    "$_sm_chown" fpp:fpp "$_sm_credfile"
    "$_sm_chmod" 0600 "$_sm_credfile"

    for _sm_name_default in \
        "config.json:{}" \
        "status.json:{}" \
        "failures.json:[]" \
        "macro-cache.json:{}"
    do
        _sm_fname="${_sm_name_default%%:*}"
        _sm_default="${_sm_name_default#*:}"
        _sm_fpath="$_sm_configdir/$_sm_fname"
        if [ ! -e "$_sm_fpath" ]; then
            printf '%s\n' "$_sm_default" > "$_sm_fpath" || {
                sm_log_err "could not create $_sm_fpath"
                return 1
            }
        fi
        "$_sm_chown" fpp:fpp "$_sm_fpath"
        "$_sm_chmod" 0644 "$_sm_fpath"
    done

    return 0
}

# Fetches, verifies, and installs the binary for this host's architecture.
# Always re-fetches: called on both install and upgrade, and a version bump
# is exactly the case where the previously installed binary must not be kept.
sm_install_binary() {
    local _sm_plugin_dir _sm_fppdir _sm_version _sm_arch _sm_tarball_name _sm_sums_name
    local _sm_base_url _sm_mktemp _sm_workdir _sm_tar _sm_mv _sm_chmod _sm_chown _sm_target
    _sm_plugin_dir="$1"
    _sm_fppdir="$2"
    _sm_version="$3"

    _sm_arch=$(sm_detect_arch "$_sm_fppdir") || {
        sm_log_err "architecture detection failed; refusing to guess an artifact"
        return 1
    }
    sm_log "detected architecture: $_sm_arch"

    _sm_tarball_name=$(sm_artifact_tarball_name "$_sm_version" "$_sm_arch")
    _sm_sums_name=$(sm_artifact_sums_name "$_sm_version")
    _sm_base_url=$(sm_artifact_base_url "$_sm_version")

    _sm_mktemp=$(sm_resolve_bin mktemp /bin/mktemp /usr/bin/mktemp) || return 1
    _sm_workdir=$("$_sm_mktemp" -d /tmp/fpp-showmesh.XXXXXX) || {
        sm_log_err "could not create a temporary working directory"
        return 1
    }
    # shellcheck disable=SC2064
    trap "rm -rf '$_sm_workdir'" EXIT

    sm_log "fetching $_sm_tarball_name from $_sm_base_url"
    sm_download "$_sm_base_url/$_sm_tarball_name" "$_sm_workdir/$_sm_tarball_name" || return 1
    sm_download "$_sm_base_url/$_sm_sums_name" "$_sm_workdir/$_sm_sums_name" || return 1

    sm_verify_checksum "$_sm_workdir/$_sm_tarball_name" "$_sm_workdir/$_sm_sums_name" "$_sm_tarball_name" || {
        sm_log_err "refusing to install an artifact that failed checksum verification"
        return 1
    }

    _sm_tar=$(sm_resolve_bin tar /bin/tar /usr/bin/tar) || return 1
    "$_sm_tar" -xzf "$_sm_workdir/$_sm_tarball_name" -C "$_sm_workdir" || {
        sm_log_err "could not extract $_sm_tarball_name"
        return 1
    }

    if [ ! -f "$_sm_workdir/showmesh-fpp-plugin" ]; then
        sm_log_err "$_sm_tarball_name did not contain showmesh-fpp-plugin at its top level"
        return 1
    fi

    _sm_mv=$(sm_resolve_bin mv /bin/mv /usr/bin/mv) || return 1
    _sm_chmod=$(sm_resolve_bin chmod /bin/chmod /usr/bin/chmod) || return 1
    _sm_chown=$(sm_resolve_bin chown /bin/chown /usr/bin/chown /usr/sbin/chown) || return 1

    _sm_target=$(sm_binary_path "$_sm_plugin_dir")
    "$_sm_mv" -f "$_sm_workdir/showmesh-fpp-plugin" "$_sm_target" || {
        sm_log_err "could not install binary to $_sm_target"
        return 1
    }
    "$_sm_chmod" 0755 "$_sm_target"
    "$_sm_chown" fpp:fpp "$_sm_target"

    sm_log "installed showmesh-fpp-plugin $_sm_version ($_sm_arch) to $_sm_target"
    return 0
}

# Best-effort only: asks FPP to pick up the new commands/descriptions.json
# through its own restart-flag mechanism rather than a direct service
# restart. This endpoint has not been confirmed against a running FPP
# instance (see README.md), so a failure here is logged and never aborts
# the install — a fresh command definition that needs a later FPP restart
# to appear is a much smaller problem than an install that reports failure
# for a cosmetic reason.
sm_request_fpp_restart_flag() {
    local _sm_curl
    _sm_curl=$(sm_resolve_bin curl /usr/bin/curl /bin/curl 2>/dev/null)
    if [ -z "$_sm_curl" ]; then
        return 0
    fi
    if ! "$_sm_curl" -fsS -m 5 -X POST "http://localhost/api/settings/restartFlag" \
        -H 'Content-Type: application/json' -d '{"value":"1"}' >/dev/null 2>&1
    then
        sm_log "could not set FPP's restart flag automatically; the new command may need a manual restart of FPP to appear (use FPP's own restart control, never systemctl restart fppd)"
    fi
    return 0
}

# $1 = FPPDIR (already defaulted), $2 = plugin directory, $3 = version
sm_install_or_upgrade() {
    local _sm_fppdir _sm_plugin_dir _sm_version
    _sm_fppdir="$1"
    _sm_plugin_dir="$2"
    _sm_version="$3"

    # Cheap and entirely local: catch a command that FPP would silently
    # drop before doing any network I/O for the binary itself.
    sm_validate_command_scripts "$_sm_plugin_dir" || return 1

    sm_ensure_config_scaffold || return 1
    sm_install_binary "$_sm_plugin_dir" "$_sm_fppdir" "$_sm_version" || return 1
    sm_request_fpp_restart_flag

    return 0
}
