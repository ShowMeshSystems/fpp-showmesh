#!/bin/sh
# Shared helpers for the fpp-showmesh install/upgrade/uninstall/preStart/
# run-macro scripts.
#
# This file is sourced, never executed directly, and is POSIX sh
# (dash-compatible). It exists because this repository's five entrypoint
# scripts run under three different, confirmed environment conventions and
# none of them can be relied on to carry a PATH:
#   - fpp_install.sh / fpp_upgrade.sh: the Plugin Manager runs bare `sudo`,
#     which strips the exported environment, so FPPDIR/SRCDIR arrive as
#     positional arguments only.
#   - preStart.sh: invoked as `/bin/bash <file>` with no arguments at all
#     (confirmed against FPP 9.5.3's scripts/functions), inheriting
#     fppd_start's own environment instead.
#   - run-macro.sh, fired as a registered command: confirmed against FPP
#     9.5.3's own source (Plugins.cpp) to receive exactly three variables —
#     MEDIADIR, FPPDIR, SCRIPTDIR — via execve, with declared arguments
#     appended positionally after the script path.
# Every external tool this file touches is resolved to an absolute path
# before use, because none of the three conventions above can be trusted
# to provide one.

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

# Takes whatever this caller's own convention supplies as a candidate
# FPPDIR value ($1 for fpp_install.sh/fpp_upgrade.sh, $FPPDIR for
# preStart.sh — see the environment-convention note above) and falls back
# to the documented default if it is empty.
sm_fppdir() {
    printf '%s\n' "${1:-/opt/fpp}"
}

# fpp_install.sh, fpp_upgrade.sh, fpp_uninstall.sh, and preStart.sh each
# resolve their own directory with
#   _sm_script_dir=$(cd "$(dirname "$0")" && pwd)
# *before* sourcing this file, rather than calling a helper defined in
# here, because FPP invokes these scripts by absolute path while the
# working directory is documented to be the plugin's *parent*, not the
# plugin directory itself — and a script cannot source the helper that
# would tell it where itself lives. The plugin directory is one level up
# from $_sm_script_dir. This is duplicated in four small, identical lines
# rather than factored out, because the one thing that cannot live in a
# sourced file is the code that locates the sourced file.
#
# run-macro.sh differs in two ways. First, it is a fired command, so FPP
# hands it SCRIPTDIR directly (see above), which is preferred there over
# deriving it from $0. Second, it lives in commands/, not scripts/ — FPP's
# own source resolves a command's "script" relative to the plugin's
# commands/ directory, not scripts/, so this file must live where FPP will
# look for it, and it reaches this one via
# "$_sm_plugin_dir/scripts/lib/common.sh" instead of the sibling-relative
# path the scripts/ entrypoints use.

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
