#!/bin/sh
# Shared helpers for the fpp-showmesh install/upgrade/uninstall/preStart scripts.
#
# This file is sourced, never executed directly, and is POSIX sh (dash-compatible)
# because the FPP Plugin Manager runs these scripts as root with a stripped
# environment: no exported FPPDIR/SRCDIR (positional only) and no PATH. Every
# external tool this file touches is resolved to an absolute path before use.

# Candidate absolute locations for each external tool this repo shells out to.
# Debian's usr-merge means these differ across FPP host images, so each is a
# list, not a single guess, and resolution fails loudly rather than silently
# falling through to a PATH lookup that will not exist at invocation time.
sm_resolve_bin() {
    local _sm_name _sm_candidate
    _sm_name="$1"
    shift
    for _sm_candidate in "$@"; do
        if [ -x "$_sm_candidate" ]; then
            printf '%s\n' "$_sm_candidate"
            return 0
        fi
    done
    sm_log_err "required tool not found: $_sm_name (checked: $*)"
    return 1
}

sm_log() {
    printf '[fpp-showmesh] %s\n' "$*"
}

sm_log_err() {
    printf '[fpp-showmesh] ERROR: %s\n' "$*" >&2
}

# FPPDIR arrives as $1 to fpp_install.sh/fpp_upgrade.sh on FPP 9.x and earlier,
# never as an exported environment variable (the Plugin Manager runs bare
# `sudo`, which strips it). Always fall back to the documented default.
sm_fppdir() {
    printf '%s\n' "${1:-/opt/fpp}"
}

# Every entrypoint script (fpp_install.sh, fpp_upgrade.sh, fpp_uninstall.sh,
# preStart.sh, run-macro.sh) resolves its own directory with
#   _sm_script_dir=$(cd "$(dirname "$0")" && pwd)
# *before* sourcing this file, rather than calling a helper defined in here,
# because FPP invokes these scripts by absolute path while the working
# directory is documented to be the plugin's *parent*, not the plugin
# directory itself — and a script cannot source the helper that would tell
# it where itself lives. The plugin directory is one level up from
# $_sm_script_dir. This is duplicated in five small, identical lines rather
# than factored out, because the one thing that cannot live in a sourced
# file is the code that locates the sourced file.

# Fixed by the artifact contract pinned for this repository. Do not derive
# this from FPPDIR: it is deliberately outside /opt/fpp so plugin state
# survives a plugin reinstall, and deliberately outside the plugin directory
# itself so `fpp_uninstall.sh` can decide what to do with it independently of
# FPP deleting the plugin tree.
sm_config_dir() {
    printf '%s\n' "/home/fpp/media/config/plugin.fpp-showmesh"
}

sm_credential_file() {
    printf '%s\n' "$(sm_config_dir)/credential"
}

sm_binary_path() {
    printf '%s\n' "$1/showmesh-fpp-plugin"
}
