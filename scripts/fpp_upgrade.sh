#!/bin/sh
# Honoured by FPP 10, which calls this first and resolves the branch before
# running it. Ignored by FPP 9.x and earlier, which upgrades by running
# fpp_install.sh again instead — this script is therefore purely additive:
# nothing about the 9.x path depends on it existing or being correct.
#
# Deliberately identical in substance to fpp_install.sh, sharing the same
# idempotent core, because FPP 10's own upgrade path resets the working tree
# to the resolved branch/sha before invoking either script and expects the
# result of running this to be the same as a fresh install at that version.
#
# On FPP 9.x, the one caller that reaches this script's sibling on the
# upgrade path (www/api/controllers/plugin.php) exports FPPDIR into the
# environment rather than passing it as an argv word — see lib/common.sh's
# sm_fppdir for why this matters and is handled, not assumed.
#
# Must be committed with the executable bit set (mode 0755).

_sm_script_dir=$(cd "$(dirname "$0")" && pwd)
_sm_plugin_dir=$(cd "$_sm_script_dir/.." && pwd)

. "$_sm_script_dir/lib/common.sh"
. "$_sm_script_dir/lib/arch.sh"
. "$_sm_script_dir/lib/fetch.sh"
. "$_sm_script_dir/lib/verify.sh"
. "$_sm_script_dir/lib/commands.sh"
. "$_sm_script_dir/lib/install-core.sh"

_sm_fppdir=$(sm_fppdir "${1:-}")

_sm_version_file="$_sm_plugin_dir/VERSION"
if [ ! -f "$_sm_version_file" ]; then
    sm_log_err "VERSION file missing from plugin directory: $_sm_version_file"
    exit 1
fi
_sm_version=$(tr -d ' \t\r\n' < "$_sm_version_file")

sm_log "upgrading showmesh-fpp-plugin to $_sm_version (FPPDIR=$_sm_fppdir, plugin dir=$_sm_plugin_dir)"

if ! sm_install_or_upgrade "$_sm_fppdir" "$_sm_plugin_dir" "$_sm_version"; then
    sm_log_err "upgrade failed"
    exit 1
fi

sm_log "upgrade complete"
exit 0
