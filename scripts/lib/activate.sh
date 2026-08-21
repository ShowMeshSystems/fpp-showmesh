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
# The activation swap itself is exactly ONE rename: staging onto target.
# An earlier version of this file preserved the previous binary by
# renaming it aside to target.previous first, then renaming staging onto
# target second: two renames, with a real window between them where
# rename(2) has already vacated the target name but not yet reoccupied
# it, so a crash in that window leaves no binary at all. A hard link
# costs nothing to create (it does not move or copy the underlying file,
# it just adds a second name for the same inode) and, unlike a rename,
# creating it never removes the original name, so the previous binary
# stays live under $target for the entire time its backup name is being
# created. That is what turns the swap back into a genuine single
# atomic rename: the target name is never briefly unoccupied.
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
# $2, preserving whatever was previously at $2 as $2.previous until the
# swap is known to have succeeded.
#
# Sequence: if a previous binary exists at the target, give it a second
# name at $2.previous with `ln` (a hard link, not a rename; see the file
# header for why that is what closes the crash window a rename-based
# backup left open); fall back to a plain `cp -p` only if the link itself
# fails (e.g. a filesystem that does not support hard links; same-
# directory same-filesystem should never cross filesystems, but this
# stays defensive rather than assuming that). Then rename the staged
# binary onto the target: the one step that actually makes the new binary
# live, and, because it is a single rename, either fully done or entirely
# undone after a crash: there is no partial state for a crash to land in
# between. If that rename fails, the target was never touched by it (a
# failed rename(2) leaves both names exactly as they were), so there is
# nothing to roll back: the previous binary is still live under $2 the
# whole time, and only the now-unneeded backup and staging files are
# cleaned up. If there was no previous binary (a fresh install) and
# activation fails, nothing is left half-installed either: the staging
# file is removed and the target was never created.
sm_activate_binary() {
    local _sm_staging _sm_target _sm_backup _sm_rm _sm_ln _sm_cp _sm_had_previous
    _sm_staging="$1"
    _sm_target="$2"
    _sm_backup="$_sm_target.previous"
    _sm_rm=$(sm_resolve_bin rm /bin/rm /usr/bin/rm) || return 1
    _sm_had_previous=0

    if [ -e "$_sm_target" ]; then
        "$_sm_rm" -f "$_sm_backup"

        _sm_ln=$(sm_resolve_bin ln /bin/ln /usr/bin/ln) || {
            "$_sm_rm" -f "$_sm_staging"
            return 1
        }
        if ! "$_sm_ln" "$_sm_target" "$_sm_backup"; then
            _sm_cp=$(sm_resolve_bin cp /bin/cp /usr/bin/cp) || {
                "$_sm_rm" -f "$_sm_staging"
                return 1
            }
            if ! "$_sm_cp" -p "$_sm_target" "$_sm_backup"; then
                sm_log_err "could not preserve previous binary at $_sm_target before activating the new one (hard link and copy fallback both failed); refusing to proceed"
                "$_sm_rm" -f "$_sm_staging"
                return 1
            fi
        fi
        _sm_had_previous=1
    fi

    if ! sm_atomic_rename "$_sm_staging" "$_sm_target"; then
        sm_log_err "activation failed: could not rename staged binary $_sm_staging onto $_sm_target; a failed rename leaves $_sm_target as it was, so the previous binary there is unaffected and no rollback is needed"
        if [ "$_sm_had_previous" -eq 1 ]; then
            "$_sm_rm" -f "$_sm_backup"
        fi
        "$_sm_rm" -f "$_sm_staging"
        return 1
    fi

    # The backup is deliberately NOT removed here on success. The swap
    # above is only one step of the caller's activation transaction; see
    # sm_activate_commit and sm_activate_rollback below, and
    # sm_install_binary in install-core.sh, which owns deciding when the
    # transaction is actually finished.
    return 0
}

# Finalizes a successful activation by discarding the preserved previous
# binary at $1.previous. Callers must not call this until every failable
# step in their activation transaction has succeeded (see
# sm_install_binary in install-core.sh); the whole point of keeping the
# previous binary around after a successful swap is so a failure later in
# the same install (a failed mode re-verification, a failed arch-stamp
# write) can still be rolled back to it.
sm_activate_commit() {
    local _sm_target _sm_rm
    _sm_target="$1"
    _sm_rm=$(sm_resolve_bin rm /bin/rm /usr/bin/rm) || return 1
    "$_sm_rm" -f "$_sm_target.previous"
}

# Writes a stamp file at $1 with content $2 by writing to a temp path and
# renaming it into place, so a write that fails partway (a full disk, a
# write-limited filesystem) leaves an existing stamp at $1 untouched
# instead of truncated.
#
# Both $1 and its temp path $1.tmp are refused if either is a symlink,
# not just written through. A stamp file lives in the plugin directory,
# which carries the same writability as everything else this project
# activates there; a `.installed-arch.tmp` planted as a symlink to a
# root-owned file elsewhere would otherwise have the `printf` below
# truncate and rewrite whatever it points at, running as root, and the
# in-place write this function replaced had the identical hole at the
# stamp path itself. A leftover DIRECTORY at the temp path, unlike a
# symlink, is not an attack and is cleared rather than refused: an old
# build of this function (or an interrupted run) could leave one behind,
# and `rm -f` alone cannot remove it, which otherwise breaks every later
# write to the same stamp with no way to recover.
#
# A symlink check alone at the temp path is not enough: a HARD link
# planted there (a second name for an existing file's inode, `ln` with no
# `-s`) passes both the `-L` check above and `-d` below, since it looks
# exactly like an ordinary regular file. The `printf` that used to write
# straight into $_sm_tmp would then truncate and overwrite whatever that
# other name's content was, in place, before the rename ever ran.
# Verified: hard-linking a victim file to the temp path and writing a
# stamp replaced the victim's content, at exit 0. `rm -f "$_sm_tmp"`
# first removes only that ONE name (unlinking never touches the data
# other names still point at, the same reasoning that makes the final
# rename below safe against a hard link at the DESTINATION), guaranteeing
# the write that follows always lands in a brand-new inode. The write
# itself uses the shell's noclobber option so the existence check
# (nothing is left at $_sm_tmp after the `rm -f` above) and the create
# happen as one kernel-level operation: anything raced into that name in
# the gap between the `rm -f` and this write, symlink or hard link, is
# refused rather than written through.
sm_write_stamp() {
    local _sm_path _sm_content _sm_tmp _sm_rm
    _sm_path="$1"
    _sm_content="$2"
    _sm_tmp="$_sm_path.tmp"
    _sm_rm=$(sm_resolve_bin rm /bin/rm /usr/bin/rm) || return 1

    if [ -L "$_sm_path" ]; then
        sm_log_err "cannot write stamp file $_sm_path: a symlink already exists at that path; refusing to write through it"
        return 1
    fi
    # `mv -f` onto a destination that exists as a DIRECTORY does not fail:
    # it moves the source inside that directory instead, which would leave
    # $_sm_path itself untouched (still a directory) while silently
    # reporting success. Caught explicitly here rather than trusted to
    # sm_atomic_rename's exit code.
    if [ -d "$_sm_path" ]; then
        sm_log_err "cannot write stamp file $_sm_path: a directory already exists at that path"
        return 1
    fi

    if [ -L "$_sm_tmp" ]; then
        sm_log_err "cannot write stamp file $_sm_path: a symlink exists at temp path $_sm_tmp; refusing to write through it"
        return 1
    fi
    if [ -d "$_sm_tmp" ]; then
        if ! "$_sm_rm" -rf "$_sm_tmp"; then
            sm_log_err "cannot write stamp file $_sm_path: a leftover directory at temp path $_sm_tmp could not be removed"
            return 1
        fi
    fi

    "$_sm_rm" -f "$_sm_tmp"
    if ! ( set -C; printf '%s\n' "$_sm_content" > "$_sm_tmp" ) 2>/dev/null; then
        sm_log_err "could not write stamp file $_sm_tmp"
        "$_sm_rm" -f "$_sm_tmp"
        return 1
    fi
    if ! sm_atomic_rename "$_sm_tmp" "$_sm_path"; then
        sm_log_err "could not activate stamp file $_sm_path"
        "$_sm_rm" -f "$_sm_tmp"
        return 1
    fi
    return 0
}

# Writes stamp $1 via sm_write_stamp; on failure, makes a best-effort
# attempt to leave an EMPTY file at $1 rather than nothing at all, but
# only when nothing already occupies that path (no file, no symlink).
#
# sm_arch_repair_reason (lib/arch.sh) already treats an EXISTING but empty
# stamp as needing repair, and treats a MISSING stamp as health (read as
# "installed by a version of this repository before the stamp existed").
# That second reading is right for an upgrade from an old install, but
# wrong for a stamp write that fails on this run: on a first install,
# nothing was ever there to have predated the stamp, so a failed write
# left the exact same on-disk state as a healthy pre-stamp install would
# have: permanently invisible to the repair guard, even after this host
# is later cloned onto different-architecture hardware. Verified: with no
# stamp on disk and detection disagreeing with the binary, the repair
# reason came back empty and preStart exited 0.
#
# Leaving the sentinel only when nothing already exists preserves
# sm_write_stamp's own guarantee for the other case: a transient failure
# writing OVER an already-recorded, good stamp must leave that stamp
# exactly as it was, not blank it out.
sm_write_stamp_or_sentinel() {
    local _sm_path _sm_content
    _sm_path="$1"
    _sm_content="$2"
    if sm_write_stamp "$_sm_path" "$_sm_content"; then
        return 0
    fi
    if [ ! -e "$_sm_path" ] && [ ! -L "$_sm_path" ]; then
        ( set -C; : > "$_sm_path" ) 2>/dev/null
    fi
    return 1
}

# Undoes a successful sm_activate_binary swap after a LATER failure in the
# same install transaction (see sm_install_binary's transaction-boundary
# comment in install-core.sh). Rolls back to the preserved previous binary
# when one exists. When this was a fresh install with nothing to roll back
# to, an earlier version of this repair called sm_activate_rollback anyway,
# which refused with "no preserved previous binary" and left the caller
# reporting failure while the new, unverified binary stayed live and
# executable at the target with no stamp describing it, a status-1 report
# that did not match what was actually on disk. This removes the target
# instead in that case, so a failed fresh install actually leaves nothing
# installed, matching what it reports.
sm_activate_undo() {
    local _sm_target _sm_rm
    _sm_target="$1"

    if [ -e "$_sm_target.previous" ]; then
        sm_activate_rollback "$_sm_target"
        return $?
    fi

    _sm_rm=$(sm_resolve_bin rm /bin/rm /usr/bin/rm) || return 1
    if "$_sm_rm" -f "$_sm_target"; then
        sm_log_err "no previous binary to roll back to for $_sm_target; removed the unverified fresh install instead of leaving it live"
        return 0
    fi
    sm_log_err "no previous binary to roll back to for $_sm_target, and could not remove the unverified fresh install either; $_sm_target may be live and unverified"
    return 1
}

sm_activate_rollback() {
    local _sm_target _sm_backup
    _sm_target="$1"
    _sm_backup="$_sm_target.previous"

    if [ ! -e "$_sm_backup" ]; then
        sm_log_err "cannot roll back $_sm_target: no preserved previous binary at $_sm_backup"
        return 1
    fi
    if sm_atomic_rename "$_sm_backup" "$_sm_target"; then
        sm_log_err "rolled back $_sm_target to its previous binary after a post-activation failure"
        return 0
    fi
    sm_log_err "rollback of $_sm_target from $_sm_backup also failed; $_sm_target may now be missing or wrong"
    return 1
}

