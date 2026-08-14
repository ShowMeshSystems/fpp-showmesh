#!/bin/sh
# FPP calls this before deleting the plugin directory, and swallows its exit
# code — the directory is removed unconditionally regardless of what this
# script returns. So this script's only job is the state FPP does not know
# about and will not otherwise clean up: everything under the plugin's
# config directory, which lives outside the plugin directory by design (see
# README.md). This script must not touch the plugin directory itself; FPP
# owns removing that, and this script is still running from inside it while
# it executes.
#
# Must be idempotent — a second run, or a run against a host where install
# never completed, must exit 0 rather than error.
#
# Must be committed with the executable bit set (mode 0755).

_sm_script_dir=$(cd "$(dirname "$0")" && pwd)
. "$_sm_script_dir/lib/common.sh"

_sm_configdir=$(sm_config_dir)
_sm_rm=$(sm_resolve_bin rm /bin/rm /usr/bin/rm) || {
    # Even tool resolution failing must not block removal from being
    # attempted; fall through and let the shell's builtin behavior of a
    # missing command surface below rather than aborting outright.
    _sm_rm=rm
}

if [ -e "$_sm_configdir" ]; then
    sm_log "removing plugin state and credential under $_sm_configdir"
    "$_sm_rm" -rf "$_sm_configdir"
else
    sm_log "no plugin state directory at $_sm_configdir; nothing to remove"
fi

sm_log "uninstall complete"
exit 0
