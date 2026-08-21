#!/bin/sh
# FPP calls this before deleting the plugin directory, and swallows its exit
# code — the directory is removed unconditionally regardless of what this
# script returns. So this script's only job is the state FPP does not know
# about and will not otherwise clean up: everything this repository creates
# outside the plugin directory, which is two separate locations (see
# README.md for why they are split): the credential directory
# (/etc/showmesh-fpp-plugin) and the non-secret plugin state directory
# under FPP's media tree (/home/fpp/media/plugindata/fpp-showmesh). This
# script must not touch the plugin directory itself; FPP owns removing
# that, and this script is still running from inside it while it executes.
#
# Must be idempotent — a second run, or a run against a host where install
# never completed, must exit 0 rather than error.
#
# Must be committed with the executable bit set (mode 0755).

_sm_script_dir=$(cd "$(dirname "$0")" && pwd)
. "$_sm_script_dir/lib/common.sh"

_sm_rm=$(sm_resolve_bin rm /bin/rm /usr/bin/rm) || {
    # Even tool resolution failing must not block removal from being
    # attempted; fall through to the same absolute-path candidate
    # sm_resolve_bin itself checks first, rather than a bare "rm" that
    # depends on a PATH none of this repository's invocation conventions
    # guarantee (see common.sh's header). If /bin/rm genuinely is not
    # there either, the invocation below fails loudly with a normal
    # "command not found" instead of silently no-oping.
    _sm_rm=/bin/rm
}

_sm_creddir=$(sm_credential_dir)
if [ -e "$_sm_creddir" ]; then
    sm_log "removing credential directory $_sm_creddir"
    "$_sm_rm" -rf "$_sm_creddir"
else
    sm_log "no credential directory at $_sm_creddir; nothing to remove"
fi

_sm_statedir=$(sm_state_dir)
if [ -e "$_sm_statedir" ]; then
    sm_log "removing plugin state directory $_sm_statedir"
    "$_sm_rm" -rf "$_sm_statedir"
else
    sm_log "no plugin state directory at $_sm_statedir; nothing to remove"
fi

sm_log "uninstall complete"
exit 0
