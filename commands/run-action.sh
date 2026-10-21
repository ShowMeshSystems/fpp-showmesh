#!/bin/sh
# Invoked by FPP as the ShowMeshRunAction command (see commands/descriptions.json).
# Environment, PATH and credential notes are in run-macro.sh and apply here unchanged.
# Must be committed with the executable bit set (mode 0755).

# FPP sets SCRIPTDIR to this directory; dirname is the fallback for manual runs.
_sm_script_dir="${SCRIPTDIR:-$(cd "$(dirname "$0")" && pwd)}"
_sm_plugin_dir=$(cd "$_sm_script_dir/.." && pwd)

. "$_sm_plugin_dir/scripts/lib/common.sh"

_sm_action_id="${1:-}"
if [ -z "$_sm_action_id" ]; then
    sm_log_err "No action chosen. Pick an action in the ShowMesh: Run Action command."
    exit 1
fi

_sm_binary=$(sm_binary_path "$_sm_plugin_dir")
if [ ! -x "$_sm_binary" ]; then
    sm_log_err "showmesh-fpp-plugin is not installed at $_sm_binary; cannot run action $_sm_action_id"
    exit 1
fi

# The "--" keeps an id that starts with a hyphen from being read as a flag.
exec "$_sm_binary" action --config-dir "$(sm_state_dir)" -- "$_sm_action_id"
