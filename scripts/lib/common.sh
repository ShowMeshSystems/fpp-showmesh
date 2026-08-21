#!/bin/sh
# Shared helpers for the fpp-showmesh install/upgrade/uninstall/preStart/
# run-macro scripts.
#
# This file is sourced, never executed directly, and is POSIX sh
# (dash-compatible). It exists because this repository's five entrypoint
# scripts run under three different, confirmed environment conventions and
# none of them can be relied on to carry a PATH:
#   - fpp_install.sh / fpp_upgrade.sh: two DIFFERENT invocation shapes,
#     confirmed by reading both of FPP's own callers rather than one.
#     scripts/install_plugin (the fresh-install path) invokes
#       fpp_install.sh FPPDIR=<dir> SRCDIR=<dir>/src
#     as ordinary argv words — that is, "FPPDIR=/opt/fpp" is the literal
#     string $1 arrives as, not a shell assignment, and it is NOT also
#     exported. www/api/controllers/plugin.php's upgrade path instead runs
#       system($SUDO . " FPPDIR=" . $fppDir . " SRCDIR=" . $fppDir . "/src " . $install_script, ...)
#     where the assignments sit BEFORE the command, making them shell
#     environment assignments for sudo to carry — here $1 is empty and
#     FPPDIR is exported instead. So a fresh install puts the value in
#     argv and nothing in the environment; an upgrade puts it in the
#     environment and nothing in argv. Both must be handled; see
#     sm_fppdir below. This corrects this repository's own first-pass
#     premise, which claimed the Plugin Manager always strips FPPDIR from
#     the environment (true only for the install path) and then built a
#     rule on it ("never read $FPPDIR") that broke the upgrade path
#     entirely — see the correction below and the capture in
#     docs/bench-capture-fpp-9.5.3.md.
#   - preStart.sh: invoked as `/bin/bash <file>` with no arguments at all
#     (confirmed against FPP 9.5.3's scripts/functions), inheriting
#     fppd_start's own environment instead.
#   - run-macro.sh, fired as a registered command: confirmed against FPP
#     9.5.3's own source (Plugins.cpp) to receive exactly three variables —
#     MEDIADIR, FPPDIR, SCRIPTDIR — via execve, with declared arguments
#     appended positionally after the script path.
# Every external tool this file touches is resolved to an absolute path
# before use, because none of the three conventions above can be trusted
# to provide one.

# Candidate absolute locations for each external tool this repo shells out to.
# Debian's usr-merge means these differ across FPP host images, so each is a
# list, not a single guess, and resolution fails loudly rather than silently
# falling through to a PATH lookup that will not exist at invocation time.
sm_resolve_bin() {
    local _sm_name _sm_candidate
    _sm_name="$1"
    shift
    for _sm_candidate in "$@"; do
        if [ -x "$_sm_candidate" ]; then
            printf '%s\n' "$_sm_candidate"
            return 0
        fi
    done
    sm_log_err "required tool not found: $_sm_name (checked: $*)"
    return 1
}

sm_log() {
    printf '[fpp-showmesh] %s\n' "$*"
}

sm_log_err() {
    printf '[fpp-showmesh] ERROR: %s\n' "$*" >&2
}

# Resolves FPPDIR by trying every source in order, because FPP hands it
# over differently depending on which of its own two callers ran this
# script (see the note above): belt and braces rather than trusting either
# alone.
#   1. $FPPDIR from the environment — set on the upgrade path (plugin.php
#      exports it before invoking sudo -E), unset on the fresh-install path.
#   2. $1, with a "FPPDIR=" prefix stripped if present — set on the
#      fresh-install path (install_plugin passes "FPPDIR=<dir>" as a plain
#      argv word, not a shell assignment), empty on the upgrade path.
#   3. The documented default, /opt/fpp, if neither produced anything.
sm_fppdir() {
    local _sm_from_env _sm_from_arg
    _sm_from_env="${FPPDIR:-}"
    if [ -n "$_sm_from_env" ]; then
        printf '%s\n' "$_sm_from_env"
        return 0
    fi

    _sm_from_arg="${1:-}"
    case "$_sm_from_arg" in
        FPPDIR=*)
            _sm_from_arg="${_sm_from_arg#FPPDIR=}"
            ;;
    esac
    if [ -n "$_sm_from_arg" ]; then
        printf '%s\n' "$_sm_from_arg"
        return 0
    fi

    printf '%s\n' "/opt/fpp"
}

# fpp_install.sh, fpp_upgrade.sh, fpp_uninstall.sh, and preStart.sh each
# resolve their own directory with
#   _sm_script_dir=$(cd "$(dirname "$0")" && pwd)
# *before* sourcing this file, rather than calling a helper defined in
# here, because FPP invokes these scripts by absolute path while the
# working directory is documented to be the plugin's *parent*, not the
# plugin directory itself — and a script cannot source the helper that
# would tell it where itself lives. The plugin directory is one level up
# from $_sm_script_dir. This is duplicated in four small, identical lines
# rather than factored out, because the one thing that cannot live in a
# sourced file is the code that locates the sourced file.
#
# run-macro.sh differs in two ways. First, it is a fired command, so FPP
# hands it SCRIPTDIR directly (see above), which is preferred there over
# deriving it from $0. Second, it lives in commands/, not scripts/ — FPP's
# own source resolves a command's "script" relative to the plugin's
# commands/ directory, not scripts/, so this file must live where FPP will
# look for it, and it reaches this one via
# "$_sm_plugin_dir/scripts/lib/common.sh" instead of the sibling-relative
# path the scripts/ entrypoints use.

# Fixed by the artifact contract pinned for this repository. Neither is
# derived from FPPDIR or from the plugin directory, so both survive a
# plugin reinstall and both are independent of what FPP deletes when it
# removes the plugin tree — `fpp_uninstall.sh` decides what to do with
# each on its own.
#
# The credential moved out of FPP's own config tree entirely, and out from
# under the plugin's non-secret state, after review found that FPP serves
# `/home/fpp/media/config/` unauthenticated over its own HTTP API — a GET
# on it returns file contents with no credential check, and an
# unauthenticated POST to the same endpoint can create subdirectories
# under it. A credential living anywhere under that tree is one
# unauthenticated request away from being read by anything that can reach
# the FPP web UI, which is a strictly worse exposure than the general
# cleartext-on-the-show-LAN posture this project otherwise accepts for
# commands and telemetry. /etc is outside anything FPP's API serves.
sm_credential_dir() {
    printf '%s\n' "/etc/showmesh-fpp-plugin"
}

sm_credential_file() {
    printf '%s\n' "$(sm_credential_dir)/credential"
}

# Non-secret plugin state (config.json, status.json, failures.json,
# macro-cache.json) stays under FPP's media tree, alongside other plugin
# data, since none of it is a credential and none of it needs to be
# outside what FPP itself serves.
sm_state_dir() {
    printf '%s\n' "/home/fpp/media/plugindata/fpp-showmesh"
}

sm_binary_path() {
    printf '%s\n' "$1/showmesh-fpp-plugin"
}

# Records which architecture was actually fetched, next to the binary
# itself, so preStart.sh can compare a fresh detection against what was
# installed rather than trusting an [ -x ] check alone. A disk image
# cloned from a host of a different architecture carries a present,
# executable, wrong-architecture binary — the mode test that guard used to
# rely on exclusively cannot see that, because nothing on disk recorded
# which architecture was installed to compare against. This file is what
# makes that comparison possible.
sm_arch_stamp_path() {
    printf '%s\n' "$1/.installed-arch"
}

# Records the sha256 of the binary that was actually live at the moment of
# the last successful activation, and the version that binary belonged to.
# Written next to .installed-arch by sm_install_binary's post-activation
# steps. sm_local_repair (install-core.sh) is the only reader: a local
# promotion candidate must match the recorded hash before it is trusted,
# and a recorded version that disagrees with what this host should be
# running means the repair must not report itself complete without
# actually reinstalling. See install-core.sh's header for the defect this
# closes: promoting a same-named, same-mode file with no content check at
# all.
sm_hash_stamp_path() {
    printf '%s\n' "$1/.installed-sha256"
}

sm_version_stamp_path() {
    printf '%s\n' "$1/.installed-version"
}

# Reads a stamp file's contents with trailing whitespace stripped by
# command substitution, absolute-path tool resolution included so this
# stays consistent with every other read in this repository. Prints
# nothing and returns non-zero if the file cannot be read.
sm_read_stamp() {
    local _sm_cat
    _sm_cat=$(sm_resolve_bin cat /bin/cat /usr/bin/cat) || return 1
    "$_sm_cat" "$1" 2>/dev/null
}

# Reads back the octal permission bits actually set on a path, trying GNU
# stat's format first (Debian FPP hosts) and falling back to BSD/macOS
# stat's format so this repository's own tests run unmodified on a
# developer Mac. Prints nothing and returns non-zero if neither works.
sm_current_mode() {
    local _sm_stat _sm_path _sm_result
    _sm_path="$1"
    _sm_stat=$(sm_resolve_bin stat /usr/bin/stat /bin/stat) || return 1
    _sm_result=$("$_sm_stat" -c '%a' "$_sm_path" 2>/dev/null) || \
        _sm_result=$("$_sm_stat" -f '%OLp' "$_sm_path" 2>/dev/null)
    if [ -z "$_sm_result" ]; then
        return 1
    fi
    printf '%s\n' "$_sm_result"
}

# Confirms a chmod actually took effect, rather than trusting its exit
# code alone. A vfat or exFAT mount (FPP explicitly supports the media
# directory on a USB stick) reports chmod as successful while the
# filesystem itself derives every file's mode from mount options, so the
# requested mode silently never applies. Catching that here, at install
# time, is the difference between a clear failure now and the binary
# refusing to start at showtime because a 0600 credential file is
# actually 0777.
sm_verify_mode() {
    local _sm_path _sm_expected _sm_actual
    _sm_path="$1"
    _sm_expected="$2"
    _sm_actual=$(sm_current_mode "$_sm_path") || {
        sm_log_err "could not read back the permission bits on $_sm_path to verify them"
        return 1
    }
    if [ "$_sm_actual" != "$_sm_expected" ]; then
        sm_log_err "mode verification failed for $_sm_path: requested $_sm_expected, filesystem reports $_sm_actual (a vfat/exFAT mount silently ignoring chmod, because it derives modes from mount options, produces exactly this mismatch)"
        return 1
    fi
    return 0
}
