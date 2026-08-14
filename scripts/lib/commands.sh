#!/bin/sh
# Validates commands/descriptions.json against the scripts it names.
#
# Confirmed from FPP 9.5.3's own source (Plugins.cpp, LoadPluginCommands):
# the file is a JSON array; each element becomes a ScriptCommand. FPP reads
# exactly two fields from each element — "name" and "script" — and
# ScriptCommand::IsOk() is exactly a file-existence check on
# "<plugin>/commands/<script>". When that check fails, FPP silently drops
# the command and moves on: no error, no log line an operator would see, no
# entry in the UI or in GET /api/commands.
#
# This validation is deliberately stricter than IsOk(): it also requires
# the executable bit, which FPP's own existence check does not. That gap
# is real and worth closing here rather than assuming FileExists is the
# whole story — the command's own environment note above records that a
# fired command reaches its script via execve, which the kernel refuses on
# a file that exists but is not executable. A script present at 0644 would
# pass FPP's IsOk() and appear in the UI, then fail at the moment it is
# actually fired, which is a worse failure to ship than one caught here.
# It is the same family of silent-skip hazard as fpp_install.sh itself
# needing mode 0755, and gets the same defense: fail the install loudly
# rather than ship a plugin whose command quietly does not work.
#
# Requires scripts/lib/common.sh to already be sourced.

# Extracts every "script" value from a descriptions.json using a targeted
# pattern rather than a general JSON parser (this repo owns and controls
# the file's formatting, so this is precise for it): match the literal key
# "script" followed by a quoted string, which cannot collide with
# "description" or any other key name.
sm_command_script_names() {
    local _sm_desc_file _sm_grep _sm_sed
    _sm_desc_file="$1"
    _sm_grep=$(sm_resolve_bin grep /usr/bin/grep /bin/grep) || return 1
    _sm_sed=$(sm_resolve_bin sed /usr/bin/sed /bin/sed) || return 1

    "$_sm_grep" -o '"script"[[:space:]]*:[[:space:]]*"[^"]*"' "$_sm_desc_file" \
        | "$_sm_sed" -E 's/.*:[[:space:]]*"([^"]*)"/\1/'
}

# $1 = plugin directory. Fails loudly, naming every offending script and
# distinguishing "missing" from "present but not executable", if
# commands/descriptions.json is missing or names a script in either state.
sm_validate_command_scripts() {
    local _sm_plugin_dir _sm_desc_file _sm_script_name _sm_script_path _sm_bad_count
    _sm_plugin_dir="$1"
    _sm_desc_file="$_sm_plugin_dir/commands/descriptions.json"

    if [ ! -f "$_sm_desc_file" ]; then
        sm_log_err "commands/descriptions.json not found at $_sm_desc_file"
        return 1
    fi

    _sm_bad_count=0
    for _sm_script_name in $(sm_command_script_names "$_sm_desc_file"); do
        _sm_script_path="$_sm_plugin_dir/commands/$_sm_script_name"
        if [ ! -e "$_sm_script_path" ]; then
            sm_log_err "commands/descriptions.json names script '$_sm_script_name', but $_sm_script_path does not exist; FPP's ScriptCommand::IsOk() will fail and it will drop this command with no error and no trace in its UI or API"
            _sm_bad_count=$((_sm_bad_count + 1))
        elif [ ! -x "$_sm_script_path" ]; then
            sm_log_err "commands/descriptions.json names script '$_sm_script_name' at $_sm_script_path, which exists but is not executable; FPP's own existence check would let this command appear, and it would then fail silently the first time it is fired"
            _sm_bad_count=$((_sm_bad_count + 1))
        fi
    done

    if [ "$_sm_bad_count" -gt 0 ]; then
        sm_log_err "refusing to install: $_sm_bad_count command script(s) referenced in descriptions.json would silently vanish"
        return 1
    fi

    return 0
}
