#!/bin/sh
# Architecture detection for artifact selection.
#
# NEVER use `uname -m` alone. A Raspberry Pi 4 or 5 boots a 64-bit kernel
# even when FPP itself is running a 32-bit (armhf) userspace, so `uname -m`
# reports "aarch64" for what is really a 32-bit install. `/etc/fpp/arch`
# would settle this cleanly but only exists on FPP 10, and the deployed
# regime this repo also has to support is FPP 9.x and earlier.
#
# Two independent signals resolve the ambiguity, following the pattern two
# unrelated FPP plugins converged on separately:
#   1. the ELF class byte of an actual FPP binary (32-bit vs 64-bit ELF), and
#   2. whether the aarch64 dynamic linker is present on this host at all.
# They must agree. Disagreement is reported and refused rather than guessed
# through, naming both readings, because a silent wrong guess ships an
# artifact that will not exec.
#
# Requires scripts/lib/common.sh to already be sourced (for sm_resolve_bin,
# sm_log, sm_log_err).

# Absolute candidate locations for an FPP binary to read the ELF class of.
# None of these paths has been confirmed against a running FPP host; see
# README.md's "what has not been verified" section.
sm_fpp_binary_candidates() {
    local _sm_fppdir
    _sm_fppdir="$1"
    printf '%s\n' \
        "$_sm_fppdir/src/fppd" \
        "$_sm_fppdir/bin/fppd" \
        "/opt/fpp/src/fppd" \
        "/usr/bin/fppd"
}

sm_find_fpp_binary() {
    local _sm_fppdir _sm_candidate _sm_tr
    _sm_fppdir="$1"
    _sm_tr=$(sm_resolve_bin tr /usr/bin/tr /bin/tr) || return 1
    for _sm_candidate in $(sm_fpp_binary_candidates "$_sm_fppdir"); do
        if [ -f "$_sm_candidate" ]; then
            printf '%s\n' "$_sm_candidate"
            return 0
        fi
    done
    sm_log_err "no FPP binary found to probe for its ELF class (checked: $(sm_fpp_binary_candidates "$_sm_fppdir" | "$_sm_tr" '\n' ' '))"
    return 1
}

# Prints the ELF magic bytes of a file as lowercase hex, e.g. "7f454c46".
sm_elf_magic() {
    local _sm_dd _sm_od _sm_tr
    _sm_dd=$(sm_resolve_bin dd /bin/dd /usr/bin/dd) || return 1
    _sm_od=$(sm_resolve_bin od /usr/bin/od /bin/od) || return 1
    _sm_tr=$(sm_resolve_bin tr /usr/bin/tr /bin/tr) || return 1
    "$_sm_dd" if="$1" bs=1 count=4 2>/dev/null | "$_sm_od" -An -tx1 | "$_sm_tr" -d ' \n'
}

sm_elf_magic_ok() {
    [ "$(sm_elf_magic "$1")" = "7f454c46" ]
}

# Prints 32 or 64, read from byte offset 4 (the EI_CLASS field: 1 = ELFCLASS32,
# 2 = ELFCLASS64) of the given ELF file.
sm_elf_class() {
    local _sm_dd _sm_od _sm_tr _sm_byte
    _sm_dd=$(sm_resolve_bin dd /bin/dd /usr/bin/dd) || return 1
    _sm_od=$(sm_resolve_bin od /usr/bin/od /bin/od) || return 1
    _sm_tr=$(sm_resolve_bin tr /usr/bin/tr /bin/tr) || return 1
    _sm_byte=$("$_sm_dd" if="$1" bs=1 skip=4 count=1 2>/dev/null | "$_sm_od" -An -tu1 | "$_sm_tr" -d ' \n')
    case "$_sm_byte" in
        1) printf '32\n' ;;
        2) printf '64\n' ;;
        *) sm_log_err "unrecognized ELF class byte in $1: '$_sm_byte'"; return 1 ;;
    esac
}

# True if a 64-bit ARM dynamic linker exists anywhere this host would keep
# one. Absence on an otherwise-ARM host means the userspace is 32-bit even
# if the kernel is 64-bit.
#
# The candidate list is overridable via SM_AARCH64_LINKER_CANDIDATES (a
# space-separated list) so the disagreement and agreement paths can be
# exercised by tests against fixture files instead of real system paths;
# production code never sets it and gets the real list below.
sm_aarch64_linker_present() {
    local _sm_path
    for _sm_path in ${SM_AARCH64_LINKER_CANDIDATES:-/lib/ld-linux-aarch64.so.1 /lib64/ld-linux-aarch64.so.1 /usr/lib/ld-linux-aarch64.so.1}
    do
        if [ -e "$_sm_path" ]; then
            return 0
        fi
    done
    return 1
}

# Prints the kernel-reported machine type. Split out from sm_detect_arch
# so tests can shadow this one function to exercise every branch below
# without needing to run on each real architecture.
sm_uname_m() {
    local _sm_uname
    _sm_uname=$(sm_resolve_bin uname /bin/uname /usr/bin/uname) || return 1
    "$_sm_uname" -m
}

# Prints one of: amd64, arm64, armv7. Non-zero exit and a stderr message on
# anything it cannot resolve confidently, including the two detection
# methods disagreeing.
#
# The two-signal ELF-class / dynamic-linker probe below exists to answer
# exactly one question: does a 64-bit kernel (uname -m reporting aarch64)
# hide a 32-bit (armhf) userspace? It is run only for that case. A literal
# 32-bit report from the kernel needs no disambiguation at all — a 32-bit
# kernel cannot run a 64-bit userspace, so armv7l is unambiguous on its
# own. And the probe cannot answer a different question it looks similar
# to: which ARM instruction set version is present. EI_CLASS is a 32- vs
# 64-bit bit-width flag; it says nothing about ARMv6 vs ARMv7, and this
# project ships one 32-bit ARM artifact, built with GOARM=7. A first pass
# of this file grouped armv6l into the same "needs disambiguation" branch
# as aarch64 and armv7l, which meant a genuine ARMv6 host (a Pi 1 or Pi
# Zero, uname -m reporting armv6l directly) would resolve through this
# probe, find a 32-bit ELF class and no aarch64 linker, call that
# "agreement", and answer armv7 — the one answer that is certainly wrong
# for that hardware, from the one module whose entire premise is refusing
# to guess. GOARM=7 code executes an illegal instruction on real ARMv6
# silicon. armv6l is now refused outright, explicitly, before any probing.
sm_detect_arch() {
    local _sm_fppdir _sm_machine _sm_fpp_bin _sm_class _sm_linker_says
    _sm_fppdir="$1"
    _sm_machine=$(sm_uname_m) || return 1

    case "$_sm_machine" in
        x86_64)
            # Not "no known FPP host runs 32-bit x86" — that would be a
            # claim about the world, stated as fact with no citation, in
            # the one file whose subject is refusing to trust unverified
            # signals. This is a scope decision instead: the artifact
            # contract this repository fetches from ships amd64, arm64,
            # and armv7 only, so a 32-bit x86 host is out of scope
            # regardless of whether one exists anywhere, and amd64 is
            # answered from the kernel report alone because x86 has no
            # analogue of the aarch64-hides-armhf trap this file exists
            # to defend against.
            printf 'amd64\n'
            return 0
            ;;
        armv7l)
            # Unambiguous on its own; see the note above the function.
            printf 'armv7\n'
            return 0
            ;;
        armv6l)
            sm_log_err "kernel reports armv6l (ARMv6 hardware, e.g. Pi 1 or Pi Zero); this project ships no armv6 artifact, and the ELF-class/linker-presence method cannot tell ARMv6 from ARMv7 in the first place — both are 32-bit ELF with no aarch64 linker. Refusing rather than shipping a GOARM=7 build that would fault with an illegal instruction on real ARMv6 silicon."
            return 1
            ;;
        aarch64)
            ;;
        *)
            sm_log_err "unrecognized or unsupported kernel machine type from uname -m: $_sm_machine"
            return 1
            ;;
    esac

    # Only aarch64 reaches here: the one case where the kernel's own word
    # size does not by itself tell us the FPP userspace's word size.
    _sm_fpp_bin=$(sm_find_fpp_binary "$_sm_fppdir") || return 1

    if ! sm_elf_magic_ok "$_sm_fpp_bin"; then
        sm_log_err "$_sm_fpp_bin does not start with the ELF magic bytes; cannot read its class"
        return 1
    fi

    _sm_class=$(sm_elf_class "$_sm_fpp_bin") || return 1

    if sm_aarch64_linker_present; then
        _sm_linker_says=64
    else
        _sm_linker_says=32
    fi

    if [ "$_sm_class" != "$_sm_linker_says" ]; then
        sm_log_err "architecture detection disagreement on $_sm_machine: ELF class of $_sm_fpp_bin reads ${_sm_class}-bit, presence of the aarch64 dynamic linker implies ${_sm_linker_says}-bit userspace. Refusing to guess an artifact; resolve manually."
        return 1
    fi

    if [ "$_sm_class" = "64" ]; then
        printf 'arm64\n'
    else
        printf 'armv7\n'
    fi
}

# Extracted out of preStart.sh rather than left inline there, specifically
# so it can be unit tested: a script run as a fresh subprocess cannot have
# sm_uname_m shadowed by a test the way every other arch.sh function in
# this suite is exercised, since POSIX sh has no portable way to export a
# function into a child process. As a plain sourced function, this one can.
#
# Prints a non-empty reason on stdout if this host's freshly detected
# architecture disagrees with the architecture stamped at the plugin's
# last successful install ($1/.installed-arch, written by
# sm_install_binary), and prints nothing otherwise. "Otherwise" covers
# three different cases deliberately treated the same way: the stamp and
# a fresh detection agree; there is no stamp at all (most likely a binary
# installed by a version of this repository before the stamp existed,
# which resolves itself on the next real install or upgrade); and fresh
# detection itself fails right now, which is not evidence the installed
# binary is wrong — it is evidence detection cannot currently answer,
# and guessing wrong there would trigger the exact kind of unnecessary,
# network-bound repair this function exists to gate precisely.
sm_arch_repair_reason() {
    local _sm_plugin_dir _sm_fppdir _sm_stamp _sm_stamped_arch _sm_current_arch
    _sm_plugin_dir="$1"
    _sm_fppdir="$2"

    _sm_stamp=$(sm_arch_stamp_path "$_sm_plugin_dir")
    if [ ! -f "$_sm_stamp" ]; then
        # No stamp at all: most likely a binary installed by a version of
        # this repository before the stamp existed. Nothing to compare
        # against, so this is not evidence of a mismatch.
        return 0
    fi

    _sm_stamped_arch=$(sm_read_stamp "$_sm_stamp")
    if [ -z "$_sm_stamped_arch" ]; then
        # The stamp file EXISTS but is empty, unlike the no-file case
        # above: exactly what a crash during a non-atomic stamp write used
        # to leave behind, or a filesystem that quietly truncated one. An
        # existing binary next to an unreadable stamp is treated as
        # needing repair rather than as health, so this guard cannot be
        # blinded by the same failure it exists to catch.
        printf 'architecture stamp at %s exists but is empty; cannot confirm the installed binary'"'"'s architecture\n' "$_sm_stamp"
        return 0
    fi

    _sm_current_arch=$(sm_detect_arch "$_sm_fppdir" 2>/dev/null) || return 0

    if [ "$_sm_current_arch" != "$_sm_stamped_arch" ]; then
        printf 'installed binary was built for %s, but this host now detects as %s — this is exactly what a disk image cloned from a different-architecture host produces\n' "$_sm_stamped_arch" "$_sm_current_arch"
    fi
    return 0
}
