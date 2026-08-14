#!/bin/sh
# Run by FPP at fppd startup. Must be a no-op in the common case: an
# unconditional repair attempt here delays every fppd start on every boot,
# which is the documented failure this pattern exists to avoid. The guard
# below is a single stat-and-executable check with nothing sourced and
# nothing on the network, before anything heavier runs.
#
# The failure this exists to catch is an SD card or disk image cloned from a
# host of a different architecture, or a binary otherwise missing or
# corrupted since the last successful install — never a routine occurrence.
#
# Confirmed against FPP 9.5.3's own source (scripts/functions,
# runPreStartScripts): this script is invoked as `/bin/bash <file>` with
# NO arguments at all, unlike fpp_install.sh/fpp_upgrade.sh. It inherits
# fppd_start's own shell environment instead of the stripped three-variable
# execve environment a fired command gets — a different situation from
# both of the other two conventions in this repository, so FPPDIR is read
# below from the environment, not from a positional argument, though
# whether it is reliably set to the right value in that inherited
# environment has not been independently confirmed; /opt/fpp remains the
# fallback either way.
#
# Must be committed with the executable bit set (mode 0755).

_sm_script_dir=$(cd "$(dirname "$0")" && pwd)
_sm_plugin_dir=$(cd "$_sm_script_dir/.." && pwd)
_sm_binary="$_sm_plugin_dir/showmesh-fpp-plugin"

if [ -x "$_sm_binary" ]; then
    # Common case: nothing to do. No log line here either — this runs on
    # every fppd start and a healthy install should be silent.
    exit 0
fi

. "$_sm_script_dir/lib/common.sh"
. "$_sm_script_dir/lib/arch.sh"
. "$_sm_script_dir/lib/fetch.sh"
. "$_sm_script_dir/lib/verify.sh"
. "$_sm_script_dir/lib/install-core.sh"

sm_log "showmesh-fpp-plugin binary missing or not executable at $_sm_binary; attempting repair"

_sm_fppdir=$(sm_fppdir "${FPPDIR:-}")

_sm_version_file="$_sm_plugin_dir/VERSION"
if [ ! -f "$_sm_version_file" ]; then
    sm_log_err "VERSION file missing from plugin directory: $_sm_version_file; cannot repair"
    exit 1
fi
_sm_version=$(tr -d ' \t\r\n' < "$_sm_version_file")

if ! sm_install_binary "$_sm_plugin_dir" "$_sm_fppdir" "$_sm_version"; then
    sm_log_err "repair failed; the ShowMesh command will not work until this is fixed"
    exit 1
fi

sm_log "repair complete"
exit 0
