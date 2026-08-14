#!/bin/sh
# FPP's Plugin Manager calls this script as root, once per fresh install and
# again on every upgrade on FPP 9.x and earlier (which does not honour
# fpp_upgrade.sh at all). It must be safe to re-run.
#
# FPPDIR is passed as $1, positionally only — never read $FPPDIR from the
# environment, the Plugin Manager runs bare `sudo` and strips it.
#
# Must be committed with the executable bit set (mode 0755); a script
# committed at 0644 is silently skipped with nothing surfaced in FPP's UI.

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

sm_log "installing showmesh-fpp-plugin $_sm_version (FPPDIR=$_sm_fppdir, plugin dir=$_sm_plugin_dir)"

if ! sm_install_or_upgrade "$_sm_fppdir" "$_sm_plugin_dir" "$_sm_version"; then
    sm_log_err "install failed"
    exit 1
fi

sm_log "install complete"
exit 0
