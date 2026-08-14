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
    local _sm_fppdir _sm_candidate
    _sm_fppdir="$1"
    for _sm_candidate in $(sm_fpp_binary_candidates "$_sm_fppdir"); do
        if [ -f "$_sm_candidate" ]; then
            printf '%s\n' "$_sm_candidate"
            return 0
        fi
    done
    sm_log_err "no FPP binary found to probe for its ELF class (checked: $(sm_fpp_binary_candidates "$_sm_fppdir" | tr '\n' ' '))"
    return 1
}

# Prints the ELF magic bytes of a file as lowercase hex, e.g. "7f454c46".
sm_elf_magic() {
    local _sm_dd _sm_od
    _sm_dd=$(sm_resolve_bin dd /bin/dd /usr/bin/dd) || return 1
    _sm_od=$(sm_resolve_bin od /usr/bin/od /bin/od) || return 1
    "$_sm_dd" if="$1" bs=1 count=4 2>/dev/null | "$_sm_od" -An -tx1 | tr -d ' \n'
}

sm_elf_magic_ok() {
    [ "$(sm_elf_magic "$1")" = "7f454c46" ]
}

# Prints 32 or 64, read from byte offset 4 (the EI_CLASS field: 1 = ELFCLASS32,
# 2 = ELFCLASS64) of the given ELF file.
sm_elf_class() {
    local _sm_dd _sm_od _sm_byte
    _sm_dd=$(sm_resolve_bin dd /bin/dd /usr/bin/dd) || return 1
    _sm_od=$(sm_resolve_bin od /usr/bin/od /bin/od) || return 1
    _sm_byte=$("$_sm_dd" if="$1" bs=1 skip=4 count=1 2>/dev/null | "$_sm_od" -An -tu1 | tr -d ' \n')
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
sm_detect_arch() {
    local _sm_fppdir _sm_machine _sm_fpp_bin _sm_class _sm_linker_says
    _sm_fppdir="$1"
    _sm_machine=$(sm_uname_m) || return 1

    case "$_sm_machine" in
        x86_64)
            # No known FPP host runs 32-bit x86; the kernel/userspace
            # word-size split that motivates the ARM disambiguation below
            # does not apply here.
            printf 'amd64\n'
            return 0
            ;;
        aarch64|armv6l|armv7l|arm*)
            ;;
        *)
            sm_log_err "unrecognized kernel machine type from uname -m: $_sm_machine"
            return 1
            ;;
    esac

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
