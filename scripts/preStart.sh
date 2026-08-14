#!/bin/sh
# Run by FPP at fppd startup. Must be cheap in the common case: an
# unconditional repair attempt here delays every fppd start on every boot,
# which is the documented failure this pattern exists to avoid. The two
# checks below are both purely local (a file test and a handful of local
# file reads for architecture detection — never the network) so they run
# on every boot at negligible cost; only an actual repair reaches the
# network, and only that path is capped and bounded below.
#
# Two failures this guards against, not one:
#   - the binary missing or not executable at all, and
#   - a binary that IS present and executable but was built for a
#     different architecture than this host now has, which is exactly
#     what an SD card or disk image cloned from a host of a different
#     architecture produces. The first pass of this script checked only
#     [ -x "$_sm_binary" ], which a cloned, wrong-architecture binary
#     passes cleanly — nothing on disk recorded which architecture had
#     been installed, so nothing could have compared. The architecture
#     stamp sm_install_binary now writes (see sm_arch_stamp_path in
#     lib/common.sh) is what makes the second check possible.
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

. "$_sm_script_dir/lib/common.sh"
. "$_sm_script_dir/lib/arch.sh"

_sm_fppdir=$(sm_fppdir "${FPPDIR:-}")

if [ ! -x "$_sm_binary" ]; then
    _sm_repair_reason="binary missing or not executable at $_sm_binary"
else
    # sm_arch_repair_reason is the testable form of this comparison — see
    # its comment in lib/arch.sh for why it is a function and not left
    # inline here.
    _sm_repair_reason=$(sm_arch_repair_reason "$_sm_plugin_dir" "$_sm_fppdir")
fi

if [ -z "$_sm_repair_reason" ]; then
    # Common case: nothing to do. No log line here either — this runs on
    # every fppd start and a healthy install should be silent.
    exit 0
fi

sm_log "repair needed: $_sm_repair_reason"

. "$_sm_script_dir/lib/fetch.sh"
. "$_sm_script_dir/lib/verify.sh"
. "$_sm_script_dir/lib/commands.sh"
. "$_sm_script_dir/lib/install-core.sh"

_sm_version_file="$_sm_plugin_dir/VERSION"
if [ ! -f "$_sm_version_file" ]; then
    sm_log_err "VERSION file missing from plugin directory: $_sm_version_file; cannot repair"
    exit 1
fi
_sm_version=$(tr -d ' \t\r\n' < "$_sm_version_file")

# A much tighter network budget than a foreground, human-initiated
# install: this runs at fppd startup and must not block a boot for
# minutes of retries on a networkless host. sm_download in lib/fetch.sh
# honours these.
SM_DOWNLOAD_CONNECT_TIMEOUT="${SM_DOWNLOAD_CONNECT_TIMEOUT:-5}"
SM_DOWNLOAD_MAX_TIME="${SM_DOWNLOAD_MAX_TIME:-15}"
export SM_DOWNLOAD_CONNECT_TIMEOUT SM_DOWNLOAD_MAX_TIME

# The full install/upgrade path, not just the binary fetch: a repair that
# only replaced the binary would never re-scaffold the credential and
# state directories, which is exactly the same class of gap as the
# architecture-stamp bug above — a guard whose narrower predecessor could
# not catch the failure it was named for.
if ! sm_install_or_upgrade "$_sm_fppdir" "$_sm_plugin_dir" "$_sm_version"; then
    sm_log_err "repair failed; the ShowMesh command will not work until this is fixed"
    exit 1
fi

sm_log "repair complete"
exit 0
