#!/bin/sh
# Stage-then-swap activation of the installed binary, with rollback.
#
# The naive sequence, `mv` the newly extracted binary straight onto the
# live target, then chmod/chown/verify it in place, has two failure
# modes. First, any failure after that first `mv` (a chmod that fails, a
# mode readback that comes back wrong on a vfat/exFAT mount, a chown that
# fails) has already destroyed the previous, working binary before
# confirming the new one is good. Second, a kill or power loss between the
# `mv` and the chmod/chown leaves an unverified binary live with no way to
# tell it apart from a healthy install.
#
# The fix is standard stage-then-swap: fully validate the new binary at a
# staging path in the *same directory* as the final target, and only then
# activate it with a single rename. A rename within one directory is a
# single filesystem-level metadata operation: atomic, and either fully
# done or not done at all after a crash, unlike a `mv` from a /tmp working
# directory onto the plugin directory is not guaranteed to be if the two
# happen to sit on different filesystems (an ordinary `mv` across
# filesystems is implemented as a copy-then-unlink, not a rename, and is
# not atomic). Staging in the target's own directory is what makes the
# final activation step actually atomic rather than merely renamed-shaped.
#
# Requires scripts/lib/common.sh to already be sourced.

# Thin wrapper around `mv -f`, factored out to one call site so tests can
# shadow this single function (the same shadowing technique arch.sh's
# tests use on sm_uname_m) to inject a failure at a specific point in the
# stage/activate sequence without needing a real broken filesystem.
sm_atomic_rename() {
    local _sm_mv
    _sm_mv=$(sm_resolve_bin mv /bin/mv /usr/bin/mv) || return 1
    "$_sm_mv" -f "$1" "$2"
}

# Moves the freshly extracted binary at $1 into staging path $2 (which
# must be in the same directory as the eventual final target, see the
# file header) and fully validates it there: mode set and read back, then
# ownership. The live target is never touched by this function. On any
# failure, the staging file is removed and nothing has changed on disk
# outside the temporary extraction area the caller already owns.
#
# The chown target is overridable via SM_INSTALL_OWNER (same pattern as
# SM_AARCH64_LINKER_CANDIDATES in arch.sh) so this repository's own tests
# can exercise a real, successful chown without an "fpp" system user
# existing on the developer machine running them; production code never
# sets it and gets the real fpp:fpp target below.
sm_stage_binary() {
    local _sm_source _sm_staging _sm_rm _sm_chmod _sm_chown
    _sm_source="$1"
    _sm_staging="$2"
    _sm_rm=$(sm_resolve_bin rm /bin/rm /usr/bin/rm) || return 1

    if ! sm_atomic_rename "$_sm_source" "$_sm_staging"; then
        sm_log_err "could not stage new binary at $_sm_staging"
        return 1
    fi

    _sm_chmod=$(sm_resolve_bin chmod /bin/chmod /usr/bin/chmod) || {
        "$_sm_rm" -f "$_sm_staging"
        return 1
    }
    if ! "$_sm_chmod" 0755 "$_sm_staging"; then
        sm_log_err "could not set permissions on staged binary $_sm_staging"
        "$_sm_rm" -f "$_sm_staging"
        return 1
    fi
    if ! sm_verify_mode "$_sm_staging" 755; then
        sm_log_err "staged binary $_sm_staging failed mode verification; discarding it before activation"
        "$_sm_rm" -f "$_sm_staging"
        return 1
    fi

    _sm_chown=$(sm_resolve_bin chown /bin/chown /usr/bin/chown /usr/sbin/chown) || {
        "$_sm_rm" -f "$_sm_staging"
        return 1
    }
    if ! "$_sm_chown" "${SM_INSTALL_OWNER:-fpp:fpp}" "$_sm_staging"; then
        sm_log_err "could not set ownership of staged binary $_sm_staging to fpp:fpp"
        "$_sm_rm" -f "$_sm_staging"
        return 1
    fi

    return 0
}

# Activates a fully staged and validated binary at $1 onto final target
# $2, preserving whatever was previously at $2 until the swap is known to
# have succeeded, and rolling that previous binary back into place if it
# does not.
#
# Sequence: if a previous binary exists at the target, rename it aside to
# $2.previous (still an atomic, same-directory rename); then rename the
# staged binary onto the target, the one step that actually makes the
# new binary live. If that second rename fails and a previous binary was
# set aside, it is renamed back. If there was no previous binary (a fresh
# install) and activation fails, nothing is left half-installed: the
# staging file is removed and the target was never created.
sm_activate_binary() {
    local _sm_staging _sm_target _sm_backup _sm_rm _sm_had_previous
    _sm_staging="$1"
    _sm_target="$2"
    _sm_backup="$_sm_target.previous"
    _sm_rm=$(sm_resolve_bin rm /bin/rm /usr/bin/rm) || return 1
    _sm_had_previous=0

    if [ -e "$_sm_target" ]; then
        "$_sm_rm" -f "$_sm_backup"
        if ! sm_atomic_rename "$_sm_target" "$_sm_backup"; then
            sm_log_err "could not preserve previous binary at $_sm_target before activating the new one; refusing to proceed"
            "$_sm_rm" -f "$_sm_staging"
            return 1
        fi
        _sm_had_previous=1
    fi

    if ! sm_atomic_rename "$_sm_staging" "$_sm_target"; then
        sm_log_err "activation failed: could not rename staged binary $_sm_staging onto $_sm_target"
        if [ "$_sm_had_previous" -eq 1 ]; then
            if sm_atomic_rename "$_sm_backup" "$_sm_target"; then
                sm_log_err "rolled back to the previous binary at $_sm_target after activation failed"
            else
                sm_log_err "activation failed AND rollback of the previous binary from $_sm_backup to $_sm_target also failed; $_sm_target may now be missing or wrong"
            fi
        fi
        "$_sm_rm" -f "$_sm_staging"
        return 1
    fi

    if [ "$_sm_had_previous" -eq 1 ]; then
        "$_sm_rm" -f "$_sm_backup"
    fi

    return 0
}
