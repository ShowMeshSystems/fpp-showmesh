#!/bin/sh
# Invoked by FPP as the ShowMeshRunMacro command (see
# commands/descriptions.json), from a schedule entry, a preset, or a manual
# button press. FPP forks a fresh process for every invocation — this is not
# a supervised daemon, and there is nothing else running in the background
# for fpp_uninstall.sh to stop.
#
# The execve environment for a fired command carries no PATH, so every tool
# here is resolved to an absolute path. The command's arguments are the only
# thing FPP passes; no credential is ever accepted as an argument, because
# every command execution is published to MQTT command/run with its
# arguments in cleartext.
#
# The hand-off below (subcommand name, flag names, environment variable
# names) is this repository's own choice for how to invoke the installed
# binary and has not been cross-checked against the binary's actual
# argument parsing. It is the seam most likely to need adjusting once both
# sides exist; see README.md.
#
# Must be committed with the executable bit set (mode 0755).

_sm_script_dir=$(cd "$(dirname "$0")" && pwd)
_sm_plugin_dir=$(cd "$_sm_script_dir/.." && pwd)

. "$_sm_script_dir/lib/common.sh"

_sm_macro_id="${1:-}"
if [ -z "$_sm_macro_id" ]; then
    sm_log_err "no macro id given; the ShowMesh: Run Macro command requires one"
    exit 1
fi

_sm_binary=$(sm_binary_path "$_sm_plugin_dir")
if [ ! -x "$_sm_binary" ]; then
    sm_log_err "showmesh-fpp-plugin is not installed at $_sm_binary; cannot run macro $_sm_macro_id"
    exit 1
fi

SHOWMESH_FPP_CONFIG_DIR=$(sm_config_dir)
SHOWMESH_FPP_CREDENTIAL_FILE=$(sm_credential_file)
export SHOWMESH_FPP_CONFIG_DIR
export SHOWMESH_FPP_CREDENTIAL_FILE

exec "$_sm_binary" run-macro --macro-id "$_sm_macro_id"
