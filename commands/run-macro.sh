#!/bin/sh
# Invoked by FPP as the ShowMeshRunMacro command (see
# commands/descriptions.json), from a schedule entry, a preset, or a manual
# button press. FPP forks a fresh process for every invocation — this is not
# a supervised daemon, and there is nothing else running in the background
# for fpp_uninstall.sh to stop.
#
# Confirmed against FPP 9.5.3's own source (Plugins.cpp / ScriptCommand):
# the execve environment for a fired command carries exactly three
# variables — MEDIADIR, FPPDIR, SCRIPTDIR — and no PATH, so every tool here
# is resolved to an absolute path. The command's declared arguments are
# appended positionally after the script path; no credential is ever
# accepted as an argument, because every command execution is published to
# MQTT command/run with its arguments in cleartext.
#
# SCRIPTDIR is FPP's own name for this script's directory (the plugin's
# commands/ directory, confirmed by the same source read: "script" in
# descriptions.json is resolved relative to commands/, not scripts/, so
# this file lives there and not alongside the other entrypoint scripts)
# and is a more reliable anchor than deriving it from $0, so it is
# preferred here and dirname is only a fallback for running this script by
# hand outside FPP. The shared library lives under scripts/lib, one level
# below the plugin root rather than below this file's own directory.
#
# The invocation contract below (subcommand name and argument order) is
# pinned against the binary's actual CLI, confirmed by the team building
# it: `showmesh-fpp-plugin run <macroId>`. The config directory is passed
# explicitly with --config-dir so this script's placement of plugin state
# is authoritative regardless of what MEDIADIR resolves to on a given
# host, rather than relying on the binary's own MEDIADIR-based fallback.
# There is no credential flag or variable: the binary always reads the
# credential from <configdir>/credential and that path is not
# configurable, deliberately, so there is no way to aim it anywhere else.
#
# Must be committed with the executable bit set (mode 0755).

_sm_script_dir="${SCRIPTDIR:-$(cd "$(dirname "$0")" && pwd)}"
_sm_plugin_dir=$(cd "$_sm_script_dir/.." && pwd)

. "$_sm_plugin_dir/scripts/lib/common.sh"

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

exec "$_sm_binary" run --config-dir "$(sm_config_dir)" "$_sm_macro_id"
