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
sm_ensure_config_scaffold() {
    local _sm_mkdir _sm_chown _sm_chmod
    local _sm_creddir _sm_credfile _sm_statedir
    local _sm_name_default _sm_fname _sm_default _sm_fpath

    # /usr/sbin/chown is a macOS-only location, listed only so this repo's
    # own tests can run unmodified on a developer Mac; Debian FPP hosts
    # always resolve chown from /bin or /usr/bin, listed first.
    _sm_mkdir=$(sm_resolve_bin mkdir /bin/mkdir /usr/bin/mkdir) || return 1
    _sm_chown=$(sm_resolve_bin chown /bin/chown /usr/bin/chown /usr/sbin/chown) || return 1
    _sm_chmod=$(sm_resolve_bin chmod /bin/chmod /usr/bin/chmod) || return 1

    # Credential directory and file. Deliberately outside FPP's own
    # media/config tree — see sm_credential_dir's comment in common.sh for
    # why — so nothing FPP itself serves over HTTP can reach it.
    _sm_creddir=$(sm_credential_dir)
    "$_sm_mkdir" -p "$_sm_creddir" || {
        sm_log_err "could not create credential directory: $_sm_creddir"
        return 1
    }
    "$_sm_chown" fpp:fpp "$_sm_creddir" || {
        sm_log_err "could not set ownership of $_sm_creddir to fpp:fpp"
        return 1
    }
    "$_sm_chmod" 0700 "$_sm_creddir" || {
        sm_log_err "could not set permissions on $_sm_creddir"
        return 1
    }
    sm_verify_mode "$_sm_creddir" 700 || return 1

    _sm_credfile=$(sm_credential_file)
    if [ ! -e "$_sm_credfile" ]; then
        : > "$_sm_credfile" || {
            sm_log_err "could not create credential file: $_sm_credfile"
            return 1
        }
        sm_log "created empty credential file at $_sm_credfile; it must be provisioned with a scheduler credential before the plugin can act"
    fi
    "$_sm_chown" fpp:fpp "$_sm_credfile" || {
        sm_log_err "could not set ownership of $_sm_credfile to fpp:fpp"
        return 1
    }
    "$_sm_chmod" 0600 "$_sm_credfile" || {
        sm_log_err "could not set permissions on $_sm_credfile"
        return 1
    }
    sm_verify_mode "$_sm_credfile" 600 || return 1

    # Non-secret state directory and files, under FPP's media tree.
    _sm_statedir=$(sm_state_dir)
    "$_sm_mkdir" -p "$_sm_statedir" || {
        sm_log_err "could not create state directory: $_sm_statedir"
        return 1
    }
    "$_sm_chown" fpp:fpp "$_sm_statedir" || {
        sm_log_err "could not set ownership of $_sm_statedir to fpp:fpp"
        return 1
    }
    "$_sm_chmod" 0700 "$_sm_statedir" || {
        sm_log_err "could not set permissions on $_sm_statedir"
        return 1
    }
    sm_verify_mode "$_sm_statedir" 700 || return 1

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
        if [ ! -e "$_sm_fpath" ]; then
            printf '%s\n' "$_sm_default" > "$_sm_fpath" || {
                sm_log_err "could not create $_sm_fpath"
                return 1
            }
        fi
        "$_sm_chown" fpp:fpp "$_sm_fpath" || {
            sm_log_err "could not set ownership of $_sm_fpath to fpp:fpp"
            return 1
        }
        "$_sm_chmod" 0600 "$_sm_fpath" || {
            sm_log_err "could not set permissions on $_sm_fpath"
            return 1
        }
        sm_verify_mode "$_sm_fpath" 600 || return 1
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
# preserved not just until the atomic rename that activates the new one
# succeeds, but until this function's own post-activation checks (mode
# re-verification, the arch-stamp write) also succeed; see the
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
    # preserved at $_sm_target.previous until the two steps below also
    # succeed. Either one failing rolls the live binary back to what was
    # running before this install started, via sm_activate_rollback,
    # instead of reporting the install as failed while actually leaving
    # the new, unverified binary live with no way back, which is what
    # happened before this boundary existed here.

    # Cheap re-confirmation that the rename actually landed a 0755 binary
    # at the target, in the same spirit as every other mode check in this
    # repository trusting a readback over an exit code alone.
    if ! sm_verify_mode "$_sm_target" 755; then
        sm_activate_rollback "$_sm_target"
        return 1
    fi

    # See sm_arch_stamp_path's comment: this is what lets preStart.sh
    # catch a cloned-image, wrong-architecture binary that an [ -x ] check
    # alone cannot distinguish from a healthy install.
    if ! printf '%s\n' "$_sm_arch" > "$(sm_arch_stamp_path "$_sm_plugin_dir")"; then
        sm_log_err "could not write architecture stamp for $_sm_target"
        sm_activate_rollback "$_sm_target"
        return 1
    fi

    # Both post-activation steps succeeded: the transaction is committed,
    # and the previous binary is no longer needed.
    sm_activate_commit "$_sm_target"

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
