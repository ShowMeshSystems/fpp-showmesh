#!/bin/sh
# Shared body of the ShowMesh night commands in descriptions.json. Each
# registered command's own script execs this with its lifecycle command
# name; FPP's environment and credential rules are those in run-macro.sh.

_sm_script_dir="${SCRIPTDIR:-$(cd "$(dirname "$0")" && pwd)}"
_sm_plugin_dir=$(cd "$_sm_script_dir/.." && pwd)

. "$_sm_plugin_dir/scripts/lib/common.sh"

_sm_night_command="${1:-}"
if [ -z "$_sm_night_command" ]; then
    sm_log_err "no night command given"
    exit 1
fi

_sm_binary=$(sm_binary_path "$_sm_plugin_dir")
if [ ! -x "$_sm_binary" ]; then
    sm_log_err "showmesh-fpp-plugin is not installed at $_sm_binary; cannot send $_sm_night_command"
    exit 1
fi

exec "$_sm_binary" night --config-dir "$(sm_state_dir)" "$_sm_night_command"
