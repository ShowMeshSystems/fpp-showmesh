#!/bin/sh
# Shared body of fpp_install.sh and fpp_upgrade.sh.
#
# Both entrypoints call sm_install_or_upgrade with the same arguments and it
# is written to be safe to re-run: FPP 9.x honours fpp_install.sh on every
# upgrade (it does not call fpp_upgrade.sh at all) while FPP 10 calls
# fpp_upgrade.sh first, so this body cannot assume it only ever runs once.
# preStart.sh's repair path also calls sm_install_or_upgrade directly
# (not just sm_install_binary), so that a repair re-scaffolds permissions
# too, not only the binary.
#
# Requires common.sh, arch.sh, fetch.sh, verify.sh, commands.sh, lock.sh,
# and activate.sh to already be sourced.

# Creates the plugin's credential directory/file and non-secret state
# directory/files, without overwriting anything that already exists. This
# runs on every install, upgrade, and preStart repair, so an existing
# credential or config must survive a re-run untouched.
#
# Every chown and chmod here is checked, and every chmod is followed by
# reading the mode back rather than trusting the exit code alone. FPP
# supports running its media directory from a USB stick, and a vfat or
# exFAT mount reports chmod as successful while actually deriving every
# file's mode from mount options — silently ignoring the request. Catching
# that here turns a silent install-time misconfiguration into a loud
# install failure, instead of the credential file being readable by
# everything on the host and the binary refusing to start at showtime
# because it requires exactly 0600.
# Creates directory $1 (mode $2, e.g. "0700") if missing and chowns/chmods
# it to fpp:fpp, refusing outright rather than following if a symlink is
# ever found at $1. Every scaffold directory lives inside a tree the
# "fpp" system user (the user fppd and this plugin's own binary run as)
# can also write to, so a symlink planted there before a root-run install
# or repair is a real, reachable attack, not a theoretical one; see
# sm_ensure_config_scaffold's header. The check is repeated immediately
# before every mutating call rather than once up front: the check and the
# following syscall are never atomic in the shell, so re-checking closes
# as much of that race as a shell script can. `chown -h` is used even
# though a directory is never legitimately a symlink here (it is refused
# above), as defence in depth for exactly that race: if a symlink is
# planted in the gap between the last check and this call, `-h` changes
# only the symlink's own ownership via lchown(2) rather than following it
# into whatever it points at. `chmod` has no such flag on Linux (there is
# no lchmod(2)), so the repeated `sm_refuse_symlink` check immediately
# before it is the only defence available for that step.
#
# The chown target is overridable via SM_INSTALL_OWNER, the same pattern
# sm_stage_binary in activate.sh uses, so this repository's own tests can
# exercise a real, successful chown without an "fpp" system user existing
# on the developer machine running them; production code never sets it
# and gets the real fpp:fpp target.
sm_scaffold_dir() {
    local _sm_path _sm_mode _sm_mode_bare _sm_mkdir _sm_chown _sm_chmod
    _sm_path="$1"
    _sm_mode="$2"
    _sm_mode_bare="${_sm_mode#0}"

    _sm_mkdir=$(sm_resolve_bin mkdir /bin/mkdir /usr/bin/mkdir) || return 1
    _sm_chown=$(sm_resolve_bin chown /bin/chown /usr/bin/chown /usr/sbin/chown) || return 1
    _sm_chmod=$(sm_resolve_bin chmod /bin/chmod /usr/bin/chmod) || return 1

    sm_refuse_symlink "$_sm_path" || return 1
    "$_sm_mkdir" -p "$_sm_path" || {
        sm_log_err "could not create directory: $_sm_path"
        return 1
    }
    sm_refuse_symlink "$_sm_path" || return 1
    "$_sm_chown" -h "${SM_INSTALL_OWNER:-fpp:fpp}" "$_sm_path" || {
        sm_log_err "could not set ownership of $_sm_path to ${SM_INSTALL_OWNER:-fpp:fpp}"
        return 1
    }
    sm_refuse_symlink "$_sm_path" || return 1
    "$_sm_chmod" "$_sm_mode" "$_sm_path" || {
        sm_log_err "could not set permissions on $_sm_path"
        return 1
    }
    sm_verify_mode "$_sm_path" "$_sm_mode_bare"
}

# Creates file $1 (mode $2) with default content $3 if missing, and
# chowns/chmods it to fpp:fpp, using the same refuse-rather-than-follow
# discipline as sm_scaffold_dir above, plus one more step that directory
# does not need: the file's own creation. `sm_create_new_file` uses the
# shell's noclobber option so the existence check and the write happen as
# one kernel-level operation, closing the specific hole a `[ ! -e ]` test
# followed by a redirect left open: a dangling symlink reads as "does
# not exist" under `-e` (it dereferences), so that older sequence let a
# root-run redirect create a brand-new, root-written file at whatever
# path the dangling symlink named.
sm_scaffold_file() {
    local _sm_path _sm_mode _sm_mode_bare _sm_default _sm_chown _sm_chmod
    _sm_path="$1"
    _sm_mode="$2"
    _sm_default="$3"
    _sm_mode_bare="${_sm_mode#0}"

    _sm_chown=$(sm_resolve_bin chown /bin/chown /usr/bin/chown /usr/sbin/chown) || return 1
    _sm_chmod=$(sm_resolve_bin chmod /bin/chmod /usr/bin/chmod) || return 1

    sm_refuse_symlink "$_sm_path" || return 1
    if [ ! -e "$_sm_path" ]; then
        sm_create_new_file "$_sm_path" "$_sm_default" || return 1
    fi
    sm_refuse_symlink "$_sm_path" || return 1
    "$_sm_chown" -h "${SM_INSTALL_OWNER:-fpp:fpp}" "$_sm_path" || {
        sm_log_err "could not set ownership of $_sm_path to ${SM_INSTALL_OWNER:-fpp:fpp}"
        return 1
    }
    sm_refuse_symlink "$_sm_path" || return 1
    "$_sm_chmod" "$_sm_mode" "$_sm_path" || {
        sm_log_err "could not set permissions on $_sm_path"
        return 1
    }
    sm_verify_mode "$_sm_path" "$_sm_mode_bare"
}

# Creates the plugin's credential directory/file and non-secret state
# directory/files, without overwriting anything that already exists. This
# runs on every install, upgrade, and preStart repair, so an existing
# credential or config must survive a re-run untouched.
#
# Every path here sits inside a directory the "fpp" system user can also
# write to (fppd and this plugin's own binary both run as fpp), and this
# function itself runs as root on every install, upgrade, and preStart
# repair. Before the symlink refusals in sm_scaffold_dir and
# sm_scaffold_file above existed, "fpp" planting a symlink at any of these
# paths turned the next repair into a root-run chown/chmod, or a
# root-written file creation, at whatever the symlink pointed to.
# Verified against a real Debian container: a root:root 0644 file outside
# this tree ended up fpp:fpp 0600 after one repair pass, and a dangling
# symlink caused a brand-new fpp:fpp 0600 file to be created at its
# target. Every mutating call below refuses a symlink rather than
# following it.
sm_ensure_config_scaffold() {
    local _sm_creddir _sm_credfile _sm_credfile_is_new _sm_statedir
    local _sm_name_default _sm_fname _sm_default _sm_fpath

    # Credential directory and file. Deliberately outside FPP's own
    # media/config tree — see sm_credential_dir's comment in common.sh for
    # why — so nothing FPP itself serves over HTTP can reach it.
    _sm_creddir=$(sm_credential_dir)
    sm_scaffold_dir "$_sm_creddir" 0700 || return 1

    _sm_credfile=$(sm_credential_file)
    _sm_credfile_is_new=0
    if [ ! -e "$_sm_credfile" ] && [ ! -L "$_sm_credfile" ]; then
        _sm_credfile_is_new=1
    fi
    sm_scaffold_file "$_sm_credfile" 0600 "" || return 1
    # Logged only after sm_scaffold_file actually succeeds, not merely
    # attempted: a log line claiming a file was created must not fire
    # ahead of confirming the creation (and the ownership and mode that
    # follow it) actually went through.
    if [ "$_sm_credfile_is_new" -eq 1 ]; then
        sm_log "created empty credential file at $_sm_credfile; it must be provisioned with a scheduler credential before the plugin can act"
    fi

    # Non-secret state directory and files, under FPP's media tree.
    _sm_statedir=$(sm_state_dir)
    sm_scaffold_dir "$_sm_statedir" 0700 || return 1

    # 0600, matching what the binary itself uses when it rewrites these
    # files — the scaffold and the binary must agree on one mode rather
    # than disagreeing from the moment install finishes to the moment the
    # binary first writes.
    for _sm_name_default in \
        "config.json:{}" \
        "status.json:{}" \
        "failures.json:[]" \
        "macro-cache.json:{}"
    do
        _sm_fname="${_sm_name_default%%:*}"
        _sm_default="${_sm_name_default#*:}"
        _sm_fpath="$_sm_statedir/$_sm_fname"
        sm_scaffold_file "$_sm_fpath" 0600 "$_sm_default" || return 1
    done

    return 0
}

# Fetches, verifies, and installs the binary for this host's architecture.
# Always re-fetches: called on both install and upgrade, and a version bump
# is exactly the case where the previously installed binary must not be kept.
#
# Verification is against this repository's own committed
# artifacts.lock.json (see lib/lock.sh), not against a checksum manifest
# fetched from the same host as the tarball; see verify.sh's header for
# why that distinction matters. Activation is stage-then-swap (see
# lib/activate.sh): the new binary is fully staged and validated before
# anything at the live target path is touched, and the previous binary is
# preserved until the mode re-verification below also succeeds; see the
# transaction-boundary comment inside sm_install_binary below.
sm_install_binary() {
    local _sm_plugin_dir _sm_fppdir _sm_version _sm_arch _sm_tarball_name
    local _sm_base_url _sm_expected_hash _sm_mktemp _sm_workdir _sm_rm _sm_tar
    local _sm_target _sm_staging
    _sm_plugin_dir="$1"
    _sm_fppdir="$2"
    _sm_version="$3"

    _sm_arch=$(sm_detect_arch "$_sm_fppdir") || {
        sm_log_err "architecture detection failed; refusing to guess an artifact"
        return 1
    }
    sm_log "detected architecture: $_sm_arch"

    _sm_tarball_name=$(sm_artifact_tarball_name "$_sm_version" "$_sm_arch")
    _sm_base_url=$(sm_artifact_base_url "$_sm_version")
    sm_check_base_url_scheme "$_sm_base_url" || return 1

    # Resolved before any network access: a missing, malformed, or
    # version-mismatched lock refuses the install outright rather than
    # fetching bytes when there is nothing trustworthy to check them
    # against.
    _sm_expected_hash=$(sm_lock_expected_sha256 "$_sm_plugin_dir" "$_sm_version" "$_sm_tarball_name") || {
        sm_log_err "refusing to install without a matching artifacts.lock.json entry for $_sm_tarball_name"
        return 1
    }

    _sm_mktemp=$(sm_resolve_bin mktemp /bin/mktemp /usr/bin/mktemp) || return 1
    _sm_rm=$(sm_resolve_bin rm /bin/rm /usr/bin/rm) || return 1
    _sm_workdir=$("$_sm_mktemp" -d /tmp/fpp-showmesh.XXXXXX) || {
        sm_log_err "could not create a temporary working directory"
        return 1
    }
    # No trap here, deliberately: a trap set inside a function is process-
    # global in POSIX sh, not function-scoped, so it would silently
    # replace any EXIT trap a caller already had set. Cleaning up
    # explicitly on every return path below is more verbose but does not
    # have that hazard.

    sm_log "fetching $_sm_tarball_name from $_sm_base_url"
    if ! sm_download "$_sm_base_url/$_sm_tarball_name" "$_sm_workdir/$_sm_tarball_name"; then
        "$_sm_rm" -rf "$_sm_workdir"
        return 1
    fi

    if ! sm_verify_sha256 "$_sm_workdir/$_sm_tarball_name" "$_sm_expected_hash"; then
        sm_log_err "refusing to install an artifact that failed checksum verification against artifacts.lock.json"
        "$_sm_rm" -rf "$_sm_workdir"
        return 1
    fi

    _sm_tar=$(sm_resolve_bin tar /bin/tar /usr/bin/tar) || {
        "$_sm_rm" -rf "$_sm_workdir"
        return 1
    }
    if ! "$_sm_tar" -xzf "$_sm_workdir/$_sm_tarball_name" -C "$_sm_workdir"; then
        sm_log_err "could not extract $_sm_tarball_name"
        "$_sm_rm" -rf "$_sm_workdir"
        return 1
    fi

    if [ ! -f "$_sm_workdir/showmesh-fpp-plugin" ]; then
        sm_log_err "$_sm_tarball_name did not contain showmesh-fpp-plugin at its top level"
        "$_sm_rm" -rf "$_sm_workdir"
        return 1
    fi

    _sm_target=$(sm_binary_path "$_sm_plugin_dir")
    # Staged in the same directory as the final target, deliberately: see
    # lib/activate.sh's header for why that is what makes the final
    # activation rename atomic.
    _sm_staging="$_sm_target.staging"

    if ! sm_stage_binary "$_sm_workdir/showmesh-fpp-plugin" "$_sm_staging"; then
        "$_sm_rm" -rf "$_sm_workdir"
        return 1
    fi
    "$_sm_rm" -rf "$_sm_workdir"

    if ! sm_activate_binary "$_sm_staging" "$_sm_target"; then
        return 1
    fi

    # Transaction boundary: sm_activate_binary's rename already made the
    # new binary live, but the previous binary is deliberately still
    # preserved at $_sm_target.previous until the mode re-verification
    # below also succeeds. A failure there rolls the live binary back to
    # what was running before this install started, via
    # sm_activate_rollback, instead of reporting the install as failed
    # while actually leaving the new, unverified binary live with no way
    # back, which is what happened before this boundary existed here.

    # Cheap re-confirmation that the rename actually landed a 0755 binary
    # at the target, in the same spirit as every other mode check in this
    # repository trusting a readback over an exit code alone.
    if ! sm_verify_mode "$_sm_target" 755; then
        sm_activate_undo "$_sm_target"
        return 1
    fi

    # The binary itself is fully committed here: the previous binary is no
    # longer needed, and nothing below this line ever rolls the activation
    # back. Stamps are written strictly AFTER this point and on purpose:
    # they are metadata describing an already-good, already-live binary,
    # never data whose own write failure should undo an activation that
    # already succeeded. An earlier version wrote stamps before this
    # commit and rolled the binary back on a failed stamp write, which
    # left a rolled-back binary next to a stamp that still described the
    # binary that got discarded, since sm_activate_undo restores only the
    # binary. A stamp write failing now is reported below without
    # touching the binary that is already correctly in place.
    sm_activate_commit "$_sm_target"

    # The stamp is written to a temp file and renamed onto its final path
    # (sm_write_stamp), never written in place: an in-place write that
    # fails partway (a full disk, a write-limited filesystem) would
    # otherwise truncate an existing stamp to empty rather than leaving it
    # unchanged, and an empty stamp read back later is indistinguishable
    # from "nothing to compare" in exactly the guard this stamp exists to
    # feed (see sm_arch_repair_reason in lib/arch.sh). sm_write_stamp_or_
    # sentinel additionally makes a failed write on a FRESH path (nothing
    # was ever recorded there) self-correcting, rather than permanently
    # invisible to that same guard; see its own comment in activate.sh.
    #
    # There is no installed-version stamp: an earlier version of this
    # function wrote one next to the architecture stamp, but nothing in
    # this repository, or in preStart.sh's repair guard, ever read it
    # back. A stamp with no consumer only produced a spurious repair-
    # failure report on a failed write with no compensating benefit, so
    # it was removed rather than given a reader it does not need.
    #
    # See sm_arch_stamp_path's comment: this is what lets preStart.sh
    # catch a cloned-image, wrong-architecture binary that an [ -x ] check
    # alone cannot distinguish from a healthy install.
    if ! sm_write_stamp_or_sentinel "$(sm_arch_stamp_path "$_sm_plugin_dir")" "$_sm_arch"; then
        sm_log_err "could not write architecture stamp for $_sm_target; the newly activated binary is live and verified, but this stamp was not recorded"
        return 1
    fi

    sm_log "installed showmesh-fpp-plugin $_sm_version ($_sm_arch) to $_sm_target"
    return 0
}

# Deliberately does not touch FPP at all. The first version of this
# function called FPP's restart-flag endpoint automatically on every
# install and upgrade, reasoned about only in the failing case ("it's
# fine if this call fails, a manual restart works too"). The case that
# was never examined is the call *succeeding* on a host that is currently
# running a live show: what setting that flag actually does at that
# moment — an immediate restart, a deferred one, or purely advisory — has
# not been confirmed against a running instance, and this project's
# standing rule is no restart and no settings change against a live show
# without that confirmation. An unattended install or upgrade is exactly
# the context where nobody is watching to catch a bad outcome. So this
# function only logs; it is the operator's call, made with eyes open,
# never this script's.
sm_note_possible_restart_need() {
    sm_log "a new or changed command definition may need FPP to restart before it appears in the UI or GET /api/commands. This installer does not do that automatically — what FPP's restart-flag setting does on a host that may be running a live show has not been confirmed, so restart FPP yourself when convenient (never systemctl restart fppd; use FPP's own restart control)."
    return 0
}

# $1 = FPPDIR (already defaulted), $2 = plugin directory, $3 = version
sm_install_or_upgrade() {
    local _sm_fppdir _sm_plugin_dir _sm_version
    _sm_fppdir="$1"
    _sm_plugin_dir="$2"
    _sm_version="$3"

    # Cheap and entirely local: catch a command that FPP would silently
    # drop before doing any network I/O for the binary itself.
    sm_validate_command_scripts "$_sm_plugin_dir" || return 1

    sm_ensure_config_scaffold || return 1
    sm_install_binary "$_sm_plugin_dir" "$_sm_fppdir" "$_sm_version" || return 1
    sm_note_possible_restart_need

    return 0
}
