#!/bin/sh
# Exercises the things in this repo worth failing loudly over: the
# architecture probe, checksum and artifacts.lock.json verification,
# stage-then-swap binary activation and rollback, the full
# sm_install_binary / sm_install_or_upgrade pipeline (fetch and
# architecture detection shadowed, so nothing here touches the network),
# command-script validation, and a handful of smaller path/mode/URL
# helpers. Every scenario here is something that would otherwise be
# discovered on a real Pi, the hard way. See README.md's "What has been
# exercised" section for the itemized list and what is deliberately left
# out (hardware-only evidence).
#
# Requires python3 to synthesize small ELF and tarball fixtures; that is a
# dev/CI-machine requirement only, and is never a runtime dependency of the
# scripts under test, which stay plain POSIX sh with no Python involved.
#
# Run with: sh test/run_tests.sh  (or bash, or dash — POSIX only, no bashisms)

set -u

_sm_test_dir=$(cd "$(dirname "$0")" && pwd)
_sm_repo_dir=$(cd "$_sm_test_dir/.." && pwd)
_sm_lib_dir="$_sm_repo_dir/scripts/lib"

_sm_pass=0
_sm_fail=0

_sm_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fpp-showmesh-tests.XXXXXX")
# Resolved to its physical path (no symlink components) rather than left
# as mktemp -d returned it: on macOS, $TMPDIR itself sits under /var,
# which is a stock OS symlink to /private/var, and sm_mkdir_p_refuse_
# symlinks (added to close a real defect: a path COMPONENT planted as a
# symlink under a scaffold directory) has no way to tell a pre-existing,
# benign system symlink like that apart from an attacker-planted one at
# test time. Every fixture built from $_sm_tmp below is therefore free of
# symlinks the test environment itself introduced, so the checks that
# follow only ever see symlinks this suite plants on purpose.
trap 'rm -rf "$_sm_tmp"' EXIT
_sm_tmp=$(cd "$_sm_tmp" && pwd -P)

pass() {
    _sm_pass=$((_sm_pass + 1))
    printf 'ok   - %s\n' "$1"
}

fail() {
    _sm_fail=$((_sm_fail + 1))
    printf 'FAIL - %s\n' "$1"
    if [ -n "${2:-}" ]; then
        printf '       %s\n' "$2"
    fi
}

# For a case this suite genuinely cannot exercise in its current
# environment (root ignores chmod 000, so an "unreadable file" case has no
# way to be unreadable) rather than a defect. Counts toward neither pass
# nor fail, unlike fail(), which would report a failure this suite did not
# actually observe and an FPP host, which runs as root, would trigger
# on every run.
skip() {
    printf 'skip - %s (%s)\n' "$1" "$2"
}

assert_eq() {
    # $1 = description, $2 = expected, $3 = actual
    if [ "$2" = "$3" ]; then
        pass "$1"
    else
        fail "$1" "expected [$2], got [$3]"
    fi
}

assert_success() {
    # $1 = description, $2 = exit status
    if [ "$2" -eq 0 ]; then
        pass "$1"
    else
        fail "$1" "expected exit 0, got $2"
    fi
}

assert_failure() {
    # $1 = description, $2 = exit status
    if [ "$2" -ne 0 ]; then
        pass "$1"
    else
        fail "$1" "expected non-zero exit, got 0"
    fi
}

assert_contains() {
    # $1 = description, $2 = haystack, $3 = needle
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1" "expected output to contain [$3], got:
$2" ;;
    esac
}

# python3 synthesizes fixture ELF/tarball bytes and every synthetic sha256
# used throughout this suite; without it, every one of those bare
# `python3 -c ...` calls below fails but is captured by a `$(...)`
# command substitution, so the suite kept running with empty fixtures and
# empty hashes and reported a plain pass/fail count instead of the
# environment problem that actually caused it. Refusing outright here,
# before any fixture is built, turns that into a loud, specific failure
# instead of a quietly degraded run.
if ! command -v python3 >/dev/null 2>&1; then
    printf 'FATAL: python3 is required to build this suite'"'"'s fixtures and was not found on PATH\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Fixture generation
# ---------------------------------------------------------------------------

make_elf() {
    # $1 = output path, $2 = ELF class (1 = 32-bit, 2 = 64-bit)
    python3 -c "
import sys
path, cls = sys.argv[1], int(sys.argv[2])
with open(path, 'wb') as f:
    f.write(bytes([0x7f, 0x45, 0x4c, 0x46, cls]) + bytes(59))
" "$1" "$2"
}

make_bad_magic() {
    python3 -c "
import sys
with open(sys.argv[1], 'wb') as f:
    f.write(b'not an elf file, deliberately')
" "$1"
}

# ---------------------------------------------------------------------------
# Architecture probe
# ---------------------------------------------------------------------------

# shellcheck disable=SC1090
. "$_sm_lib_dir/common.sh"
# shellcheck disable=SC1090
. "$_sm_lib_dir/arch.sh"

echo "== architecture probe =="

# amd64 short-circuits on the kernel machine type alone; no ELF probing.
sm_uname_m() { echo x86_64; }
out=$(sm_detect_arch "$_sm_tmp/nonexistent-fppdir" 2>"$_sm_tmp/amd64.err")
assert_eq "amd64 short-circuits without touching the filesystem" "amd64" "$out"

# arm64: kernel reports aarch64, FPP binary is a 64-bit ELF, and the aarch64
# dynamic linker fixture exists. Both signals agree on 64-bit.
sm_uname_m() { echo aarch64; }
mkdir -p "$_sm_tmp/arm64-agree/src"
make_elf "$_sm_tmp/arm64-agree/src/fppd" 2
: > "$_sm_tmp/arm64-agree/ld-linux-aarch64.so.1"
SM_AARCH64_LINKER_CANDIDATES="$_sm_tmp/arm64-agree/ld-linux-aarch64.so.1"
export SM_AARCH64_LINKER_CANDIDATES
out=$(sm_detect_arch "$_sm_tmp/arm64-agree" 2>"$_sm_tmp/arm64.err")
assert_eq "arm64 when ELF class and linker probe agree on 64-bit" "arm64" "$out"

# armv7l is answered directly from the kernel report alone, with NO ELF or
# linker probing at all: a 32-bit kernel cannot be hiding a 64-bit
# userspace, so there is no ambiguity to resolve. Prove it by pointing at
# an fppdir with no FPP binary in it whatsoever — if the code were still
# routing armv7l through the disambiguation path, this would fail with
# "no FPP binary found" instead of answering armv7.
sm_uname_m() { echo armv7l; }
out=$(sm_detect_arch "$_sm_tmp/armv7-no-binary-needed" 2>"$_sm_tmp/armv7.err")
assert_eq "armv7l answers armv7 directly, without needing an FPP binary to probe" "armv7" "$out"

# armv6l must be refused outright, never answered armv7. This is the bug
# the coordinator found: EI_CLASS (the ELF class byte) cannot distinguish
# ARMv6 from ARMv7 — both are 32-bit ELF with no aarch64 linker — so
# routing armv6l through the same disambiguation path as aarch64 would
# find "agreement" at 32-bit and answer armv7, which is wrong for real
# ARMv6 silicon and is exactly the kind of guess this module exists to
# refuse. No FPP binary is provided here either, proving the refusal
# happens before any probing, not as a side effect of a missing binary.
sm_uname_m() { echo armv6l; }
out=$(sm_detect_arch "$_sm_tmp/armv6-refused" 2>"$_sm_tmp/armv6.err")
status=$?
assert_failure "armv6l is refused, never answered armv7" "$status"
assert_contains "the armv6l refusal message names ARMv6" "$(cat "$_sm_tmp/armv6.err")" "ARMv6"

# Disagreement case 1: kernel reports aarch64 (a Pi 4/5 boot pattern), the
# FPP binary is a 32-bit ELF (a real armhf userspace), but the aarch64
# linker fixture exists anyway. The two methods disagree and must refuse.
sm_uname_m() { echo aarch64; }
mkdir -p "$_sm_tmp/disagree-1/src"
make_elf "$_sm_tmp/disagree-1/src/fppd" 1
: > "$_sm_tmp/disagree-1/ld-linux-aarch64.so.1"
SM_AARCH64_LINKER_CANDIDATES="$_sm_tmp/disagree-1/ld-linux-aarch64.so.1"
export SM_AARCH64_LINKER_CANDIDATES
out=$(sm_detect_arch "$_sm_tmp/disagree-1" 2>"$_sm_tmp/disagree-1.err")
status=$?
assert_failure "disagreement (32-bit ELF, linker present) is refused, not guessed" "$status"
err=$(cat "$_sm_tmp/disagree-1.err")
assert_contains "disagreement message names the ELF reading" "$err" "32-bit"
assert_contains "disagreement message names the linker reading" "$err" "64-bit"

# Disagreement case 2, the mirror: 64-bit ELF but no aarch64 linker present.
sm_uname_m() { echo aarch64; }
mkdir -p "$_sm_tmp/disagree-2/src"
make_elf "$_sm_tmp/disagree-2/src/fppd" 2
SM_AARCH64_LINKER_CANDIDATES="$_sm_tmp/disagree-2/no-such-linker"
export SM_AARCH64_LINKER_CANDIDATES
out=$(sm_detect_arch "$_sm_tmp/disagree-2" 2>"$_sm_tmp/disagree-2.err")
status=$?
assert_failure "disagreement (64-bit ELF, linker absent) is refused, not guessed" "$status"
err=$(cat "$_sm_tmp/disagree-2.err")
assert_contains "disagreement message names the ELF reading" "$err" "64-bit"
assert_contains "disagreement message names the linker reading" "$err" "32-bit"

unset SM_AARCH64_LINKER_CANDIDATES

# No FPP binary anywhere to probe: refuse rather than default to something.
sm_uname_m() { echo aarch64; }
out=$(sm_detect_arch "$_sm_tmp/empty-fppdir" 2>"$_sm_tmp/nobinary.err")
status=$?
assert_failure "missing FPP binary to probe is refused" "$status"
assert_contains "missing-binary message says so" "$(cat "$_sm_tmp/nobinary.err")" "no FPP binary found"

# Unrecognized kernel machine type: refuse rather than guess.
sm_uname_m() { echo sparc64; }
out=$(sm_detect_arch "$_sm_tmp/empty-fppdir" 2>"$_sm_tmp/unrecognized.err")
status=$?
assert_failure "unrecognized kernel machine type is refused" "$status"

# A file that is not an ELF at all: refuse.
sm_uname_m() { echo aarch64; }
mkdir -p "$_sm_tmp/bad-magic/src"
make_bad_magic "$_sm_tmp/bad-magic/src/fppd"
out=$(sm_detect_arch "$_sm_tmp/bad-magic" 2>"$_sm_tmp/bad-magic.err")
status=$?
assert_failure "a non-ELF file at the FPP binary path is refused" "$status"

unset -f sm_uname_m

# ---------------------------------------------------------------------------
# sm_arch_repair_reason: the preStart.sh guard, as a testable function
# ---------------------------------------------------------------------------
#
# This is the function that answers "does preStart.sh need to repair this
# install", extracted out of preStart.sh itself because a script run as a
# subprocess cannot have sm_uname_m shadowed the way it is everywhere else
# in this file — POSIX sh has no portable way to export a function into a
# child process. Exercising it here is exercising preStart.sh's actual
# decision, not a reimplementation of it.

echo "== sm_arch_repair_reason (preStart.sh's guard) =="

_sm_stampdir="$_sm_tmp/arch-repair"
mkdir -p "$_sm_stampdir/fppdir"

# Matching stamp: no repair reason.
sm_uname_m() { echo x86_64; }
printf 'amd64\n' > "$(sm_arch_stamp_path "$_sm_stampdir")"
out=$(sm_arch_repair_reason "$_sm_stampdir" "$_sm_stampdir/fppdir")
assert_eq "a stamp matching a fresh detection produces no repair reason" "" "$out"

# Mismatched stamp: the disk-image-clone case this exists to catch. The
# binary was stamped arm64 but the host now detects as amd64.
sm_uname_m() { echo x86_64; }
printf 'arm64\n' > "$(sm_arch_stamp_path "$_sm_stampdir")"
out=$(sm_arch_repair_reason "$_sm_stampdir" "$_sm_stampdir/fppdir")
if [ -n "$out" ]; then
    pass "a stamp disagreeing with a fresh detection produces a repair reason"
else
    fail "a stamp disagreeing with a fresh detection produces a repair reason" "expected non-empty output, got none"
fi
assert_contains "the repair reason names the stamped architecture" "$out" "arm64"
assert_contains "the repair reason names the freshly detected architecture" "$out" "amd64"

# No stamp at all: nothing to compare against, so no repair reason —
# this is the "installed by an older version of this repository" case,
# not evidence of a mismatch.
rm -f "$(sm_arch_stamp_path "$_sm_stampdir")"
sm_uname_m() { echo x86_64; }
out=$(sm_arch_repair_reason "$_sm_stampdir" "$_sm_stampdir/fppdir")
assert_eq "no stamp at all produces no repair reason" "" "$out"

# Detection itself fails (e.g. an unrecognized machine type): a stamp
# exists, but since fresh detection cannot answer, this must not be
# treated as a mismatch.
printf 'amd64\n' > "$(sm_arch_stamp_path "$_sm_stampdir")"
sm_uname_m() { echo sparc64; }
out=$(sm_arch_repair_reason "$_sm_stampdir" "$_sm_stampdir/fppdir")
assert_eq "a failed fresh detection produces no repair reason, not a false mismatch" "" "$out"

# An EXISTING but EMPTY stamp file, unlike no stamp file at all, must
# produce a repair reason: this is what a non-atomic stamp write left
# behind before it was fixed to write-then-rename (see sm_write_stamp in
# activate.sh), and treating it the same as "no stamp" would leave the
# architecture guard permanently blind from that point on.
: > "$(sm_arch_stamp_path "$_sm_stampdir")"
sm_uname_m() { echo x86_64; }
out=$(sm_arch_repair_reason "$_sm_stampdir" "$_sm_stampdir/fppdir")
if [ -n "$out" ]; then
    pass "an existing but empty architecture stamp produces a repair reason, not silent health"
else
    fail "an existing but empty architecture stamp produces a repair reason, not silent health" "expected non-empty output, got none"
fi

unset -f sm_uname_m

# ---------------------------------------------------------------------------
# Checksum verification
# ---------------------------------------------------------------------------

# shellcheck disable=SC1090
. "$_sm_lib_dir/verify.sh"

echo "== checksum verification =="

_sm_ckdir="$_sm_tmp/checksum"
mkdir -p "$_sm_ckdir"
_sm_tarball="showmesh-fpp-plugin_0.1.0_linux_amd64.tar.gz"
printf 'not a real tarball, just fixture bytes for a hash to cover\n' > "$_sm_ckdir/$_sm_tarball"

_sm_real_sha=$(sha256sum "$_sm_ckdir/$_sm_tarball" | awk '{print $1}')
printf '%s  %s\n' "$_sm_real_sha" "$_sm_tarball" > "$_sm_ckdir/SHA256SUMS.good"
# A manifest that also covers an unrelated file, to prove the match is by
# exact filename and not by substring.
printf '%s  %s\n' "$_sm_real_sha" "$_sm_tarball" > "$_sm_ckdir/SHA256SUMS.multi"
printf 'deadbeef  showmesh-fpp-plugin_0.1.0_linux_arm64.tar.gz\n' >> "$_sm_ckdir/SHA256SUMS.multi"

if sm_verify_checksum "$_sm_ckdir/$_sm_tarball" "$_sm_ckdir/SHA256SUMS.good" "$_sm_tarball"; then
    pass "matching checksum verifies"
else
    fail "matching checksum verifies" "sm_verify_checksum returned non-zero on a correct pair"
fi

if sm_verify_checksum "$_sm_ckdir/$_sm_tarball" "$_sm_ckdir/SHA256SUMS.multi" "$_sm_tarball"; then
    pass "correct entry is matched by exact filename among several manifest lines"
else
    fail "correct entry is matched by exact filename among several manifest lines" "false negative"
fi

# Failed checksum: the manifest says one thing, the file is another.
_sm_wrong_sha="0000000000000000000000000000000000000000000000000000000000000000"
_sm_wrong_sha=$(printf '%s' "$_sm_wrong_sha" | cut -c1-64)
printf '%s  %s\n' "$_sm_wrong_sha" "$_sm_tarball" > "$_sm_ckdir/SHA256SUMS.bad"
if sm_verify_checksum "$_sm_ckdir/$_sm_tarball" "$_sm_ckdir/SHA256SUMS.bad" "$_sm_tarball"; then
    fail "mismatched checksum is rejected" "sm_verify_checksum returned success on a wrong hash"
else
    pass "mismatched checksum is rejected"
fi

# Tampered-after-verification case: manifest matches the original bytes,
# but the downloaded file was altered afterward (the scenario checksum
# verification exists to catch).
cp "$_sm_ckdir/$_sm_tarball" "$_sm_ckdir/tampered.tar.gz"
printf '%s  %s\n' "$_sm_real_sha" "tampered.tar.gz" > "$_sm_ckdir/SHA256SUMS.tampered"
printf 'extra bytes appended after the manifest was made\n' >> "$_sm_ckdir/tampered.tar.gz"
if sm_verify_checksum "$_sm_ckdir/tampered.tar.gz" "$_sm_ckdir/SHA256SUMS.tampered" "tampered.tar.gz"; then
    fail "a tampered file fails verification" "sm_verify_checksum accepted altered bytes"
else
    pass "a tampered file fails verification"
fi

# Missing manifest entry: refuse rather than silently pass.
: > "$_sm_ckdir/SHA256SUMS.empty"
if sm_verify_checksum "$_sm_ckdir/$_sm_tarball" "$_sm_ckdir/SHA256SUMS.empty" "$_sm_tarball"; then
    fail "no manifest entry for the artifact is rejected" "sm_verify_checksum accepted with nothing to check against"
else
    pass "no manifest entry for the artifact is rejected"
fi

# Missing files entirely: refuse rather than error obscurely.
if sm_verify_checksum "$_sm_ckdir/does-not-exist.tar.gz" "$_sm_ckdir/SHA256SUMS.good" "$_sm_tarball"; then
    fail "a missing downloaded artifact is rejected" "unexpected success"
else
    pass "a missing downloaded artifact is rejected"
fi

if sm_verify_checksum "$_sm_ckdir/$_sm_tarball" "$_sm_ckdir/does-not-exist.SHA256SUMS" "$_sm_tarball"; then
    fail "a missing checksum manifest is rejected" "unexpected success"
else
    pass "a missing checksum manifest is rejected"
fi

# sm_verify_sha256 is the actual install-time trust gate, so it must
# validate its own expected-hash argument rather than relying on every
# caller having done so first (every current caller does, but this
# function failing closed on its own is what makes that not load-bearing
# on its own). An empty expected hash must never be treated as anything
# other than malformed, regardless of what the real hash happens to be.
if sm_verify_sha256 "$_sm_ckdir/$_sm_tarball" ""; then
    fail "sm_verify_sha256 rejects an empty expected-hash argument" "unexpected success"
else
    pass "sm_verify_sha256 rejects an empty expected-hash argument"
fi

out=$(sm_verify_sha256 "$_sm_ckdir/$_sm_tarball" "" 2>&1)
assert_contains "sm_verify_sha256's empty-hash refusal names the argument, not a downstream mismatch" "$out" "expected-hash argument"

# Correct length, but not hex: also malformed, not just "wrong".
_sm_nonhex_hash=$(python3 -c "print('z' * 64)")
if sm_verify_sha256 "$_sm_ckdir/$_sm_tarball" "$_sm_nonhex_hash"; then
    fail "sm_verify_sha256 rejects a non-hex expected-hash argument of the right length" "unexpected success"
else
    pass "sm_verify_sha256 rejects a non-hex expected-hash argument of the right length"
fi

# A multi-line argument containing one genuinely valid 64-hex line among
# other content, and where that embedded line happens to be the file's
# REAL hash: a line-oriented guard (grep -Eq against the whole value) is
# fooled by this because it matches ANY line, not the whole value, so it
# waves the value through as "looks like a hash" and only the downstream
# checksum-mismatch comparison rejects it. That still fails closed either
# way (this multi-line value can never string-compare equal to the pure
# hash sm_sha256_of computes), which is why exit status alone cannot tell
# these two guards apart: the error message can. A guard that means what
# it says rejects this before ever computing the tarball's hash at all;
# a line-oriented guard reports it as a downstream "checksum mismatch"
# instead, having incorrectly accepted the argument's shape.
_sm_multiline_hash=$(printf 'garbage line one\n%s\nanother garbage line\n' "$_sm_real_sha")
out=$(sm_verify_sha256 "$_sm_ckdir/$_sm_tarball" "$_sm_multiline_hash" 2>&1)
status=$?
assert_failure "sm_verify_sha256 rejects a multi-line argument containing a valid hex line" "$status"
assert_contains "the rejection names the malformed argument, not a downstream checksum mismatch (proving the guard itself caught it, not the comparison after it)" "$out" "expected-hash argument"

# ---------------------------------------------------------------------------
# artifacts.lock.json lookup: the trust anchor sm_install_binary actually
# verifies against, instead of a checksum manifest fetched from the same
# host as the tarball.
# ---------------------------------------------------------------------------

# shellcheck disable=SC1090
. "$_sm_lib_dir/lock.sh"

echo "== artifacts.lock.json lookup =="

_sm_lockdir="$_sm_tmp/lock"
mkdir -p "$_sm_lockdir"
_sm_hash_amd64=$(python3 -c "print('a' * 64)")
_sm_hash_arm64=$(python3 -c "print('b' * 64)")
cat > "$_sm_lockdir/artifacts.lock.json" <<JSON
{
  "version": "1.2.3",
  "artifacts": [
    { "filename": "showmesh-fpp-plugin_1.2.3_linux_amd64.tar.gz", "kind": "go-helper", "architecture": "amd64", "sha256": "$_sm_hash_amd64" },
    { "filename": "showmesh-fpp-plugin_1.2.3_linux_arm64.tar.gz", "kind": "go-helper", "architecture": "arm64", "sha256": "$_sm_hash_arm64" }
  ]
}
JSON

assert_eq "sm_lock_version reads the lock's top-level version" "1.2.3" "$(sm_lock_version "$_sm_lockdir/artifacts.lock.json")"

out=$(sm_lock_sha256 "$_sm_lockdir/artifacts.lock.json" "showmesh-fpp-plugin_1.2.3_linux_amd64.tar.gz")
assert_eq "a lock lookup hit returns the expected sha256" "$_sm_hash_amd64" "$out"

out=$(sm_lock_sha256 "$_sm_lockdir/artifacts.lock.json" "showmesh-fpp-plugin_1.2.3_linux_armv7.tar.gz" 2>"$_sm_tmp/lock-miss.err")
status=$?
assert_failure "a lock lookup miss (filename not in the lock) is rejected" "$status"
assert_contains "the lookup-miss message names the filename" "$(cat "$_sm_tmp/lock-miss.err")" "armv7"

out=$(sm_lock_expected_sha256 "$_sm_lockdir" "9.9.9" "showmesh-fpp-plugin_1.2.3_linux_amd64.tar.gz" 2>"$_sm_tmp/lock-mismatch.err")
status=$?
assert_failure "a version mismatch between the lock and the requested install is rejected" "$status"
_sm_mismatch_err=$(cat "$_sm_tmp/lock-mismatch.err")
assert_contains "the version-mismatch message names the lock's version" "$_sm_mismatch_err" "1.2.3"
assert_contains "the version-mismatch message names the requested version" "$_sm_mismatch_err" "9.9.9"

out=$(sm_lock_expected_sha256 "$_sm_tmp/lock-does-not-exist" "1.2.3" "whatever.tar.gz" 2>&1)
status=$?
assert_failure "a missing artifacts.lock.json is rejected, not silently skipped" "$status"

# Malformed lock entry: a sha256 field present but not 64 hex characters.
mkdir -p "$_sm_lockdir-malformed"
cat > "$_sm_lockdir-malformed/artifacts.lock.json" <<'JSON'
{
  "version": "1.2.3",
  "artifacts": [
    { "filename": "showmesh-fpp-plugin_1.2.3_linux_amd64.tar.gz", "kind": "go-helper", "architecture": "amd64", "sha256": "not-a-real-hash" }
  ]
}
JSON
out=$(sm_lock_expected_sha256 "$_sm_lockdir-malformed" "1.2.3" "showmesh-fpp-plugin_1.2.3_linux_amd64.tar.gz" 2>&1)
status=$?
assert_failure "a malformed sha256 value in the lock is rejected" "$status"

# A minified lock (every artifact object on one single physical line): the
# per-filename count guard still confirms exactly one LINE names this
# filename, but grep -o against that one line finds every OTHER artifact's
# sha256 key too. Requesting the SECOND entry on the line is the case that
# actually exercises the bug: taking merely the first sha256 found on the
# line is coincidentally correct for the first entry, and wrong for every
# entry after it. sm_lock_sha256 must return exactly the requested
# artifact's hash regardless of its position on the line.
_sm_hash_minified_a=$(python3 -c "print('c' * 64)")
_sm_hash_minified_b=$(python3 -c "print('d' * 64)")
mkdir -p "$_sm_lockdir-minified"
printf '{"version": "1.2.3", "artifacts": [{ "filename": "a.tar.gz", "kind": "go-helper", "architecture": "amd64", "sha256": "%s" }, { "filename": "b.tar.gz", "kind": "go-helper", "architecture": "arm64", "sha256": "%s" }]}\n' \
    "$_sm_hash_minified_a" "$_sm_hash_minified_b" > "$_sm_lockdir-minified/artifacts.lock.json"
out=$(sm_lock_sha256 "$_sm_lockdir-minified/artifacts.lock.json" "b.tar.gz")
status=$?
assert_success "a lookup against a minified (single-line) lock succeeds" "$status"
assert_eq "a minified lock returns the SECOND entry's hash, not the first entry's hash on the same line" "$_sm_hash_minified_b" "$out"

# An unreadable lock file must be refused as unreadable specifically, not
# fall through grep/awk failures into an unrelated "no sha256 field" or
# "integer expression expected" error.
mkdir -p "$_sm_lockdir-unreadable"
cat > "$_sm_lockdir-unreadable/artifacts.lock.json" <<JSON
{
  "version": "1.2.3",
  "artifacts": [
    { "filename": "unreadable.tar.gz", "kind": "go-helper", "architecture": "amd64", "sha256": "$_sm_hash_amd64" }
  ]
}
JSON
chmod 000 "$_sm_lockdir-unreadable/artifacts.lock.json"
if [ "$(id -u)" -eq 0 ]; then
    skip "an unreadable lock file is refused as unreadable" "running as root; chmod 000 has no effect, cannot exercise this case here"
else
    out=$(sm_lock_sha256 "$_sm_lockdir-unreadable/artifacts.lock.json" "unreadable.tar.gz" 2>&1)
    status=$?
    assert_failure "an unreadable lock file is refused" "$status"
    assert_contains "the refusal names the file as unreadable, not some downstream symptom" "$out" "not readable"
fi
chmod 644 "$_sm_lockdir-unreadable/artifacts.lock.json"

# A per-artifact object that happens to carry its own "version" key must
# never be mistaken for the lock's top-level version pin, regardless of
# whether that artifact entry appears before or after the top-level key
# in the raw text.
mkdir -p "$_sm_lockdir-nested-version"
cat > "$_sm_lockdir-nested-version/artifacts.lock.json" <<JSON
{
  "artifacts": [
    { "filename": "x.tar.gz", "kind": "go-helper", "architecture": "amd64", "version": "9.9.9", "sha256": "$_sm_hash_amd64" }
  ],
  "version": "1.2.3"
}
JSON
out=$(sm_lock_version "$_sm_lockdir-nested-version/artifacts.lock.json")
assert_eq "sm_lock_version reads the top-level version, not a same-named key nested inside an artifact object" "1.2.3" "$out"

# A pretty-printed lock (e.g. the output of `jq .`, one key per line
# throughout, including inside each artifact object) puts a per-artifact
# "version" key at line-start too, exactly like the top-level one. This
# parser cannot tell them apart by position alone, so it must refuse the
# lock outright rather than silently returning whichever one it finds
# first, the bug this pretty-printed fixture reproduces.
mkdir -p "$_sm_lockdir-pretty-ambiguous"
cat > "$_sm_lockdir-pretty-ambiguous/artifacts.lock.json" <<JSON
{
  "version": "1.2.3",
  "artifacts": [
    {
      "filename": "x.tar.gz",
      "kind": "go-helper",
      "architecture": "amd64",
      "version": "9.9.9",
      "sha256": "$_sm_hash_amd64"
    }
  ]
}
JSON
out=$(sm_lock_version "$_sm_lockdir-pretty-ambiguous/artifacts.lock.json" 2>"$_sm_tmp/lock-pretty.err")
status=$?
assert_failure "a pretty-printed lock with a per-artifact version also at line-start is refused, not guessed" "$status"
assert_contains "the refusal names the ambiguity, not a downstream symptom" "$(cat "$_sm_tmp/lock-pretty.err")" "unambiguously"

# Two entries naming the SAME filename, minified onto one physical line:
# `grep -Fc` counts matching LINES, not occurrences, so this used to count
# as a single match and silently pick the first entry's hash rather than
# refusing an ambiguous lock. Reproduces on the same input shape a lock
# with one artifact per line already refused correctly.
_sm_hash_dup_a=$(python3 -c "print('e' * 64)")
_sm_hash_dup_b=$(python3 -c "print('f' * 64)")
mkdir -p "$_sm_lockdir-dup-minified"
printf '{"version": "1.2.3", "artifacts": [{ "filename": "dup.tar.gz", "kind": "go-helper", "architecture": "amd64", "sha256": "%s" }, { "filename": "dup.tar.gz", "kind": "go-helper", "architecture": "arm64", "sha256": "%s" }]}\n' \
    "$_sm_hash_dup_a" "$_sm_hash_dup_b" > "$_sm_lockdir-dup-minified/artifacts.lock.json"
out=$(sm_lock_sha256 "$_sm_lockdir-dup-minified/artifacts.lock.json" "dup.tar.gz" 2>"$_sm_tmp/lock-dup.err")
status=$?
assert_failure "two entries naming the same filename, minified onto one physical line, are refused as ambiguous" "$status"
assert_contains "the refusal names the ambiguity, counted as two entries, not one line" "$(cat "$_sm_tmp/lock-dup.err")" "2 entries naming dup.tar.gz"

# The same duplicate-filename case, one artifact per line: must also
# refuse, not just when minified.
mkdir -p "$_sm_lockdir-dup-lines"
cat > "$_sm_lockdir-dup-lines/artifacts.lock.json" <<JSON
{
  "version": "1.2.3",
  "artifacts": [
    { "filename": "dup.tar.gz", "kind": "go-helper", "architecture": "amd64", "sha256": "$_sm_hash_dup_a" },
    { "filename": "dup.tar.gz", "kind": "go-helper", "architecture": "arm64", "sha256": "$_sm_hash_dup_b" }
  ]
}
JSON
out=$(sm_lock_sha256 "$_sm_lockdir-dup-lines/artifacts.lock.json" "dup.tar.gz" 2>&1)
status=$?
assert_failure "two entries naming the same filename, one per line, are refused as ambiguous" "$status"

# An object whose "sha256" key comes BEFORE its "filename" key: JSON does
# not guarantee key order, and a regenerated lock is free to write them in
# either order. The old prefix-strip approach assumed "filename" always
# came first, so it read past this object's own (earlier) "sha256" and
# either found nothing or, on a minified multi-object line, found the
# NEXT artifact's hash instead. This parser demands the committed order
# and refuses rather than guessing at a different one.
_sm_hash_reordered=$(python3 -c "print('1' * 64)")
mkdir -p "$_sm_lockdir-reordered"
cat > "$_sm_lockdir-reordered/artifacts.lock.json" <<JSON
{
  "version": "1.2.3",
  "artifacts": [
    { "sha256": "$_sm_hash_reordered", "kind": "go-helper", "architecture": "amd64", "filename": "reordered.tar.gz" }
  ]
}
JSON
out=$(sm_lock_sha256 "$_sm_lockdir-reordered/artifacts.lock.json" "reordered.tar.gz" 2>"$_sm_tmp/lock-reordered.err")
status=$?
assert_failure "an object with sha256 before filename is refused, not guessed at" "$status"
assert_contains "the refusal names the ambiguity, not a generic missing-field message" "$(cat "$_sm_tmp/lock-reordered.err")" "unambiguously"

# The reordered case combined with minification, on TWO objects sharing
# one physical line: this is the shape that used to return a different
# artifact's hash at exit 0 rather than merely failing to find one.
# Requesting the FIRST artifact on the line must not return the SECOND
# artifact's sha256.
_sm_hash_reordered_a=$(python3 -c "print('2' * 64)")
_sm_hash_reordered_b=$(python3 -c "print('3' * 64)")
mkdir -p "$_sm_lockdir-reordered-minified"
printf '{"version": "1.2.3", "artifacts": [{ "sha256": "%s", "kind": "go-helper", "architecture": "amd64", "filename": "ra.tar.gz" }, { "filename": "rb.tar.gz", "kind": "go-helper", "architecture": "arm64", "sha256": "%s" }]}\n' \
    "$_sm_hash_reordered_a" "$_sm_hash_reordered_b" > "$_sm_lockdir-reordered-minified/artifacts.lock.json"
out=$(sm_lock_sha256 "$_sm_lockdir-reordered-minified/artifacts.lock.json" "ra.tar.gz" 2>&1)
status=$?
assert_failure "the first artifact's reordered object is refused rather than returning the second artifact's hash" "$status"
if [ "$out" = "$_sm_hash_reordered_b" ]; then
    fail "the reordered first entry never returns the second entry's hash" "returned $out, which is the SECOND artifact's sha256"
else
    pass "the reordered first entry never returns the second entry's hash"
fi
out=$(sm_lock_sha256 "$_sm_lockdir-reordered-minified/artifacts.lock.json" "rb.tar.gz")
status=$?
assert_success "the second, correctly-ordered object on the same line still resolves" "$status"
assert_eq "the second object's own hash is returned" "$_sm_hash_reordered_b" "$out"

# A "sha256" NESTED inside some other key of the same entry (a "meta"
# object, say) must not be mistaken for the entry's own top-level hash:
# the pattern that finds "sha256" fields has no concept of JSON nesting,
# so it used to find both, silently take the FIRST one (the nested
# value), and return it at exit 0.
_sm_hash_nested_outer=$(python3 -c "print('a' * 64)")
_sm_hash_nested_inner=$(python3 -c "print('c' * 64)")
mkdir -p "$_sm_lockdir-nested-sha256"
cat > "$_sm_lockdir-nested-sha256/artifacts.lock.json" <<JSON
{
  "version": "1.2.3",
  "artifacts": [
    { "filename": "nested.tar.gz", "meta": { "sha256": "$_sm_hash_nested_inner" }, "sha256": "$_sm_hash_nested_outer" }
  ]
}
JSON
out=$(sm_lock_sha256 "$_sm_lockdir-nested-sha256/artifacts.lock.json" "nested.tar.gz" 2>&1)
status=$?
assert_failure "an entry with a sha256 nested inside another key is refused, not resolved to the nested value" "$status"
if [ "$out" = "$_sm_hash_nested_inner" ]; then
    fail "the nested sha256 is never silently returned" "returned $out, which is the NESTED value, not a refusal"
else
    pass "the nested sha256 is never silently returned"
fi

# The case above still has a top-level "sha256" (the outer one) to
# outnumber the nested one, so the sha_count-gt-1 branch above catches it
# on its own; the brace-depth check right after it is never actually
# exercised by that fixture. An entry with a nested "sha256" and NO
# top-level one at all (only the "meta" object carries the field) is the
# shape that specifically exercises the brace-depth check: exactly one
# "sha256" match total, so the count check passes it through, and only
# the depth check can still refuse it.
_sm_hash_nested_only=$(python3 -c "print('d' * 64)")
mkdir -p "$_sm_lockdir-nested-sha256-only"
cat > "$_sm_lockdir-nested-sha256-only/artifacts.lock.json" <<JSON
{
  "version": "1.2.3",
  "artifacts": [
    { "filename": "nested-only.tar.gz", "meta": { "sha256": "$_sm_hash_nested_only" } }
  ]
}
JSON
out=$(sm_lock_sha256 "$_sm_lockdir-nested-sha256-only/artifacts.lock.json" "nested-only.tar.gz" 2>&1)
status=$?
assert_failure "an entry whose ONLY sha256 is nested inside another key, with no top-level sha256 at all, is refused" "$status"
if [ "$out" = "$_sm_hash_nested_only" ]; then
    fail "the nested-only sha256 is never silently returned" "returned $out, which is the NESTED value, not a refusal"
else
    pass "the nested-only sha256 is never silently returned"
fi

# The brace-depth check above counts `{`/`}` characters in the raw text,
# which is blind to a brace sitting inside a JSON STRING value rather
# than acting as real structure. An entry whose only sha256 is nested,
# preceded by a string field whose VALUE is literally "}", used to
# understate the open-brace count enough to pass the depth check and
# return the nested hash at exit 0.
_sm_hash_nested_string_trap=$(python3 -c "print('9' * 64)")
mkdir -p "$_sm_lockdir-nested-sha256-string-trap"
cat > "$_sm_lockdir-nested-sha256-string-trap/artifacts.lock.json" <<JSON
{
  "version": "1.2.3",
  "artifacts": [
    { "filename": "trap.tar.gz", "note": "}", "meta": { "sha256": "$_sm_hash_nested_string_trap" } }
  ]
}
JSON
out=$(sm_lock_sha256 "$_sm_lockdir-nested-sha256-string-trap/artifacts.lock.json" "trap.tar.gz" 2>&1)
status=$?
assert_failure "a brace character inside a string value does not defeat the nested-sha256 refusal" "$status"
if [ "$out" = "$_sm_hash_nested_string_trap" ]; then
    fail "the string-trapped nested sha256 is never silently returned" "returned $out, which is the NESTED value, not a refusal"
else
    pass "the string-trapped nested sha256 is never silently returned"
fi

# The duplicate-filename guard above counts LINES with grep -Fc, which
# undercounts two occurrences that share ONE physical, minified line as a
# single match. A single OBJECT with a duplicated "filename" key (and a
# duplicated "sha256" key to go with it) on one line exercises exactly
# that undercount, distinct from the two-separate-objects duplicate case
# above: this used to pass the ambiguity guard and return the FIRST
# sha256, where JSON semantics give the last.
_sm_hash_dupkey_a=$(python3 -c "print('1' * 64)")
_sm_hash_dupkey_b=$(python3 -c "print('2' * 64)")
mkdir -p "$_sm_lockdir-dup-keys-one-object"
printf '{"version": "1.2.3", "artifacts": [{ "filename": "dupkey.tar.gz", "filename": "dupkey.tar.gz", "sha256": "%s", "sha256": "%s" }]}\n' \
    "$_sm_hash_dupkey_a" "$_sm_hash_dupkey_b" > "$_sm_lockdir-dup-keys-one-object/artifacts.lock.json"
out=$(sm_lock_sha256 "$_sm_lockdir-dup-keys-one-object/artifacts.lock.json" "dupkey.tar.gz" 2>"$_sm_tmp/lock-dupkey.err")
status=$?
assert_failure "a single object with a duplicated filename key, minified onto one line, is refused as ambiguous" "$status"
assert_contains "the refusal counts 2 entries, not the 1 a line-based count would see" "$(cat "$_sm_tmp/lock-dupkey.err")" "2 entries naming dupkey.tar.gz"

# An empty "sha256" value is a field that IS present and IS in the right
# place (after "filename"), just empty: a different case from the field
# being absent or misordered, which the old check for -z "$_sm_hash"
# could not tell apart from this one. It must still fail closed, but with
# its own, accurate message.
mkdir -p "$_sm_lockdir-empty-sha256"
cat > "$_sm_lockdir-empty-sha256/artifacts.lock.json" <<'JSON'
{
  "version": "1.2.3",
  "artifacts": [
    { "filename": "blank.tar.gz", "sha256": "" }
  ]
}
JSON
out=$(sm_lock_sha256 "$_sm_lockdir-empty-sha256/artifacts.lock.json" "blank.tar.gz" 2>&1)
status=$?
assert_failure "an empty sha256 value is refused" "$status"
# The filename deliberately avoids the substring "empty" so this
# assertion cannot pass by coincidentally matching the filename embedded
# in a DIFFERENT, wrong message (the old "does not come after filename"
# text) instead of actually proving the new, accurate message fired.
assert_contains "the refusal names the value as empty, not a fabricated key-ordering problem" "$out" "empty sha256 value"

# The compromised-host case this whole mechanism exists for: a downloaded
# tarball and a downloaded SHA256SUMS agree with each other (as if the
# manifest were generated from these same, tampered bytes), but disagree
# with the committed lock. The old same-origin check (sm_verify_checksum)
# would have accepted this pair; the actual install gate
# (sm_lock_expected_sha256 + sm_verify_sha256) must not.
_sm_compdir="$_sm_tmp/compromised"
mkdir -p "$_sm_compdir"
_sm_comp_tarball="showmesh-fpp-plugin_1.2.3_linux_amd64.tar.gz"
printf 'attacker-controlled bytes, self-consistent with their own manifest\n' > "$_sm_compdir/$_sm_comp_tarball"
_sm_attacker_hash=$(sha256sum "$_sm_compdir/$_sm_comp_tarball" | awk '{print $1}')
printf '%s  %s\n' "$_sm_attacker_hash" "$_sm_comp_tarball" > "$_sm_compdir/SHA256SUMS"
_sm_legit_hash=$(python3 -c "print('e' * 64)")
cat > "$_sm_compdir/artifacts.lock.json" <<JSON
{
  "version": "1.2.3",
  "artifacts": [
    { "filename": "$_sm_comp_tarball", "kind": "go-helper", "architecture": "amd64", "sha256": "$_sm_legit_hash" }
  ]
}
JSON

if sm_verify_checksum "$_sm_compdir/$_sm_comp_tarball" "$_sm_compdir/SHA256SUMS" "$_sm_comp_tarball"; then
    pass "the compromised pair is self-consistent (the attack surface a manifest-only check cannot see)"
else
    fail "the compromised pair is self-consistent (the attack surface a manifest-only check cannot see)" "test setup is wrong: the downloaded manifest and tarball should agree with each other"
fi

_sm_comp_expected=$(sm_lock_expected_sha256 "$_sm_compdir" "1.2.3" "$_sm_comp_tarball")
if sm_verify_sha256 "$_sm_compdir/$_sm_comp_tarball" "$_sm_comp_expected"; then
    fail "the compromised host's self-consistent pair is rejected by the lock-anchored check" "sm_verify_sha256 accepted a tarball the committed lock disagrees with"
else
    pass "the compromised host's self-consistent pair is rejected by the lock-anchored check"
fi

# lock.sh's own header says every tool it uses is resolved to an absolute
# path precisely because none of this repository's invocation conventions
# can be trusted to carry a PATH: a bare `tr` regressed into
# sm_lock_sha256's own flattening step despite that. Run in a subshell so
# clearing PATH here cannot affect anything after this block, including
# the "$( )" command substitutions this suite itself relies on throughout.
# sm_resolve_bin's candidates are absolute paths checked with `[ -x ]`, so
# a correctly resolved tool must keep working with no PATH at all; a bare
# invocation instead fails, and the bug this closes was not that failure
# itself but sm_lock_sha256 misreporting it as "no entry for the
# artifact" rather than a tool being missing.
out=$(
    # shellcheck disable=SC2123
    PATH=""
    sm_lock_sha256 "$_sm_lockdir/artifacts.lock.json" "showmesh-fpp-plugin_1.2.3_linux_amd64.tar.gz" 2>&1
)
status=$?
assert_success "sm_lock_sha256 succeeds with an empty PATH (every tool it uses is resolved to an absolute path)" "$status"
assert_eq "the lookup still returns the correct hash with an empty PATH" "$_sm_hash_amd64" "$out"

# ---------------------------------------------------------------------------
# Command script validation
# ---------------------------------------------------------------------------

# shellcheck disable=SC1090
. "$_sm_lib_dir/commands.sh"

echo "== command script validation =="

make_plugin_tree() {
    # $1 = plugin dir to create, populated with a commands/descriptions.json
    # naming one script. The caller decides whether that script exists.
    mkdir -p "$1/commands"
}

# All named scripts exist and are executable: passes clean.
_sm_cmd_ok="$_sm_tmp/cmd-ok"
make_plugin_tree "$_sm_cmd_ok"
cat > "$_sm_cmd_ok/commands/descriptions.json" <<'JSON'
[
  {
    "name": "ShowMeshRunMacro",
    "script": "run-macro.sh",
    "args": [
      { "name": "macroId", "description": "the macro id, containing the word script inside this sentence to prove extraction is not fooled by it", "type": "string", "optional": false }
    ]
  }
]
JSON
printf '#!/bin/sh\ntrue\n' > "$_sm_cmd_ok/commands/run-macro.sh"
chmod 0755 "$_sm_cmd_ok/commands/run-macro.sh"

if sm_validate_command_scripts "$_sm_cmd_ok"; then
    pass "a descriptions.json whose script exists and is executable validates"
else
    fail "a descriptions.json whose script exists and is executable validates" "unexpected failure"
fi

names=$(sm_command_script_names "$_sm_cmd_ok/commands/descriptions.json")
assert_eq "script name extraction ignores 'script' appearing inside a description string" "run-macro.sh" "$names"

# The named script does not exist at all.
_sm_cmd_missing="$_sm_tmp/cmd-missing"
make_plugin_tree "$_sm_cmd_missing"
cat > "$_sm_cmd_missing/commands/descriptions.json" <<'JSON'
[
  { "name": "ShowMeshRunMacro", "script": "run-macro.sh", "args": [] }
]
JSON
out=$(sm_validate_command_scripts "$_sm_cmd_missing" 2>"$_sm_tmp/cmd-missing.err")
status=$?
assert_failure "a descriptions.json naming a script that does not exist is rejected" "$status"
assert_contains "the missing-script message names the script" "$(cat "$_sm_tmp/cmd-missing.err")" "run-macro.sh"

# The named script exists but was committed without the executable bit —
# the case FPP's own IsOk() would let through and then fail on when fired.
_sm_cmd_noexec="$_sm_tmp/cmd-noexec"
make_plugin_tree "$_sm_cmd_noexec"
cat > "$_sm_cmd_noexec/commands/descriptions.json" <<'JSON'
[
  { "name": "ShowMeshRunMacro", "script": "run-macro.sh", "args": [] }
]
JSON
printf '#!/bin/sh\ntrue\n' > "$_sm_cmd_noexec/commands/run-macro.sh"
chmod 0644 "$_sm_cmd_noexec/commands/run-macro.sh"
out=$(sm_validate_command_scripts "$_sm_cmd_noexec" 2>"$_sm_tmp/cmd-noexec.err")
status=$?
assert_failure "a descriptions.json naming a script that exists but is not executable is rejected" "$status"
assert_contains "the not-executable message distinguishes it from missing" "$(cat "$_sm_tmp/cmd-noexec.err")" "not executable"

# No descriptions.json at all.
_sm_cmd_nofile="$_sm_tmp/cmd-nofile"
mkdir -p "$_sm_cmd_nofile"
if sm_validate_command_scripts "$_sm_cmd_nofile" 2>/dev/null; then
    fail "a missing descriptions.json is rejected" "unexpected success"
else
    pass "a missing descriptions.json is rejected"
fi

# ---------------------------------------------------------------------------
# sm_fppdir: two different FPP callers, two different conventions
# ---------------------------------------------------------------------------

echo "== sm_fppdir =="

# NOTE: assertions in this section deliberately run in the main shell, not
# inside a subshell wrapping the FPPDIR manipulation — pass/fail counters
# are plain variables and a subshell's increments to them vanish when the
# subshell exits, which would silently make every assertion in here count
# for nothing. FPPDIR is unset again after each case instead.

# Fresh-install convention: install_plugin passes "FPPDIR=<dir>" as a
# literal argv word, not a shell assignment, and does not export it.
unset FPPDIR
out=$(sm_fppdir "FPPDIR=/opt/fpp")
assert_eq "a literal FPPDIR=<dir> argv word has the prefix stripped" "/opt/fpp" "$out"

# Upgrade convention: plugin.php exports FPPDIR before invoking sudo -E,
# and $1 arrives empty.
FPPDIR=/opt/fpp-custom
export FPPDIR
out=$(sm_fppdir "")
assert_eq "FPPDIR from the environment is used when \$1 is empty" "/opt/fpp-custom" "$out"
unset FPPDIR

# Environment takes priority when, hypothetically, both are present.
FPPDIR=/opt/fpp-from-env
export FPPDIR
out=$(sm_fppdir "FPPDIR=/opt/fpp-from-arg")
assert_eq "environment is checked before argv" "/opt/fpp-from-env" "$out"
unset FPPDIR

# Neither present: falls back to the documented default.
out=$(sm_fppdir "")
assert_eq "falls back to /opt/fpp when neither source has a value" "/opt/fpp" "$out"

# A plain directory string (not a FPPDIR=-prefixed one) in $1 is used as
# given — defensive, in case a future FPP version changes its calling
# convention back to a bare positional path.
out=$(sm_fppdir "/opt/fpp-bare")
assert_eq "a bare (non-prefixed) \$1 is used as-is" "/opt/fpp-bare" "$out"

# ---------------------------------------------------------------------------
# Artifact base URL scheme enforcement
# ---------------------------------------------------------------------------

# shellcheck disable=SC1090
. "$_sm_lib_dir/fetch.sh"

echo "== base URL scheme enforcement =="

if sm_check_base_url_scheme "https://example.invalid/release" 2>/dev/null; then
    pass "an https:// base URL passes"
else
    fail "an https:// base URL passes" "unexpected rejection"
fi

out=$(sm_check_base_url_scheme "http://example.invalid/release" 2>&1)
status=$?
assert_success "a plain http:// base URL is accepted (bench override)" "$status"
assert_contains "a plain http:// base URL is logged, not silent" "$out" "plain http"

out=$(sm_check_base_url_scheme "example.invalid/release" 2>&1)
status=$?
assert_failure "a base URL with no scheme at all is rejected" "$status"

out=$(sm_check_base_url_scheme "ftp://example.invalid/release" 2>&1)
status=$?
assert_failure "a base URL with an unrecognized scheme is rejected" "$status"

# ---------------------------------------------------------------------------
# Mode verification
# ---------------------------------------------------------------------------

echo "== mode verification =="

_sm_modedir="$_sm_tmp/modes"
mkdir -p "$_sm_modedir"

_sm_modefile="$_sm_modedir/testfile"
: > "$_sm_modefile"
chmod 600 "$_sm_modefile"

if sm_verify_mode "$_sm_modefile" 600 ; then
    pass "a mode that was actually set verifies"
else
    fail "a mode that was actually set verifies" "unexpected failure reading back 600"
fi

if sm_verify_mode "$_sm_modefile" 644; then
    fail "a mode that was NOT set is rejected" "sm_verify_mode accepted 644 on a 600 file"
else
    pass "a mode that was NOT set is rejected"
fi

out=$(sm_verify_mode "$_sm_modedir/does-not-exist" 600 2>&1)
status=$?
assert_failure "verifying the mode of a nonexistent path fails rather than silently passing" "$status"

# ---------------------------------------------------------------------------
# Stage-then-swap binary activation, with rollback
# ---------------------------------------------------------------------------

# shellcheck disable=SC1090
. "$_sm_lib_dir/activate.sh"

echo "== stage-then-swap activation =="

# No "fpp" system user exists on the machine running this suite (see
# README.md's "what has not been verified" section), so sm_stage_binary's
# chown would fail loudly here even on a healthy stage. Point it at the
# current user instead so these tests exercise a real, successful chown
# rather than skipping ownership entirely; production code never sets
# this and always targets fpp:fpp.
SM_INSTALL_OWNER="$(id -un):$(id -gn)"
export SM_INSTALL_OWNER

# sm_ensure_scaffold_stage_dir's own chown targets root:root by default,
# which this suite's unprivileged user cannot set either (and running as
# root, per the gate this project requires, would trivially chown to the
# real root:root anyway with nothing left to override). Same pattern as
# SM_INSTALL_OWNER above.
SM_SCAFFOLD_STAGE_OWNER="$(id -un):$(id -gn)"
export SM_SCAFFOLD_STAGE_OWNER

_sm_actdir="$_sm_tmp/activate"
mkdir -p "$_sm_actdir"

# Fresh install: no previous binary at all. Stage then activate, and
# confirm nothing but the final target is left behind.
_sm_act_target="$_sm_actdir/fresh-plugin"
_sm_act_staging="$_sm_act_target.staging"
printf 'new binary content\n' > "$_sm_tmp/act-fresh-source"
if sm_stage_binary "$_sm_tmp/act-fresh-source" "$_sm_act_staging" \
    && sm_activate_binary "$_sm_act_staging" "$_sm_act_target"; then
    pass "a fresh install with no previous binary stages and activates cleanly"
else
    fail "a fresh install with no previous binary stages and activates cleanly" "unexpected failure"
fi
assert_eq "the activated binary is executable (mode 0755)" "755" "$(sm_current_mode "$_sm_act_target")"
assert_eq "no staging file is left behind after a successful activation" "" "$( [ -e "$_sm_act_staging" ] && echo present )"
assert_eq "no backup file is left behind after a successful fresh activation (there was no previous binary to preserve)" "" "$( [ -e "$_sm_act_target.previous" ] && echo present )"

# ---------------------------------------------------------------------------
# sm_stage_binary against a hostile plugin directory: the TOCTOU window a
# chmod/chown run AFTER staging left open (an "fpp" race between the
# rename onto the staging path and the chmod/chown that used to follow it
# could redirect a root chmod/chown onto an arbitrary path), and a
# directory planted at the staging path ahead of a fresh install.
#
# A live 300-iteration race against the OLD implementation is not run
# here: it is exactly as flaky as a real race is, by nature, and the fix
# below closes the window structurally rather than narrowing it, so a
# structural proof is the right kind of evidence for it, not a
# probabilistic one. This is a STRUCTURAL test, not a live race: it
# proves chmod/chown never execute against the shared staging path at
# all, in this implementation, for any input, rather than trying to catch
# a race in the act.
# ---------------------------------------------------------------------------

_sm_toctou_dir="$_sm_tmp/stage-toctou"
mkdir -p "$_sm_toctou_dir/fake-bin"
_sm_toctou_log="$_sm_toctou_dir/calls.log"
: > "$_sm_toctou_log"
cat > "$_sm_toctou_dir/fake-bin/chmod" <<FAKE
#!/bin/sh
printf 'chmod %s\n' "\$*" >> "$_sm_toctou_log"
exec chmod "\$@"
FAKE
cat > "$_sm_toctou_dir/fake-bin/chown" <<FAKE
#!/bin/sh
printf 'chown %s\n' "\$*" >> "$_sm_toctou_log"
exec chown "\$@"
FAKE
chmod 0755 "$_sm_toctou_dir/fake-bin/chmod" "$_sm_toctou_dir/fake-bin/chown"

# Only chmod/chown are shadowed; every other tool sm_stage_binary needs
# still resolves for real, the same partial-shadow technique the ln-
# fallback test below uses.
sm_resolve_bin() {
    case "$1" in
        chmod) printf '%s\n' "$_sm_toctou_dir/fake-bin/chmod"; return 0 ;;
        chown) printf '%s\n' "$_sm_toctou_dir/fake-bin/chown"; return 0 ;;
    esac
    _sm_toctou_name="$1"
    shift
    for _sm_candidate in "$@"; do
        if [ -x "$_sm_candidate" ]; then
            printf '%s\n' "$_sm_candidate"
            return 0
        fi
    done
    sm_log_err "required tool not found: $_sm_toctou_name (checked: $*)"
    return 1
}

_sm_toctou_target="$_sm_actdir/toctou-plugin"
_sm_toctou_staging="$_sm_toctou_target.staging"
printf 'binary content for the toctou structural proof\n' > "$_sm_tmp/toctou-source"
if sm_stage_binary "$_sm_tmp/toctou-source" "$_sm_toctou_staging"; then
    pass "sm_stage_binary succeeds with chmod/chown wrapped for the TOCTOU structural proof"
else
    fail "sm_stage_binary succeeds with chmod/chown wrapped for the TOCTOU structural proof" "unexpected failure"
fi
# shellcheck disable=SC1090
. "$_sm_lib_dir/common.sh"

if [ -s "$_sm_toctou_log" ]; then
    pass "the chmod/chown wrappers were actually invoked (the proof below is not vacuous)"
else
    fail "the chmod/chown wrappers were actually invoked (the proof below is not vacuous)" "the log is empty; chmod/chown were never called at all"
fi
if grep -F "$_sm_toctou_staging" "$_sm_toctou_log" >/dev/null 2>&1; then
    fail "chmod/chown never run against the shared staging path" "$(cat "$_sm_toctou_log")"
else
    pass "chmod/chown never run against the shared staging path (both ran only against the private source path before it was ever staged)"
fi

# A directory planted at the staging path (reachable on a fresh install,
# where nothing has ever legitimately occupied that path before) must be
# refused, not silently accepted with the new binary moved INSIDE it:
# `mv -f` onto an existing directory does not fail, it relocates the
# source inside that directory instead, which would leave a directory at
# the binary's own path, reported as a successful install, that preStart
# would then find "healthy" (its own [-x] check on a directory is false,
# but nothing distinguishes a fresh empty directory left mid-mutation
# from any other unexpected state without this refusal in place).
_sm_dirstage_target="$_sm_actdir/dirstage-plugin"
_sm_dirstage_staging="$_sm_dirstage_target.staging"
mkdir -p "$_sm_dirstage_staging"
printf 'binary content that must never land inside the planted directory\n' > "$_sm_tmp/dirstage-source"
out=$(sm_stage_binary "$_sm_tmp/dirstage-source" "$_sm_dirstage_staging" 2>&1)
status=$?
assert_failure "sm_stage_binary refuses a directory planted at the staging path" "$status"
assert_eq "nothing was moved inside the planted directory" "" "$(ls -A "$_sm_dirstage_staging" 2>/dev/null)"

# Upgrade: a previous binary exists, the swap succeeds, and the new
# content is what is live. The backup is deliberately still on disk right
# after sm_activate_binary returns (see its header): the activation
# transaction is not committed until the caller calls sm_activate_commit,
# which is what a caller with more failable steps after the swap (see
# sm_install_binary) uses to decide when it is actually safe to discard
# the previous binary.
_sm_act_target2="$_sm_actdir/upgrade-plugin"
printf 'old binary content\n' > "$_sm_act_target2"
chmod 0755 "$_sm_act_target2"
_sm_act_staging2="$_sm_act_target2.staging"
printf 'new binary content v2\n' > "$_sm_tmp/act-upgrade-source"
sm_stage_binary "$_sm_tmp/act-upgrade-source" "$_sm_act_staging2" \
    || fail "staging succeeds ahead of the upgrade-activation test" "sm_stage_binary itself failed; see stderr above"
if sm_activate_binary "$_sm_act_staging2" "$_sm_act_target2"; then
    pass "an upgrade over an existing binary activates cleanly"
else
    fail "an upgrade over an existing binary activates cleanly" "unexpected failure"
fi
assert_eq "the upgraded target now serves the new content" "new binary content v2" "$(cat "$_sm_act_target2")"
assert_eq "the backup is still present immediately after activation, uncommitted" "present" "$( [ -e "$_sm_act_target2.previous" ] && echo present )"
assert_eq "the preserved backup still holds the OLD content" "old binary content" "$(cat "$_sm_act_target2.previous")"
sm_activate_commit "$_sm_act_target2"
assert_eq "no backup file is left behind once the transaction is committed" "" "$( [ -e "$_sm_act_target2.previous" ] && echo present )"

# Failure during post-staging validation: shadow sm_verify_mode (the same
# technique arch.sh's tests use on sm_uname_m) to force staging's mode
# check to fail. The previous binary must survive untouched and
# executable, and the staging file must be discarded.
_sm_act_target3="$_sm_actdir/validation-failure-plugin"
printf 'previous binary, must survive\n' > "$_sm_act_target3"
chmod 0755 "$_sm_act_target3"
_sm_act_staging3="$_sm_act_target3.staging"
printf 'new binary that never gets validated\n' > "$_sm_tmp/act-badvalidation-source"
sm_verify_mode() { sm_log_err "test-injected mode verification failure"; return 1; }
out=$(sm_stage_binary "$_sm_tmp/act-badvalidation-source" "$_sm_act_staging3" 2>&1)
status=$?
# shellcheck disable=SC1090
. "$_sm_lib_dir/common.sh"
assert_failure "a failure injected during post-staging mode validation is rejected" "$status"
assert_eq "the previous binary survives a post-staging validation failure" "previous binary, must survive" "$(cat "$_sm_act_target3")"
if [ -x "$_sm_act_target3" ]; then
    pass "the previous binary remains executable after a post-staging validation failure"
else
    fail "the previous binary remains executable after a post-staging validation failure" "lost its executable bit"
fi
assert_eq "the staging file is removed after a post-staging validation failure" "" "$( [ -e "$_sm_act_staging3" ] && echo present )"

# Failure in the swap itself, after staging (and the previous-binary
# backup) already succeeded: shadow sm_atomic_rename to fail on its one
# remaining call within activation (the staging-to-target swap; backing
# up the previous binary now uses `ln`, not sm_atomic_rename at all; see
# the file header for why). A failed rename never touches its
# destination, so the previous binary must still be exactly what is live
# at the target: no separate rollback rename is needed, or performed.
_sm_act_target4="$_sm_actdir/swap-failure-plugin"
printf 'previous binary, must be restored\n' > "$_sm_act_target4"
chmod 0755 "$_sm_act_target4"
_sm_act_staging4="$_sm_act_target4.staging"
printf 'new binary that never goes live\n' > "$_sm_tmp/act-badswap-source"
sm_stage_binary "$_sm_tmp/act-badswap-source" "$_sm_act_staging4" \
    || fail "staging succeeds ahead of the swap-failure test" "sm_stage_binary itself failed; see stderr above"
sm_atomic_rename() { return 1; }
out=$(sm_activate_binary "$_sm_act_staging4" "$_sm_act_target4" 2>&1)
status=$?
# shellcheck disable=SC1090
. "$_sm_lib_dir/activate.sh"
assert_failure "a failure injected in the swap itself, after staging succeeded, is rejected" "$status"
assert_eq "the previous binary is still live at the target after a failed swap (never moved away in the first place)" "previous binary, must be restored" "$(cat "$_sm_act_target4")"
if [ -x "$_sm_act_target4" ]; then
    pass "the still-live previous binary remains executable"
else
    fail "the still-live previous binary remains executable" "lost its executable bit"
fi
assert_contains "the failure message says no rollback is needed" "$out" "no rollback is needed"
assert_eq "the staging file is removed after a failed swap" "" "$( [ -e "$_sm_act_staging4" ] && echo present )"
assert_eq "the now-unneeded backup is removed after a failed swap" "" "$( [ -e "$_sm_act_target4.previous" ] && echo present )"

# ---------------------------------------------------------------------------
# sm_activate_rollback: post-activation failure, after the swap already
# succeeded (the case Finding 2 closed; see sm_install_binary's own
# transaction-boundary comment in install-core.sh, exercised end to end
# in the "install/upgrade pipeline" section below).
# ---------------------------------------------------------------------------

_sm_act_target5="$_sm_actdir/rollback-plugin"
printf 'previous binary, must come back after rollback\n' > "$_sm_act_target5"
chmod 0755 "$_sm_act_target5"
_sm_act_staging5="$_sm_act_target5.staging"
printf 'new binary that goes live but then fails a later check\n' > "$_sm_tmp/act-rollback-source"
sm_stage_binary "$_sm_tmp/act-rollback-source" "$_sm_act_staging5" \
    || fail "staging succeeds ahead of the rollback test" "sm_stage_binary itself failed; see stderr above"
sm_activate_binary "$_sm_act_staging5" "$_sm_act_target5" \
    || fail "activation succeeds ahead of the rollback test" "sm_activate_binary itself failed; see stderr above"
assert_eq "the new binary is live right after activation, before any rollback" "new binary that goes live but then fails a later check" "$(cat "$_sm_act_target5")"

out=$(sm_activate_rollback "$_sm_act_target5" 2>&1)
status=$?
assert_success "sm_activate_rollback succeeds when a backup is present" "$status"
assert_eq "sm_activate_rollback restores the previous binary's content" "previous binary, must come back after rollback" "$(cat "$_sm_act_target5")"
assert_eq "sm_activate_rollback removes the backup name once restored" "" "$( [ -e "$_sm_act_target5.previous" ] && echo present )"

out=$(sm_activate_rollback "$_sm_act_target5" 2>&1)
status=$?
assert_failure "sm_activate_rollback with no backup present refuses rather than silently doing nothing" "$status"

# ---------------------------------------------------------------------------
# sm_activate_binary's backup mechanism: hard link, not the two-rename form
# it replaced. See activate.sh's file header for why the two-rename form
# leaves a real crash window where the target name is briefly unoccupied.
# Nothing above this point in the suite distinguished the two forms: both
# leave the same final content on disk when nothing fails mid-sequence, so
# reverting the `ln` back to a second sm_atomic_rename call left the whole
# suite passing with zero coverage of the actual change. This is the
# regression test for that gap.
# ---------------------------------------------------------------------------

echo "== sm_activate_binary backup mechanism (hard link vs two-rename) =="

# The current implementation calls sm_atomic_rename exactly ONCE per
# sm_activate_binary run when a previous binary exists: only for the final
# staging-to-target swap, because the backup is a hard link (`ln`), not a
# rename. The two-rename form this replaced would call it TWICE (once to
# move the previous binary aside, once for the swap). Counting calls via
# the same shadowing technique used throughout this file turns that
# implementation difference into an assertion: reverting the `ln` call
# back to a second sm_atomic_rename makes this fail.
_sm_act_target6="$_sm_actdir/hardlink-plugin"
printf 'previous binary, backed up via a hard link, not a second rename\n' > "$_sm_act_target6"
chmod 0755 "$_sm_act_target6"
_sm_act_staging6="$_sm_act_target6.staging"
printf 'new binary\n' > "$_sm_tmp/act-hardlink-source"
sm_stage_binary "$_sm_tmp/act-hardlink-source" "$_sm_act_staging6" \
    || fail "staging succeeds ahead of the hard-link-backup test" "sm_stage_binary itself failed; see stderr above"

_sm_rename_call_count=0
sm_atomic_rename() {
    _sm_rename_call_count=$((_sm_rename_call_count + 1))
    mv -f "$1" "$2"
}
sm_activate_binary "$_sm_act_staging6" "$_sm_act_target6" \
    || fail "activation succeeds ahead of the hard-link-backup test" "sm_activate_binary itself failed; see stderr above"
# shellcheck disable=SC1090
. "$_sm_lib_dir/activate.sh"
assert_eq "sm_activate_binary calls sm_atomic_rename exactly once when a previous binary exists (the swap only; the backup is a hard link, not a second rename)" "1" "$_sm_rename_call_count"

# The hard link itself: $target.previous must be the SAME file (same
# device and inode) that was live at $target immediately BEFORE the
# swap, not merely a copy with the same bytes — that is what proves `ln`
# was actually used rather than `cp`. The inode is captured before
# sm_activate_binary runs at all, since capturing it (or the backup's
# inode) only AFTER activation compares two files that differ under
# every implementation regardless of whether a hard link or a copy made
# the backup: the target's inode has already changed to the newly
# swapped-in staging file by then. Comparing against a captured
# pre-swap inode is what a mutation replacing `ln` with `cp -p` (or with
# `false`, forcing the cp fallback) actually turns red.
_sm_act_target7="$_sm_actdir/hardlink-inode-plugin"
printf 'previous binary content for inode check\n' > "$_sm_act_target7"
chmod 0755 "$_sm_act_target7"
_sm_inode_before_swap=$(stat -c '%d:%i' "$_sm_act_target7" 2>/dev/null || stat -f '%d:%i' "$_sm_act_target7")
_sm_act_staging7="$_sm_act_target7.staging"
printf 'new binary content\n' > "$_sm_tmp/act-inode-source"
sm_stage_binary "$_sm_tmp/act-inode-source" "$_sm_act_staging7" \
    || fail "staging succeeds ahead of the hard-link-inode test" "sm_stage_binary itself failed; see stderr above"
sm_activate_binary "$_sm_act_staging7" "$_sm_act_target7" \
    || fail "activation succeeds ahead of the hard-link-inode test" "sm_activate_binary itself failed; see stderr above"
_sm_inode_backup=$(stat -c '%d:%i' "$_sm_act_target7.previous" 2>/dev/null || stat -f '%d:%i' "$_sm_act_target7.previous")
_sm_inode_target=$(stat -c '%d:%i' "$_sm_act_target7" 2>/dev/null || stat -f '%d:%i' "$_sm_act_target7")
assert_eq "the preserved backup is the SAME file (device+inode) that was live before the swap, proving it was hard-linked" "$_sm_inode_before_swap" "$_sm_inode_backup"
if [ "$_sm_inode_backup" = "$_sm_inode_target" ]; then
    fail "the preserved backup and the freshly activated target are different files" "they share an inode; the swap did not actually replace the target's content"
else
    pass "the preserved backup and the freshly activated target are different files after the swap"
fi
assert_eq "the preserved backup holds the OLD content" "previous binary content for inode check" "$(cat "$_sm_act_target7.previous")"

# ln failing (a filesystem that does not support hard links) must fall
# back to `cp -p`, exercised for real rather than only by hand: shadow the
# resolved `ln` itself so sm_stage_binary/sm_activate_binary's own
# sm_resolve_bin lookups still work for every OTHER tool, only `ln`
# fails.
_sm_fake_ln_dir="$_sm_tmp/fake-ln-bin"
mkdir -p "$_sm_fake_ln_dir"
cat > "$_sm_fake_ln_dir/ln" <<'FAKELN'
#!/bin/sh
exit 1
FAKELN
chmod 0755 "$_sm_fake_ln_dir/ln"
sm_resolve_bin() {
    if [ "$1" = "ln" ]; then
        printf '%s\n' "$_sm_fake_ln_dir/ln"
        return 0
    fi
    shift
    for _sm_candidate in "$@"; do
        if [ -x "$_sm_candidate" ]; then
            printf '%s\n' "$_sm_candidate"
            return 0
        fi
    done
    return 1
}
_sm_act_target8="$_sm_actdir/cp-fallback-plugin"
printf 'previous binary, must be backed up via cp -p since ln is unavailable\n' > "$_sm_act_target8"
chmod 0755 "$_sm_act_target8"
_sm_act_staging8="$_sm_act_target8.staging"
printf 'new binary via cp fallback\n' > "$_sm_tmp/act-cpfallback-source"
sm_stage_binary "$_sm_tmp/act-cpfallback-source" "$_sm_act_staging8" \
    || fail "staging succeeds ahead of the cp-fallback test" "sm_stage_binary itself failed; see stderr above"
out=$(sm_activate_binary "$_sm_act_staging8" "$_sm_act_target8" 2>&1)
status=$?
# shellcheck disable=SC1090
. "$_sm_lib_dir/common.sh"
assert_success "activation succeeds via the cp -p fallback when ln is unavailable" "$status"
assert_eq "the target serves the new content after a cp -p fallback activation" "new binary via cp fallback" "$(cat "$_sm_act_target8")"
assert_eq "the backup created via cp -p holds the OLD content" "previous binary, must be backed up via cp -p since ln is unavailable" "$(cat "$_sm_act_target8.previous")"

# ---------------------------------------------------------------------------
# sm_write_stamp: write-then-rename stamp writes, and the symlink/leftover-
# directory handling at both the stamp path and its temp path.
# ---------------------------------------------------------------------------

echo "== sm_write_stamp (write-then-rename stamp writes) =="

_sm_wsdir="$_sm_tmp/write-stamp"
mkdir -p "$_sm_wsdir"

# The ordinary case: content lands at the path.
_sm_ws_path="$_sm_wsdir/ok-stamp"
if sm_write_stamp "$_sm_ws_path" "amd64"; then
    pass "sm_write_stamp writes a fresh stamp"
else
    fail "sm_write_stamp writes a fresh stamp" "unexpected failure"
fi
assert_eq "the written stamp holds the given content" "amd64" "$(cat "$_sm_ws_path")"
assert_eq "no leftover .tmp file after a successful write" "" "$( [ -e "$_sm_ws_path.tmp" ] && echo present )"

# A symlinked temp path must never be written through: the actual defect
# this closes. A `.tmp` symlink pointing at some other real file, planted
# by anything with write access to the plugin directory (the same
# directory and writability as the stamp itself), must not have its
# target truncated and rewritten.
_sm_ws_dir3="$_sm_wsdir/diverted-tmp"
mkdir -p "$_sm_ws_dir3"
_sm_ws_outside3="$_sm_tmp/outside-target-for-symlink-tmp"
printf 'root-owned content that must never be touched\n' > "$_sm_ws_outside3"
ln -s "$_sm_ws_outside3" "$_sm_ws_dir3/stamp.tmp"
out=$(sm_write_stamp "$_sm_ws_dir3/stamp" "amd64" 2>&1)
status=$?
assert_failure "a symlinked temp path is refused, not written through" "$status"
assert_contains "the refusal names the symlink, not a downstream symptom" "$out" "symlink"
assert_eq "the symlink target is untouched by the refused write" "root-owned content that must never be touched" "$(cat "$_sm_ws_outside3")"
assert_eq "nothing is left at the stamp path itself" "" "$( [ -e "$_sm_ws_dir3/stamp" ] && echo present )"

# A symlinked DESTINATION must be refused too, for the same reason as the
# temp path: writing through it would rewrite whatever it points at.
_sm_ws_dir4="$_sm_wsdir/diverted-dest"
mkdir -p "$_sm_ws_dir4"
_sm_ws_outside4="$_sm_tmp/outside-target-for-symlink-dest"
printf 'root-owned content that must never be touched either\n' > "$_sm_ws_outside4"
ln -s "$_sm_ws_outside4" "$_sm_ws_dir4/stamp"
out=$(sm_write_stamp "$_sm_ws_dir4/stamp" "amd64" 2>&1)
status=$?
assert_failure "a symlinked destination is refused, not written through" "$status"
assert_contains "the refusal names the symlink, not a downstream symptom" "$out" "symlink"
assert_eq "the symlink target is untouched by the refused write" "root-owned content that must never be touched either" "$(cat "$_sm_ws_outside4")"

# A leftover DIRECTORY at the temp path, unlike a symlink, is not an
# attack: it is cleared so this write, and every one after it at the same
# path, can proceed. Before this fix, `rm -f` alone could not remove it
# and this failed forever with no way to recover.
_sm_ws_path5="$_sm_wsdir/leftover-dir-tmp"
mkdir -p "$_sm_ws_path5.tmp"
if sm_write_stamp "$_sm_ws_path5" "amd64"; then
    pass "a leftover directory at the temp path is cleared and the write proceeds"
else
    fail "a leftover directory at the temp path is cleared and the write proceeds" "unexpected failure"
fi
assert_eq "the stamp written after clearing a leftover temp directory holds the given content" "amd64" "$(cat "$_sm_ws_path5")"

# A HARD link at the temp path passes both the symlink check and the
# directory check above (it is an ordinary regular file, just with a
# second name), so it is a distinct case from either: the old in-place
# `printf > tmp` truncated and rewrote whatever the hard link's OTHER
# name pointed at, before the rename ever ran. Verified: hard-linking a
# victim file to the temp path and writing a stamp replaced the victim's
# content, at exit 0.
_sm_ws_dir7="$_sm_wsdir/hardlinked-tmp"
mkdir -p "$_sm_ws_dir7"
_sm_ws_victim7="$_sm_ws_dir7/victim-hardlinked"
printf 'victim content sharing an inode with the temp path, must survive\n' > "$_sm_ws_victim7"
ln "$_sm_ws_victim7" "$_sm_ws_dir7/stamp.tmp"
if sm_write_stamp "$_sm_ws_dir7/stamp" "amd64"; then
    pass "sm_write_stamp succeeds when a hard link occupies the temp path"
else
    fail "sm_write_stamp succeeds when a hard link occupies the temp path" "unexpected failure"
fi
assert_eq "the hard-linked victim's content is untouched by the write" "victim content sharing an inode with the temp path, must survive" "$(cat "$_sm_ws_victim7")"
assert_eq "the stamp itself still holds the given content, written to a fresh inode" "amd64" "$(cat "$_sm_ws_dir7/stamp")"

# A write that genuinely cannot create its temp file (permission denied,
# not a symlink or a directory) must never truncate an EXISTING stamp:
# the whole point of writing to a temp file and renaming is that a
# failure before the rename leaves the original untouched. Cannot be
# exercised as root, which ignores directory permissions entirely.
_sm_ws_path6="$_sm_wsdir/existing-stamp"
printf 'arm64\n' > "$_sm_ws_path6"
if [ "$(id -u)" -eq 0 ]; then
    skip "a write that cannot create its temp file leaves an existing stamp untouched" "running as root; directory permissions have no effect, cannot exercise this case here"
else
    chmod 0555 "$_sm_wsdir"
    out=$(sm_write_stamp "$_sm_ws_path6" "amd64" 2>&1)
    status=$?
    chmod 0755 "$_sm_wsdir"
    assert_failure "a write that cannot create its temp file is rejected" "$status"
    assert_eq "an existing stamp survives a failed write untouched, not truncated" "arm64" "$(cat "$_sm_ws_path6")"
fi

# ---------------------------------------------------------------------------
# sm_install_binary / sm_install_or_upgrade: the full fetch -> verify ->
# extract -> stage -> activate -> post-activate pipeline, driven end to
# end. Nothing here touches the network: sm_detect_arch and sm_download
# are shadowed (the same technique used throughout this file) so every
# scenario runs against locally synthesized tarballs and a locally
# written artifacts.lock.json instead.
#
# Before this section existed, nothing in this suite ever called
# sm_install_binary or sm_install_or_upgrade at all: restoring main's old
# install-core.sh (the naive `mv -f` onto the live target, verified
# against a fetched SHA256SUMS manifest instead of this lock) over this
# branch's version left the suite reporting the same pass count with zero
# failures, because the two functions these findings changed were never
# exercised at the point the change actually took effect.
# ---------------------------------------------------------------------------

# shellcheck disable=SC1090
. "$_sm_lib_dir/install-core.sh"

# ---------------------------------------------------------------------------
# sm_ensure_config_scaffold: refuses a symlink on every scaffold path
# instead of following it. The credential directory, the state directory,
# and every file inside them are chowned and chmoded as root on every
# install, upgrade, and preStart repair, and all of them live inside a
# tree the "fpp" system user (the user fppd and this plugin's own binary
# run as) can also write to. Before this fix, "fpp" planting a symlink at
# any of these paths turned the next repair into a root-run chown/chmod
# (or root-written file creation) at whatever the symlink pointed to; see
# sm_ensure_config_scaffold's header for the real-host evidence this
# closes. SM_INSTALL_OWNER is already set to the current user for the
# rest of this suite (see the stage-then-swap section above), so the
# success paths below exercise a real chown without requiring an "fpp"
# system user on the developer machine running them.
# ---------------------------------------------------------------------------

echo "== sm_ensure_config_scaffold (symlink refusal) =="

_sm_scafdir="$_sm_tmp/scaffold"
mkdir -p "$_sm_scafdir"

# sm_scaffold_file's staging root defaults to /etc/showmesh-fpp-plugin.stage,
# which this suite's unprivileged user cannot create. Point it at a tmp
# directory the suite itself controls instead; production code never sets
# this and gets the real, root-controlled path.
SM_SCAFFOLD_STAGE_ROOT="$_sm_scafdir/stage-root"
export SM_SCAFFOLD_STAGE_ROOT

# --- a symlinked directory target must be refused, not followed. ---
_sm_scaf_creddir_target="$_sm_scafdir/creddir-real-target"
mkdir -p "$_sm_scaf_creddir_target"
_sm_scaf_creddir_link="$_sm_scafdir/creddir-diverted"
ln -s "$_sm_scaf_creddir_target" "$_sm_scaf_creddir_link"
out=$(sm_scaffold_dir "$_sm_scaf_creddir_link" 0700 2>&1)
status=$?
assert_failure "sm_scaffold_dir refuses a symlinked directory path" "$status"
assert_contains "the refusal names the symlink" "$out" "symlink"
assert_eq "the symlink itself is untouched (still a symlink, not replaced)" "symlink" "$( [ -L "$_sm_scaf_creddir_link" ] && echo symlink )"

# --- a symlinked FILE destination, pointing at a real, pre-existing file
# outside the scaffold tree, must be refused: the chown/chmod that would
# otherwise follow it is exactly how "fpp" turns a planted symlink into
# root handing ownership of an arbitrary file to "fpp". Verified for real
# against a Debian container as root: a root:root 0644 file outside this
# tree ended up fpp:fpp 0600 after one repair pass before this fix. ---
_sm_scaf_victim="$_sm_scafdir/victim-existing.txt"
printf 'must never be touched\n' > "$_sm_scaf_victim"
chmod 0644 "$_sm_scaf_victim"
_sm_scaf_victim_mode_before=$(sm_current_mode "$_sm_scaf_victim")
_sm_scaf_file_link="$_sm_scafdir/file-diverted-to-victim"
ln -s "$_sm_scaf_victim" "$_sm_scaf_file_link"
out=$(sm_scaffold_file "$_sm_scaf_file_link" 0600 "{}" 2>&1)
status=$?
assert_failure "sm_scaffold_file refuses a symlinked destination pointing at an existing file" "$status"
assert_contains "the refusal names the symlink" "$out" "symlink"
assert_eq "the symlink target's content is untouched" "must never be touched" "$(cat "$_sm_scaf_victim")"
assert_eq "the symlink target's mode is untouched" "$_sm_scaf_victim_mode_before" "$(sm_current_mode "$_sm_scaf_victim")"

# --- a DANGLING symlink at a file path is the case `[ ! -e ]` alone
# cannot see (it dereferences and reports false), which used to let the
# creation redirect land at the symlink's target instead of refusing.
# Verified for real against a Debian container as root: this created a
# brand-new fpp:fpp 0600 file at the dangling symlink's target before
# this fix. ---
_sm_scaf_dangle_target="$_sm_scafdir/must-never-be-created.txt"
_sm_scaf_dangle_link="$_sm_scafdir/dangling-diverted"
ln -s "$_sm_scaf_dangle_target" "$_sm_scaf_dangle_link"
out=$(sm_scaffold_file "$_sm_scaf_dangle_link" 0600 "{}" 2>&1)
status=$?
assert_failure "sm_scaffold_file refuses a dangling symlinked destination" "$status"
assert_contains "the refusal names the symlink" "$out" "symlink"
assert_eq "nothing is created at the dangling symlink's target" "" "$( [ -e "$_sm_scaf_dangle_target" ] && echo present )"

# --- the ordinary case: no symlink anywhere, a fresh scaffold directory
# and file are created, owned, and moded correctly, and a second run is
# idempotent and does not disturb existing content. ---
_sm_scaf_ok_dir="$_sm_scafdir/ok-dir"
if sm_scaffold_dir "$_sm_scaf_ok_dir" 0700; then
    pass "sm_scaffold_dir succeeds for a fresh, non-symlinked directory"
else
    fail "sm_scaffold_dir succeeds for a fresh, non-symlinked directory" "unexpected failure"
fi
assert_eq "the fresh directory has the requested mode" "700" "$(sm_current_mode "$_sm_scaf_ok_dir")"

_sm_scaf_ok_file="$_sm_scaf_ok_dir/config.json"
if sm_scaffold_file "$_sm_scaf_ok_file" 0600 "{}"; then
    pass "sm_scaffold_file succeeds for a fresh, non-symlinked file"
else
    fail "sm_scaffold_file succeeds for a fresh, non-symlinked file" "unexpected failure"
fi
assert_eq "the fresh file holds the given default content" "{}" "$(cat "$_sm_scaf_ok_file")"
assert_eq "the fresh file has the requested mode" "600" "$(sm_current_mode "$_sm_scaf_ok_file")"

printf 'operator-provisioned content that must survive a re-run\n' > "$_sm_scaf_ok_file"
chmod 0600 "$_sm_scaf_ok_file"
if sm_scaffold_file "$_sm_scaf_ok_file" 0600 "{}"; then
    pass "sm_scaffold_file re-run on an existing file succeeds"
else
    fail "sm_scaffold_file re-run on an existing file succeeds" "unexpected failure"
fi
assert_eq "a re-run does not overwrite existing file content" "operator-provisioned content that must survive a re-run" "$(cat "$_sm_scaf_ok_file")"

# --- a symlinked PARENT path COMPONENT, not the leaf, must be refused
# too. sm_refuse_symlink alone only ever checked the leaf; `mkdir -p`
# follows a symlink at any parent component exactly as readily as it
# creates a missing one. Verified for real against a Debian container: a
# symlinked "plugindata" path component let a root scaffold create a
# directory, and every file scaffolded inside it, under /etc, owned by
# "fpp", at exit 0. ---
_sm_scaf_comp_real="$_sm_scafdir/component-real-target"
mkdir -p "$_sm_scaf_comp_real"
_sm_scaf_comp_link="$_sm_scafdir/component-diverted"
ln -s "$_sm_scaf_comp_real" "$_sm_scaf_comp_link"
_sm_scaf_comp_deep="$_sm_scaf_comp_link/nested/deeper"
out=$(sm_scaffold_dir "$_sm_scaf_comp_deep" 0700 2>&1)
status=$?
assert_failure "sm_scaffold_dir refuses a symlinked PARENT path component, not just the leaf" "$status"
assert_contains "the refusal names the symlink" "$out" "symlink"
assert_eq "nothing was created inside the symlinked component's real target" "" "$(ls -A "$_sm_scaf_comp_real" 2>/dev/null)"

# --- sm_ensure_config_scaffold itself, not only its two split helpers:
# this is the direct exercise of the function every install, upgrade, and
# preStart repair actually calls. sm_credential_dir/sm_state_dir are
# shadowed to point inside this suite's own tmp tree (their real targets
# are fixed, non-overridable absolute paths this suite must never touch),
# with a symlinked PARENT component planted ahead of the state directory
# to exercise the exact gap defect #2 above closes, end to end through
# the actual entrypoint rather than only through sm_scaffold_dir
# directly. ---
_sm_ecs_dir="$_sm_tmp/ensure-config-scaffold"
mkdir -p "$_sm_ecs_dir"
_sm_ecs_cred_target="$_sm_ecs_dir/credroot"
mkdir -p "$_sm_ecs_cred_target"
_sm_ecs_state_real="$_sm_ecs_dir/state-real-target"
mkdir -p "$_sm_ecs_state_real"
_sm_ecs_state_link="$_sm_ecs_dir/state-diverted"
ln -s "$_sm_ecs_state_real" "$_sm_ecs_state_link"
sm_credential_dir() { printf '%s\n' "$_sm_ecs_cred_target/creddir"; }
sm_state_dir() { printf '%s\n' "$_sm_ecs_state_link/nested/statedir"; }
out=$(sm_ensure_config_scaffold 2>&1)
status=$?
assert_failure "sm_ensure_config_scaffold itself refuses a symlinked path component under the state directory" "$status"
assert_eq "nothing was created inside the symlinked component's real target" "" "$(ls -A "$_sm_ecs_state_real" 2>/dev/null)"
# shellcheck disable=SC1090
. "$_sm_lib_dir/common.sh"

# --- a HARD link at a scaffold file's own path passes sm_refuse_symlink
# (it is an ordinary regular file, just with a second name), so a
# chown/chmod run in place against it would mutate whatever the other
# name points at. Verified for real against a Debian container: a root-
# owned 0666 file hard-linked to config.json became fpp:fpp 0600 after
# one scaffold pass, at exit 0. ---
_sm_scaf_hl_victim="$_sm_scafdir/hardlink-victim"
printf 'victim content sharing an inode with the scaffolded path, must survive\n' > "$_sm_scaf_hl_victim"
chmod 0666 "$_sm_scaf_hl_victim"
_sm_scaf_hl_victim_mode_before=$(sm_current_mode "$_sm_scaf_hl_victim")
_sm_scaf_hl_path="$_sm_scafdir/hardlinked-config.json"
ln "$_sm_scaf_hl_victim" "$_sm_scaf_hl_path"
if sm_scaffold_file "$_sm_scaf_hl_path" 0600 "{}"; then
    pass "sm_scaffold_file succeeds when a hard link occupies its own path"
else
    fail "sm_scaffold_file succeeds when a hard link occupies its own path" "unexpected failure"
fi
assert_eq "the hard-linked victim's content is untouched" "victim content sharing an inode with the scaffolded path, must survive" "$(cat "$_sm_scaf_hl_victim")"
assert_eq "the hard-linked victim's mode is untouched" "$_sm_scaf_hl_victim_mode_before" "$(sm_current_mode "$_sm_scaf_hl_victim")"
assert_eq "the scaffolded path itself now has the requested mode, in a fresh inode" "600" "$(sm_current_mode "$_sm_scaf_hl_path")"

# --- a DIRECTORY (or anything else that is not a regular file) at a
# scaffold file's own path must be refused, not chowned/chmoded and
# reported healthy. ---
_sm_scaf_dir_at_file_path="$_sm_scafdir/directory-at-file-path"
mkdir -p "$_sm_scaf_dir_at_file_path"
out=$(sm_scaffold_file "$_sm_scaf_dir_at_file_path" 0600 "{}" 2>&1)
status=$?
assert_failure "sm_scaffold_file refuses a directory at its own path" "$status"
assert_eq "the directory is left exactly as it was, not chowned/chmoded" "" "$(ls -A "$_sm_scaf_dir_at_file_path" 2>/dev/null)"

# --- the "refuses a directory" assertion above only checks a non-zero
# exit, which `cat` on a directory already supplies on its own with the
# regular-file guard removed; it does not actually prove the guard is
# load-bearing. A FIFO at the same path does: with no writer ever opening
# the other end, `cat` on a FIFO blocks forever, so a planted FIFO in the
# scaffold path turns the root boot-time repair into a hang instead of a
# refusal if the regular-file check is ever deleted. This is run in a
# separate process under a bounded timeout specifically so that if the
# guard regresses, this suite reports a failure instead of hanging
# itself. ---
_sm_mkfifo=$(command -v mkfifo 2>/dev/null || true)
_sm_timeout_bin=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
if [ -z "$_sm_mkfifo" ] || [ -z "$_sm_timeout_bin" ]; then
    skip "sm_scaffold_file refuses a FIFO at its own path rather than blocking on it" "mkfifo(1) or timeout(1)/gtimeout(1) not available"
else
    _sm_scaf_fifo_path="$_sm_scafdir/fifo-at-file-path"
    "$_sm_mkfifo" "$_sm_scaf_fifo_path"
    out=$("$_sm_timeout_bin" 5 sh -c '
        . "$1/common.sh"
        . "$1/install-core.sh"
        sm_scaffold_file "$2" 0600 "{}"
    ' _ "$_sm_lib_dir" "$_sm_scaf_fifo_path" 2>&1)
    status=$?
    if [ "$status" -eq 124 ]; then
        fail "sm_scaffold_file refuses a FIFO promptly rather than blocking on it" "timed out (rc=124) reading the FIFO; the regular-file guard did not stop this"
    else
        assert_failure "sm_scaffold_file refuses a FIFO at its own path rather than blocking on it" "$status"
    fi
    assert_eq "the FIFO is left exactly as it was, not chowned/chmoded" "fifo" "$( [ -p "$_sm_scaf_fifo_path" ] && echo fifo )"
fi

echo "== staging root location invariant =="

# The suite exports SM_SCAFFOLD_STAGE_ROOT at the top of this section and
# never unsets it, so nothing above ever exercises the real default this
# repository ships. This is the one place that does: a subshell resolves
# sm_scaffold_stage_root() with the override unset, so what it prints is
# actually the default a real install would use, not the tmp path this
# suite substitutes for it everywhere else.
_sm_stage_default=$(unset SM_SCAFFOLD_STAGE_ROOT; sm_scaffold_stage_root)
_sm_cred_default=$(sm_credential_dir)
_sm_state_default=$(sm_state_dir)

# The whole point of the private staging root (see common.sh's header on
# sm_scaffold_stage_root) is that neither sm_credential_dir nor
# sm_state_dir, both fpp-owned, can be its parent: a descendant of either
# would inherit an fpp-writable ancestor able to replace the staging
# directory wholesale regardless of its own mode.
case "$_sm_stage_default" in
    "$_sm_cred_default"/*|"$_sm_cred_default")
        fail "the default staging root is not a descendant of the credential directory" "stage root: $_sm_stage_default, credential dir: $_sm_cred_default"
        ;;
    *)
        pass "the default staging root is not a descendant of the credential directory"
        ;;
esac
case "$_sm_stage_default" in
    "$_sm_state_default"/*|"$_sm_state_default")
        fail "the default staging root is not a descendant of the state directory" "stage root: $_sm_stage_default, state dir: $_sm_state_default"
        ;;
    *)
        pass "the default staging root is not a descendant of the state directory"
        ;;
esac
assert_eq "the default staging root is the documented /etc path" "/etc/showmesh-fpp-plugin.stage" "$_sm_stage_default"

echo "== sm_ensure_scaffold_stage_dir ownership reassertion =="

# sm_mkdir_p_refuse_symlinks only CREATES a missing directory; it never
# touches one that already exists. Before this fix, that meant a staging
# root pre-planted by "fpp" (the only non-root actor able to reach this
# path's parent before the directory exists) kept whatever ownership it
# already had: sm_ensure_scaffold_stage_dir chmoded it 0700 and reported
# success without ever reasserting ownership. Simulated here by
# pre-creating the staging root before calling the function, then proving
# a chown actually runs against it regardless: shadowing chown to log its
# invocations, the same wrapper technique the stage-then-swap TOCTOU proof
# above uses, rather than trying to observe a real ownership change this
# suite's single unprivileged user cannot produce.
_sm_reassert_dir="$_sm_tmp/stage-reassert"
mkdir -p "$_sm_reassert_dir/fake-bin"
_sm_reassert_log="$_sm_reassert_dir/chown-calls.log"
: > "$_sm_reassert_log"
cat > "$_sm_reassert_dir/fake-bin/chown" <<FAKE
#!/bin/sh
printf '%s\n' "\$*" >> "$_sm_reassert_log"
exec chown "\$@"
FAKE
chmod 0755 "$_sm_reassert_dir/fake-bin/chown"

sm_resolve_bin() {
    case "$1" in
        chown) printf '%s\n' "$_sm_reassert_dir/fake-bin/chown"; return 0 ;;
    esac
    _sm_reassert_name="$1"
    shift
    for _sm_reassert_candidate in "$@"; do
        if [ -x "$_sm_reassert_candidate" ]; then
            printf '%s\n' "$_sm_reassert_candidate"
            return 0
        fi
    done
    sm_log_err "required tool not found: $_sm_reassert_name (checked: $*)"
    return 1
}

_sm_preexisting_stage="$_sm_scafdir/preexisting-stage-root"
mkdir -p "$_sm_preexisting_stage"
chmod 0755 "$_sm_preexisting_stage"

# Run in-process, not in a forked `sh -c`: a child process would re-source
# common.sh fresh and get the REAL sm_resolve_bin back, silently defeating
# the shadow just installed above.
_sm_reassert_saved_root="${SM_SCAFFOLD_STAGE_ROOT-}"
SM_SCAFFOLD_STAGE_ROOT="$_sm_preexisting_stage"
export SM_SCAFFOLD_STAGE_ROOT
sm_ensure_scaffold_stage_dir
status=$?
SM_SCAFFOLD_STAGE_ROOT="$_sm_reassert_saved_root"
export SM_SCAFFOLD_STAGE_ROOT
# shellcheck disable=SC1090
. "$_sm_lib_dir/common.sh"

assert_success "sm_ensure_scaffold_stage_dir succeeds against a pre-existing staging root" "$status"
if grep -F "$_sm_preexisting_stage" "$_sm_reassert_log" >/dev/null 2>&1; then
    pass "a pre-existing staging root still gets its ownership reasserted, not just chmoded"
else
    fail "a pre-existing staging root still gets its ownership reasserted, not just chmoded" "chown log is empty for $_sm_preexisting_stage:
$(cat "$_sm_reassert_log")"
fi

echo "== no /proc dependency remains =="

# sm_scaffold_activate_cross_device (the EXDEV fallback that set
# attributes through /proc/self/fd rather than by path) was dead code:
# GNU mv already catches EXDEV internally and falls back to a copy for a
# regular file, so the fallback's own marker never printed even under a
# forced, confirmed EXDEV. It has been deleted along with every /proc
# reference that came with it. This asserts the deletion was total,
# rather than only removing the function's own definition and leaving a
# caller or a comment still depending on procfs being mounted.
_sm_proc_hits=$(grep -rl '/proc' "$_sm_lib_dir" 2>/dev/null || true)
if [ -z "$_sm_proc_hits" ]; then
    pass "no file under scripts/lib references /proc; the cross-device fallback's procfs dependency is gone, not just its function"
else
    fail "no file under scripts/lib references /proc; the cross-device fallback's procfs dependency is gone, not just its function" "$_sm_proc_hits"
fi

echo "== sm_create_new_file (noclobber) =="

# The shell's own noclobber option (`set -C`) is what makes the existence
# check and the file creation one kernel-level operation; nothing in this
# suite exercised that specifically before. A pre-existing regular file
# at the target must be refused outright, never truncated and rewritten,
# which is exactly what a plain `>` redirect without noclobber would do.
_sm_ncdir="$_sm_tmp/create-new-file"
mkdir -p "$_sm_ncdir"
_sm_nc_path="$_sm_ncdir/already-there"
printf 'must survive untouched\n' > "$_sm_nc_path"
out=$(sm_create_new_file "$_sm_nc_path" "new content that must never land here" 2>&1)
status=$?
assert_failure "sm_create_new_file refuses when a regular file already exists at the target" "$status"
assert_eq "the pre-existing file's content is untouched, not truncated by noclobber's own open" "must survive untouched" "$(cat "$_sm_nc_path")"

_sm_nc_fresh="$_sm_ncdir/fresh"
if sm_create_new_file "$_sm_nc_fresh" "brand new content"; then
    pass "sm_create_new_file succeeds for a path nothing occupies yet"
else
    fail "sm_create_new_file succeeds for a path nothing occupies yet" "unexpected failure"
fi
assert_eq "the newly created file holds the given content" "brand new content" "$(cat "$_sm_nc_fresh")"

echo "== install/upgrade pipeline (sm_install_binary, sm_install_or_upgrade) =="

# fetch.sh reads $SHOWMESH_PLUGIN_ARTIFACT_BASE_URL unguarded, relying on
# ordinary POSIX sh's default-unset-is-empty behaviour; this suite runs
# under `set -u`, which fpp_install.sh/fpp_upgrade.sh themselves do not,
# so it must give the variable a defined (empty) value itself before
# exercising anything that reads it, rather than the production scripts
# needing to.
SHOWMESH_PLUGIN_ARTIFACT_BASE_URL="${SHOWMESH_PLUGIN_ARTIFACT_BASE_URL:-}"
export SHOWMESH_PLUGIN_ARTIFACT_BASE_URL

make_tarball() {
    # $1 = output tarball path, $2 = the binary's content
    _sm_mt_dir=$(mktemp -d)
    printf '%s' "$2" > "$_sm_mt_dir/showmesh-fpp-plugin"
    (cd "$_sm_mt_dir" && tar -czf "$1" showmesh-fpp-plugin)
    rm -rf "$_sm_mt_dir"
}

# URL-aware download stub used throughout the install pipeline section
# below. A mutation swapping in the pre-lock install-core.sh (which fetches
# BOTH the tarball and a same-origin SHA256SUMS manifest from the same base
# URL) must not have its manifest request handed the tarball's own gzip
# bytes: a URL-oblivious stub that served the tarball for every request
# made that mutation die on binary input inside awk before reaching
# anything behaviorally interesting, which is worthless as acceptance
# evidence. This serves the tarball for a URL ending in its own name, and a
# real, self-consistent SHA256SUMS manifest for any other URL requested
# against the same base; current code never requests the second URL at
# all, so this is a no-op for it, and only matters for that mutation check.
sm_download_serve_tarball_and_sums() {
    # $1 = requested URL, $2 = destination path, $3 = local tarball
    # fixture, $4 = tarball name as it appears in the URL
    case "$1" in
        */"$4")
            cp "$3" "$2"
            ;;
        *)
            printf '%s  %s\n' "$(sha256sum "$3" | awk '{print $1}')" "$4" > "$2"
            ;;
    esac
}

make_install_lock() {
    # $1 = lock path, $2 = version, $3 = exact tarball filename, $4 = sha256
    cat > "$1" <<LOCKJSON
{
  "version": "$2",
  "artifacts": [
    { "filename": "$3", "kind": "go-helper", "architecture": "amd64", "sha256": "$4" }
  ]
}
LOCKJSON
}

_sm_ipdir="$_sm_tmp/install-pipeline"
mkdir -p "$_sm_ipdir"
_sm_ip_version="9.9.9"
_sm_ip_tarball_name=$(sm_artifact_tarball_name "$_sm_ip_version" "amd64")
_sm_ip_fppdir_unused="$_sm_ipdir/fppdir-unused"

sm_detect_arch() { echo amd64; }

# --- baseline: a fresh install with a matching lock succeeds end to end ---
_sm_ip_fresh="$_sm_ipdir/fresh"
mkdir -p "$_sm_ip_fresh"
make_tarball "$_sm_tmp/fresh-good.tar.gz" "fresh install binary content"
_sm_ip_fresh_hash=$(sha256sum "$_sm_tmp/fresh-good.tar.gz" | awk '{print $1}')
make_install_lock "$_sm_ip_fresh/artifacts.lock.json" "$_sm_ip_version" "$_sm_ip_tarball_name" "$_sm_ip_fresh_hash"
sm_download() { sm_download_serve_tarball_and_sums "$1" "$2" "$_sm_tmp/fresh-good.tar.gz" "$_sm_ip_tarball_name"; }

if sm_install_binary "$_sm_ip_fresh" "$_sm_ip_fppdir_unused" "$_sm_ip_version"; then
    pass "a fresh sm_install_binary run with a matching lock succeeds end to end"
else
    fail "a fresh sm_install_binary run with a matching lock succeeds end to end" "unexpected failure"
fi
assert_eq "the installed binary's content matches the served tarball" "fresh install binary content" "$(cat "$_sm_ip_fresh/showmesh-fpp-plugin")"
assert_eq "the installed binary is executable (0755)" "755" "$(sm_current_mode "$_sm_ip_fresh/showmesh-fpp-plugin")"
assert_eq "the arch stamp is written" "amd64" "$(cat "$_sm_ip_fresh/.installed-arch")"
assert_eq "no installed-version stamp is written (removed: nothing in this repository ever reads it back)" "" "$( [ -e "$_sm_ip_fresh/.installed-version" ] && echo present )"
assert_eq "no staging file is left behind after a successful sm_install_binary run" "" "$( [ -e "$_sm_ip_fresh/showmesh-fpp-plugin.staging" ] && echo present )"
assert_eq "no backup file is left behind after a successful fresh sm_install_binary run" "" "$( [ -e "$_sm_ip_fresh/showmesh-fpp-plugin.previous" ] && echo present )"

# --- scenario 1: a lock hash that disagrees with the served bytes must
# refuse the install, and the previous binary must survive byte-identical
# and executable. ---
_sm_ip_mismatch="$_sm_ipdir/checksum-mismatch"
mkdir -p "$_sm_ip_mismatch"
printf 'existing previous binary, must survive untouched\n' > "$_sm_ip_mismatch/showmesh-fpp-plugin"
chmod 0755 "$_sm_ip_mismatch/showmesh-fpp-plugin"
_sm_ip_prev_hash_before=$(sha256sum "$_sm_ip_mismatch/showmesh-fpp-plugin" | awk '{print $1}')

make_tarball "$_sm_tmp/mismatch.tar.gz" "bytes that do not match what the lock expects"
_sm_ip_wrong_hash=$(python3 -c "print('f' * 64)")
make_install_lock "$_sm_ip_mismatch/artifacts.lock.json" "$_sm_ip_version" "$_sm_ip_tarball_name" "$_sm_ip_wrong_hash"
sm_download() { sm_download_serve_tarball_and_sums "$1" "$2" "$_sm_tmp/mismatch.tar.gz" "$_sm_ip_tarball_name"; }

out=$(sm_install_binary "$_sm_ip_mismatch" "$_sm_ip_fppdir_unused" "$_sm_ip_version" 2>&1)
status=$?
assert_failure "a lock hash that disagrees with the served bytes refuses the install" "$status"
assert_contains "the refusal names checksum verification" "$out" "checksum verification"
_sm_ip_prev_hash_after=$(sha256sum "$_sm_ip_mismatch/showmesh-fpp-plugin" | awk '{print $1}')
assert_eq "the previous binary is byte-identical after a refused checksum mismatch" "$_sm_ip_prev_hash_before" "$_sm_ip_prev_hash_after"
if [ -x "$_sm_ip_mismatch/showmesh-fpp-plugin" ]; then
    pass "the previous binary remains executable after a refused checksum mismatch"
else
    fail "the previous binary remains executable after a refused checksum mismatch" "lost its executable bit"
fi
assert_eq "no staging file is left behind after a refused checksum mismatch" "" "$( [ -e "$_sm_ip_mismatch/showmesh-fpp-plugin.staging" ] && echo present )"

# --- scenario 2: a fresh install whose swap fails must leave nothing
# half-installed. ---
_sm_ip_swapfail="$_sm_ipdir/swap-fail"
mkdir -p "$_sm_ip_swapfail"
make_tarball "$_sm_tmp/swapfail-good.tar.gz" "binary that must never go live"
_sm_ip_swapfail_hash=$(sha256sum "$_sm_tmp/swapfail-good.tar.gz" | awk '{print $1}')
make_install_lock "$_sm_ip_swapfail/artifacts.lock.json" "$_sm_ip_version" "$_sm_ip_tarball_name" "$_sm_ip_swapfail_hash"
sm_download() { sm_download_serve_tarball_and_sums "$1" "$2" "$_sm_tmp/swapfail-good.tar.gz" "$_sm_ip_tarball_name"; }
# Let staging succeed (sm_atomic_rename is also the rename sm_stage_binary
# uses to move the extracted binary into staging) and fail only the
# actual swap onto the target, by destination suffix, so this scenario
# reaches the swap it is named for instead of dying one step earlier.
sm_atomic_rename() {
    case "$2" in
        *.staging) mv -f "$1" "$2" ;;
        *) return 1 ;;
    esac
}

out=$(sm_install_binary "$_sm_ip_swapfail" "$_sm_ip_fppdir_unused" "$_sm_ip_version" 2>&1)
status=$?
# shellcheck disable=SC1090
. "$_sm_lib_dir/activate.sh"
assert_failure "a fresh install whose swap fails is refused" "$status"
assert_contains "the failure actually reached the swap step, not an earlier staging failure" "$out" "could not rename staged binary"
assert_eq "no target binary exists after a failed fresh-install swap" "" "$( [ -e "$_sm_ip_swapfail/showmesh-fpp-plugin" ] && echo present )"
assert_eq "no staging file is left behind after a failed fresh-install swap" "" "$( [ -e "$_sm_ip_swapfail/showmesh-fpp-plugin.staging" ] && echo present )"
assert_eq "no arch stamp is written after a failed fresh-install swap" "" "$( [ -e "$_sm_ip_swapfail/.installed-arch" ] && echo present )"
assert_eq "no backup file is left behind after a failed fresh-install swap" "" "$( [ -e "$_sm_ip_swapfail/showmesh-fpp-plugin.previous" ] && echo present )"

# --- scenario 3: a post-activation failure (mode re-verification of the
# live target, the last check before the transaction commits) must roll
# the live binary back to what was running before this install started,
# not leave the new, unverified binary live while reporting the install
# as failed. sm_verify_mode is called twice per run now: once for real,
# inside sm_stage_binary, and once again by sm_install_binary itself
# after the swap; only the second call is forced to fail here, by call
# count, so staging still succeeds and this scenario actually reaches
# the post-swap check it is named for. ---
_sm_ip_rollback="$_sm_ipdir/post-activation-rollback"
mkdir -p "$_sm_ip_rollback"
printf 'old binary, must come back after rollback\n' > "$_sm_ip_rollback/showmesh-fpp-plugin"
chmod 0755 "$_sm_ip_rollback/showmesh-fpp-plugin"
_sm_ip_rollback_prev_hash=$(sha256sum "$_sm_ip_rollback/showmesh-fpp-plugin" | awk '{print $1}')

make_tarball "$_sm_tmp/rollback-new.tar.gz" "new binary that activates then must be rolled back"
_sm_ip_rollback_hash=$(sha256sum "$_sm_tmp/rollback-new.tar.gz" | awk '{print $1}')
make_install_lock "$_sm_ip_rollback/artifacts.lock.json" "$_sm_ip_version" "$_sm_ip_tarball_name" "$_sm_ip_rollback_hash"
sm_download() { sm_download_serve_tarball_and_sums "$1" "$2" "$_sm_tmp/rollback-new.tar.gz" "$_sm_ip_tarball_name"; }
_sm_mv_calls=0
sm_verify_mode() {
    _sm_mv_calls=$((_sm_mv_calls + 1))
    if [ "$_sm_mv_calls" -ge 2 ]; then
        sm_log_err "test-injected post-activation mode verification failure"
        return 1
    fi
    [ "$(sm_current_mode "$1")" = "$2" ]
}

out=$(sm_install_binary "$_sm_ip_rollback" "$_sm_ip_fppdir_unused" "$_sm_ip_version" 2>&1)
status=$?
# shellcheck disable=SC1090
. "$_sm_lib_dir/common.sh"
assert_failure "a post-activation mode-verification failure is refused" "$status"
_sm_ip_rollback_after_hash=$(sha256sum "$_sm_ip_rollback/showmesh-fpp-plugin" | awk '{print $1}')
assert_eq "the previous binary's content is restored after a post-activation rollback" "$_sm_ip_rollback_prev_hash" "$_sm_ip_rollback_after_hash"
if [ -x "$_sm_ip_rollback/showmesh-fpp-plugin" ]; then
    pass "the rolled-back binary remains executable"
else
    fail "the rolled-back binary remains executable" "lost its executable bit"
fi
assert_eq "no backup file remains once the post-activation rollback completes" "" "$( [ -e "$_sm_ip_rollback/showmesh-fpp-plugin.previous" ] && echo present )"
assert_eq "no arch stamp is written when the post-activation mode check fails before the transaction commits" "" "$( [ -e "$_sm_ip_rollback/.installed-arch" ] && echo present )"

# --- scenario 4: the same post-activation mode-verification failure on a
# FRESH install (no previous binary at all) must remove the unverified
# target rather than attempt a rollback that has nothing to roll back
# to. Before the rollback fix this replaced, sm_activate_rollback refused
# with "no preserved previous binary" and returned failure while the
# new, unverified binary stayed live and executable at the target, a
# status-1 report that did not match what was actually on disk. ---
_sm_ip_freshfail="$_sm_ipdir/fresh-post-activation-failure"
mkdir -p "$_sm_ip_freshfail"
make_tarball "$_sm_tmp/freshfail-new.tar.gz" "new binary on a fresh install that must not survive a post-activation failure"
_sm_ip_freshfail_hash=$(sha256sum "$_sm_tmp/freshfail-new.tar.gz" | awk '{print $1}')
make_install_lock "$_sm_ip_freshfail/artifacts.lock.json" "$_sm_ip_version" "$_sm_ip_tarball_name" "$_sm_ip_freshfail_hash"
sm_download() { sm_download_serve_tarball_and_sums "$1" "$2" "$_sm_tmp/freshfail-new.tar.gz" "$_sm_ip_tarball_name"; }
_sm_mv_calls=0
sm_verify_mode() {
    _sm_mv_calls=$((_sm_mv_calls + 1))
    if [ "$_sm_mv_calls" -ge 2 ]; then
        sm_log_err "test-injected post-activation mode verification failure"
        return 1
    fi
    [ "$(sm_current_mode "$1")" = "$2" ]
}

out=$(sm_install_binary "$_sm_ip_freshfail" "$_sm_ip_fppdir_unused" "$_sm_ip_version" 2>&1)
status=$?
# shellcheck disable=SC1090
. "$_sm_lib_dir/common.sh"
assert_failure "a post-activation mode-verification failure on a fresh install (no previous binary) is refused" "$status"
assert_eq "no target binary is left live after a fresh install's post-activation failure" "" "$( [ -e "$_sm_ip_freshfail/showmesh-fpp-plugin" ] && echo present )"
assert_eq "no staging file is left behind either" "" "$( [ -e "$_sm_ip_freshfail/showmesh-fpp-plugin.staging" ] && echo present )"
assert_contains "the refusal names having nothing to roll back to, not a generic rollback failure" "$out" "no previous binary to roll back to"

# --- scenario 5: a failed arch-stamp write AFTER the transaction has
# committed must NOT roll the binary back. The mode re-verification
# above already confirmed the new binary is good, and sm_activate_commit
# has already discarded the backup by the time stamps are written; a
# stamp failing to record afterward is reported as a failure, but the
# already-good binary that is live stays live. Regression test for the
# bug this closes: an earlier version wrote stamps BEFORE the commit and
# rolled the binary back on a failed stamp write, restoring the previous
# binary while leaving the arch stamp already rewritten for the version
# that got discarded — stamps describing a binary that was never kept. ---
_sm_ip_stampfail="$_sm_ipdir/stamp-write-failure"
mkdir -p "$_sm_ip_stampfail"
printf 'old binary; only the STAMP write fails in this scenario, not activation\n' > "$_sm_ip_stampfail/showmesh-fpp-plugin"
chmod 0755 "$_sm_ip_stampfail/showmesh-fpp-plugin"
make_tarball "$_sm_tmp/stampfail-new.tar.gz" "new binary that activates and stays live despite a failed stamp write"
_sm_ip_stampfail_hash=$(sha256sum "$_sm_tmp/stampfail-new.tar.gz" | awk '{print $1}')
make_install_lock "$_sm_ip_stampfail/artifacts.lock.json" "$_sm_ip_version" "$_sm_ip_tarball_name" "$_sm_ip_stampfail_hash"
sm_download() { sm_download_serve_tarball_and_sums "$1" "$2" "$_sm_tmp/stampfail-new.tar.gz" "$_sm_ip_tarball_name"; }
# A directory sitting where the arch stamp must be written makes the
# write fail portably, on any filesystem or user, without touching
# sm_verify_mode, which must pass for real in this scenario.
mkdir -p "$_sm_ip_stampfail/.installed-arch"

out=$(sm_install_binary "$_sm_ip_stampfail" "$_sm_ip_fppdir_unused" "$_sm_ip_version" 2>&1)
status=$?
assert_failure "a failed arch-stamp write after the transaction commits is still reported as a failure" "$status"
assert_contains "the failure names the architecture stamp" "$out" "architecture stamp"
assert_eq "the NEW binary stays live despite the failed stamp write, since activation had already committed" "new binary that activates and stays live despite a failed stamp write" "$(cat "$_sm_ip_stampfail/showmesh-fpp-plugin")"
assert_eq "no backup file remains: the transaction had already committed before the stamp write was attempted" "" "$( [ -e "$_sm_ip_stampfail/showmesh-fpp-plugin.previous" ] && echo present )"

# --- scenario 6: a stamp write that fails with NOTHING already at the
# stamp path (a genuine write failure, e.g. a full disk; shadowed here
# rather than manufactured, since the directory-exists trick scenario 5
# uses deliberately leaves something at the path and so cannot exercise
# this case) must not leave the architecture guard permanently blind. A
# missing stamp reads as "installed by a version of this repository
# before the stamp existed" (see sm_arch_repair_reason), which is the
# WRONG reading for a stamp write that failed on this run: verified,
# before this fix, with no stamp on disk and detection disagreeing with
# the binary, sm_arch_repair_reason returned no reason and preStart would
# have exited 0. sm_write_stamp_or_sentinel closes this by leaving an
# EMPTY stamp behind on a failed write when nothing was there before,
# which sm_arch_repair_reason already treats as needing repair. ---
_sm_ip_sentinel="$_sm_ipdir/stamp-write-failure-no-prior-stamp"
mkdir -p "$_sm_ip_sentinel"
make_tarball "$_sm_tmp/sentinel-new.tar.gz" "new binary that activates despite a failed arch-stamp write with nothing there before"
_sm_ip_sentinel_hash=$(sha256sum "$_sm_tmp/sentinel-new.tar.gz" | awk '{print $1}')
make_install_lock "$_sm_ip_sentinel/artifacts.lock.json" "$_sm_ip_version" "$_sm_ip_tarball_name" "$_sm_ip_sentinel_hash"
sm_download() { sm_download_serve_tarball_and_sums "$1" "$2" "$_sm_tmp/sentinel-new.tar.gz" "$_sm_ip_tarball_name"; }
sm_write_stamp() { sm_log_err "test-injected stamp write failure"; return 1; }

out=$(sm_install_binary "$_sm_ip_sentinel" "$_sm_ip_fppdir_unused" "$_sm_ip_version" 2>&1)
status=$?
# shellcheck disable=SC1090
. "$_sm_lib_dir/activate.sh"
assert_failure "a stamp write failing with nothing at the path beforehand is still reported as a failure" "$status"
assert_eq "the NEW binary stays live despite the failed stamp write" "new binary that activates despite a failed arch-stamp write with nothing there before" "$(cat "$_sm_ip_sentinel/showmesh-fpp-plugin")"
if [ -f "$_sm_ip_sentinel/.installed-arch" ] && [ -z "$(cat "$_sm_ip_sentinel/.installed-arch")" ]; then
    pass "an empty sentinel stamp is left behind after a failed write with nothing there before"
else
    fail "an empty sentinel stamp is left behind after a failed write with nothing there before" "got: $( [ -e "$_sm_ip_sentinel/.installed-arch" ] && cat "$_sm_ip_sentinel/.installed-arch" || echo '(no file at all)')"
fi
# shellcheck disable=SC1090
. "$_sm_lib_dir/arch.sh"
out=$(sm_arch_repair_reason "$_sm_ip_sentinel" "$_sm_ip_fppdir_unused")
if [ -n "$out" ]; then
    pass "sm_arch_repair_reason treats the sentinel left by a failed first stamp write as needing repair"
else
    fail "sm_arch_repair_reason treats the sentinel left by a failed first stamp write as needing repair" "expected non-empty repair reason, got none"
fi

unset -f sm_detect_arch sm_download

# --- sm_install_or_upgrade: the orchestration around sm_install_binary
# (command-script validation, the config scaffold, the restart note),
# with sm_ensure_config_scaffold shadowed so this suite never touches
# /etc or /home/fpp on the machine running it; see the function's own
# comment in install-core.sh for why those are real, fixed system paths. ---

echo "== sm_install_or_upgrade orchestration =="

sm_detect_arch() { echo amd64; }
sm_ensure_config_scaffold() { sm_log "test stub: scaffold skipped"; return 0; }

_sm_orch_ok="$_sm_ipdir/orch-ok"
mkdir -p "$_sm_orch_ok/commands"
cat > "$_sm_orch_ok/commands/descriptions.json" <<'JSON'
[ { "name": "ShowMeshRunMacro", "script": "run-macro.sh", "args": [] } ]
JSON
printf '#!/bin/sh\ntrue\n' > "$_sm_orch_ok/commands/run-macro.sh"
chmod 0755 "$_sm_orch_ok/commands/run-macro.sh"
make_tarball "$_sm_tmp/orch-good.tar.gz" "orchestration success binary"
_sm_orch_hash=$(sha256sum "$_sm_tmp/orch-good.tar.gz" | awk '{print $1}')
make_install_lock "$_sm_orch_ok/artifacts.lock.json" "$_sm_ip_version" "$_sm_ip_tarball_name" "$_sm_orch_hash"
sm_download() { sm_download_serve_tarball_and_sums "$1" "$2" "$_sm_tmp/orch-good.tar.gz" "$_sm_ip_tarball_name"; }

out=$(sm_install_or_upgrade "$_sm_ip_fppdir_unused" "$_sm_orch_ok" "$_sm_ip_version" 2>&1)
status=$?
assert_success "sm_install_or_upgrade succeeds end to end with the scaffold stubbed" "$status"
assert_contains "sm_install_or_upgrade logs the manual-restart note on success" "$out" "restart"
assert_eq "sm_install_or_upgrade actually installed the binary" "orchestration success binary" "$(cat "$_sm_orch_ok/showmesh-fpp-plugin")"

# Command-script validation runs first and entirely locally: a missing
# script must block everything after it, including the config scaffold.
_sm_orch_badcmd="$_sm_ipdir/orch-badcmd"
mkdir -p "$_sm_orch_badcmd/commands"
cat > "$_sm_orch_badcmd/commands/descriptions.json" <<'JSON'
[ { "name": "ShowMeshRunMacro", "script": "run-macro.sh", "args": [] } ]
JSON
# run-macro.sh is deliberately never created here.
_sm_scaffold_called=0
sm_ensure_config_scaffold() { _sm_scaffold_called=1; return 0; }
out=$(sm_install_or_upgrade "$_sm_ip_fppdir_unused" "$_sm_orch_badcmd" "$_sm_ip_version" 2>&1)
status=$?
assert_failure "sm_install_or_upgrade refuses when command-script validation fails" "$status"
assert_eq "sm_install_or_upgrade never reaches the config scaffold when command validation fails" "0" "$_sm_scaffold_called"
unset _sm_scaffold_called

# A failed config scaffold step must block the binary install that
# follows it.
_sm_orch_badscaffold="$_sm_ipdir/orch-badscaffold"
mkdir -p "$_sm_orch_badscaffold/commands"
cp "$_sm_orch_ok/commands/descriptions.json" "$_sm_orch_badscaffold/commands/"
cp "$_sm_orch_ok/commands/run-macro.sh" "$_sm_orch_badscaffold/commands/"
make_install_lock "$_sm_orch_badscaffold/artifacts.lock.json" "$_sm_ip_version" "$_sm_ip_tarball_name" "$_sm_orch_hash"
sm_ensure_config_scaffold() { return 1; }
out=$(sm_install_or_upgrade "$_sm_ip_fppdir_unused" "$_sm_orch_badscaffold" "$_sm_ip_version" 2>&1)
status=$?
assert_failure "sm_install_or_upgrade refuses when the config scaffold step fails" "$status"
assert_eq "no binary is installed when the config scaffold step failed" "" "$( [ -e "$_sm_orch_badscaffold/showmesh-fpp-plugin" ] && echo present )"

# shellcheck disable=SC1090
. "$_sm_lib_dir/install-core.sh"
unset -f sm_detect_arch sm_download

# ---------------------------------------------------------------------------
# Repository hygiene: the executable bits everything else depends on
# ---------------------------------------------------------------------------
#
# FPP gates on [ -x <script> ] for every one of its own entrypoint hooks,
# silently skipping anything committed without the bit — including
# fpp_install.sh itself, which means a lost bit on THAT one file means
# sm_validate_command_scripts (and everything else in this suite) never
# even runs on a real host. Nothing else in this repository checks git's
# recorded mode, and there is no CI here to catch it either, so this suite
# is the only thing that does.

echo "== repository hygiene =="

_sm_git=$(command -v git 2>/dev/null || true)
if [ -z "$_sm_git" ]; then
    fail "git is available to check recorded executable bits" "git not found; cannot verify committed file modes"
else
    for _sm_entrypoint in \
        scripts/fpp_install.sh \
        scripts/fpp_upgrade.sh \
        scripts/fpp_uninstall.sh \
        scripts/preStart.sh \
        commands/run-macro.sh \
        test/run_tests.sh
    do
        _sm_recorded_mode=$(cd "$_sm_repo_dir" && "$_sm_git" ls-files -s -- "$_sm_entrypoint" 2>/dev/null | awk '{print $1}')
        assert_eq "$_sm_entrypoint is committed executable (100755)" "100755" "$_sm_recorded_mode"
    done

    # Discovered with `find`, the same way the hygiene scan below finds
    # its own runtime script surface, rather than a hand-maintained list:
    # a hardcoded list here left a newly added lib file unchecked by
    # construction, the identical gap this repository already closed one
    # level up for the bare-tool-call scan.
    _sm_libfiles=$(find "$_sm_repo_dir/scripts/lib" -maxdepth 1 -type f -name '*.sh' | sort)
    for _sm_libfile_abs in $_sm_libfiles; do
        _sm_libfile=${_sm_libfile_abs#"$_sm_repo_dir"/}
        _sm_recorded_mode=$(cd "$_sm_repo_dir" && "$_sm_git" ls-files -s -- "$_sm_libfile" 2>/dev/null | awk '{print $1}')
        assert_eq "$_sm_libfile is committed non-executable (100644, it is only ever sourced)" "100644" "$_sm_recorded_mode"
    done

    _sm_recorded_mode=$(cd "$_sm_repo_dir" && "$_sm_git" ls-files -s -- artifacts.lock.json 2>/dev/null | awk '{print $1}')
    assert_eq "artifacts.lock.json is committed non-executable (100644, it is data, not a script)" "100644" "$_sm_recorded_mode"
fi

# Every external tool this repository's runtime code shells out to must be
# resolved to an absolute path first (see common.sh's header: none of the
# three invocation conventions FPP uses to run these scripts can be
# trusted to carry a PATH). A bare `tr` slipped back in at lock.sh's own
# flattening step after a previous round of this exact cleanup, and the
# suite stayed fully green because nothing checked for it: with an empty
# PATH it silently failed and the caller misreported "no entry for the
# artifact" instead of "tool not found". This grep-based check is what
# makes that regress loudly instead of silently.
#
# The runtime script surface is DISCOVERED, not a hardcoded file list: a
# hardcoded list left a newly added script unscanned by construction,
# which is exactly the gap that let a bare tool call ship inside one
# undetected before. Every *.sh under scripts/ and commands/ is this
# repository's actual runtime surface (test/run_tests.sh itself is
# excluded on purpose — it is a dev/CI-only script that legitimately
# calls tools bare, with a real PATH, and is not one of the three
# constrained invocation conventions common.sh's header describes).
# Scrubs a file's own sm_resolve_bin call sites (see the header on the
# scrub itself, below) and reports every command-position or bare-
# assignment use of $2 remaining in $1, one per output line. Factored out
# of the real scan below so the self-test section further down can drive
# the exact same detection logic against synthetic fixtures instead of
# only ever exercising it against whatever this repository's own tree
# happens to contain right now.
_sm_hygiene_bare_hits() {
    local _sm_hbh_file _sm_hbh_tool _sm_hbh_scrubbed
    _sm_hbh_file="$1"
    _sm_hbh_tool="$2"

    # Blanks out only the sm_resolve_bin call's OWN argument list (the
    # tool name plus its absolute-path candidates, which legitimately
    # contain the bare word) up to that call's closing paren, rather than
    # excluding any LINE that merely mentions "sm_resolve_bin" anywhere
    # on it. The old, line-wide exclusion missed a bare call sharing a
    # physical line with an unrelated sm_resolve_bin reference; scrubbing
    # just the call's own text closes that without hiding anything else
    # on the same line.
    #
    # The argument class is restricted to what a real candidate list
    # ever contains (the tool name plus absolute paths: letters, digits,
    # `_`, `/`, `.`, `-`, and whitespace) rather than "everything but a
    # closing paren". A real call never contains a `)` before its own
    # terminator, so this restriction changes nothing for one; it exists
    # for the adversarial case, a bare call nested inside what looks like
    # a resolver argument list (for example a `$(...)` used as a
    # candidate), which carries a `)` of its OWN ahead of the real
    # terminator. `[^)]*` stopped at that inner `)`, scrubbing the nested
    # bare call away before the command-position scan below ever saw it.
    # Restricting the class means anything containing a `$`, `(`, or `"`
    # simply fails to match at all, so the sed leaves that entire
    # malformed span untouched for the real scan to inspect instead of
    # silently deleting it.
    _sm_hbh_scrubbed=$(sed -E 's/sm_resolve_bin[[:space:][:alnum:]_./-]*\)//g' "$_sm_hbh_file")

    # Two distinct shapes count as an unresolved use of a tool, found
    # independently rather than through a single line-based allow/deny
    # list (which is what let a comment- or log-line exclusion hide an
    # actual invocation on the same kind of line):
    #
    #   1. A bare invocation in COMMAND POSITION: the tool name directly
    #      after a command separator (start of line, `;`, `&`, `|`, `(`,
    #      `)` as a case-arm pattern's own close, `{` opening an inline
    #      group, a backtick, `!`, a leading redirection with no target
    #      word of its own (`>&2 tool`, `2>&1 tool`, `<&0 tool`), `$(`,
    #      one or more leading `VAR=value` environment assignments
    #      (`LC_ALL=C tool`), or the shell keywords `then`/`do`/`else`/
    #      `elif`/`if`/`while`/`until`/`time`/`command`/`exec`/`eval`/
    #      `sudo`/`xargs`), optionally quoted. Prose that merely mentions
    #      a tool's name mid-sentence ("...ignoring chmod...", "...from
    #      uname -m...") is never preceded by any of those, so it never
    #      matches this shape, with no need to special-case which
    #      function's message the prose happens to sit inside (the
    #      previous version's exclusion for lines starting with
    #      sm_log_err/sm_log/printf was too broad for exactly this
    #      reason: it also hid a real bare invocation embedded inside
    #      such a line's own $(...).) An earlier version of this class
    #      omitted the shell keywords and the case/brace delimiters, so a
    #      bare call right after `then`, `do`, `{`, or a case pattern's
    #      `)` all shared a line with none of the original delimiters and
    #      went uncaught; a later version still missed the backtick
    #      itself, `!`, `if`/`while`/`until`/`time`/`command`/`exec`/
    #      `eval`/`sudo`/`xargs`, a leading redirection, and a leading
    #      env-var assignment.
    #   2. A bare ASSIGNMENT: VAR=tool with no resolution in between,
    #      optionally preceded by `local`, `export`, or `readonly`.
    #      "_sm_rm=rm" is exactly as unresolved as calling `rm` directly
    #      the moment "$_sm_rm" is later invoked; a plain character-class
    #      match that excluded anything preceded by "=" (the previous
    #      version's) whitelisted this shape by construction instead of
    #      catching it. "local _sm_rm=rm" is the single most likely
    #      accidental shape in this tree, since nearly every function
    #      here opens a block of `local` declarations, and an earlier
    #      version of this class did not recognize `local`/`export`/
    #      `readonly` as a prefix to that same shape.
    printf '%s\n' "$_sm_hbh_scrubbed" | grep -n -E \
        "(^|[;&|(){\`!]|[0-9]*(>{1,2}|<)&?[0-9]*|\\\$\\(|(^|[[:space:];&|])(then|do|else|elif|if|while|until|time|command|exec|eval|sudo|xargs)[[:space:]]|(^|[;&|(){])([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+)[[:space:]]*[\"']?${_sm_hbh_tool}([^A-Za-z0-9_]|\$)|(^|[;&|(){]|(^|[[:space:];&|])(then|do|else|elif|if|while|until|local|export|readonly)[[:space:]])[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=${_sm_hbh_tool}([^A-Za-z0-9_]|\$)" \
        | grep -v -E '^[0-9]+:[[:space:]]*#'
}

_sm_hygiene_files=$(find "$_sm_repo_dir/scripts" "$_sm_repo_dir/commands" -type f -name '*.sh' | sort)

# The allowed tool list is derived FROM sm_resolve_bin's own call sites
# across those same discovered scripts, not duplicated by hand: a tool
# newly resolved somewhere becomes allowed here automatically, with
# nothing to fall out of sync.
_sm_allowed_tools=$(printf '%s\n' "$_sm_hygiene_files" | xargs grep -ohE 'sm_resolve_bin[[:space:]]+[A-Za-z0-9_]+' 2>/dev/null \
    | awk '{print $2}' | sort -u)

_sm_bare_tool_hits=0
for _sm_hygiene_file in $_sm_hygiene_files; do
    _sm_relfile=${_sm_hygiene_file#"$_sm_repo_dir"/}
    for _sm_tool in $_sm_allowed_tools; do
        _sm_hits=$(_sm_hygiene_bare_hits "$_sm_hygiene_file" "$_sm_tool")
        if [ -n "$_sm_hits" ]; then
            _sm_bare_tool_hits=$((_sm_bare_tool_hits + 1))
            fail "$_sm_relfile calls '$_sm_tool' through a resolved absolute path, never bare" "$_sm_hits"
        fi
    done
done
if [ "$_sm_bare_tool_hits" -eq 0 ]; then
    pass "no runtime script calls a resolved external tool bare (unresolved by absolute path)"
fi
if [ -n "$_sm_allowed_tools" ]; then
    pass "the allowed tool list was derived from sm_resolve_bin's own call sites, not hand-duplicated"
else
    fail "the allowed tool list was derived from sm_resolve_bin's own call sites, not hand-duplicated" "derived list is empty; the discovery itself is broken"
fi

# --- self-test: the detection logic above, driven against synthetic
# fixtures rather than this repository's own (currently clean) tree, so
# a regression in the guard itself fails loudly instead of only ever
# being as good as whatever this tree happens to contain right now. Each
# fixture plants exactly one bare `chmod` invocation in a shape this
# guard's command-position class must catch. ---
_sm_hygiene_selftest_dir="$_sm_tmp/hygiene-selftest"
mkdir -p "$_sm_hygiene_selftest_dir"

_sm_hygiene_case() {
    # $1 = description, $2 = fixture body, $3 = tool the fixture plants bare
    _sm_hc_file="$_sm_hygiene_selftest_dir/case.sh"
    printf '%s\n' "$2" > "$_sm_hc_file"
    _sm_hc_hits=$(_sm_hygiene_bare_hits "$_sm_hc_file" "$3")
    if [ -n "$_sm_hc_hits" ]; then
        pass "hygiene guard catches a bare call $1"
    else
        fail "hygiene guard catches a bare call $1" "no hit for fixture:
$2"
    fi
}

_sm_hygiene_case "after 'then'" 'if [ -f x ]; then chmod x; fi' chmod
_sm_hygiene_case "after 'do'" 'for f in x; do chmod "$f"; done' chmod
_sm_hygiene_case "inside { ... }" '{ chmod x; }' chmod
_sm_hygiene_case "after a case pattern" 'case "$x" in *) chmod x ;; esac' chmod
_sm_hygiene_case "backtick command substitution" 'x=`chmod y`' chmod
_sm_hygiene_case "negated with '!'" '! chmod x' chmod
_sm_hygiene_case "'if tool; then'" 'if chmod x; then :; fi' chmod
_sm_hygiene_case "'while'" 'while chmod x; do :; done' chmod
_sm_hygiene_case "'until'" 'until chmod x; do :; done' chmod
_sm_hygiene_case "'time'" 'time chmod x' chmod
_sm_hygiene_case "'command'" 'command chmod x' chmod
_sm_hygiene_case "'exec'" 'exec chmod x' chmod
_sm_hygiene_case "'eval'" 'eval chmod x' chmod
_sm_hygiene_case "'sudo'" 'sudo chmod x' chmod
_sm_hygiene_case "'xargs'" 'echo x | xargs chmod' chmod
_sm_hygiene_case "a leading redirection" '>&2 chmod x' chmod

# The sed scrub must not delete a bare call nested inside what looks like
# a resolver argument list (a command substitution used as one of the
# candidates), which carries a `)` of its own ahead of the call's real
# terminator. The bare call planted here is `rm`, not `chmod`: it sits
# inside the nested `$(...)`, so this checks specifically that the scrub
# leaves it standing rather than deleting it along with the outer
# sm_resolve_bin call it appears to belong to.
_sm_hygiene_case "nested inside a resolver argument list" '_sm_x=$(sm_resolve_bin chmod "$(rm -f x)")' rm

# --- self-test: the bare-ASSIGNMENT class ("VAR=tool"), the other half
# of _sm_hygiene_bare_hits. Every fixture above only ever plants a bare
# call in COMMAND position; reverting the assignment class to its old,
# narrower character-class-only form left the suite fully green with none
# of these run, so each of these is what actually exercises that half of
# the guard. ---
_sm_hygiene_case "bare assignment 'VAR=tool'" '_sm_rm=rm' rm
_sm_hygiene_case "'local VAR=tool'" 'local _sm_rm=rm' rm
_sm_hygiene_case "'export VAR=tool'" 'export _sm_rm=rm' rm
_sm_hygiene_case "'readonly VAR=tool'" 'readonly _sm_rm=rm' rm
_sm_hygiene_case "a leading 'LC_ALL=C'" 'LC_ALL=C chmod x' chmod

unset -f _sm_hygiene_case
unset _sm_hc_file _sm_hc_hits

# ---------------------------------------------------------------------------
# The shipped commands/descriptions.json, not only synthetic fixtures
# ---------------------------------------------------------------------------
#
# Every command-script-validation assertion above runs against a fixture
# built inside this test. None of them prove the actual file this
# repository ships is valid — this exact gap is what let run-macro.sh sit
# under scripts/ instead of commands/ for one commit, caught only when
# someone happened to run the validator against the real tree by hand.
# Running it here turns that into a standing check instead of a one-time
# save.

echo "== shipped descriptions.json =="

if sm_validate_command_scripts "$_sm_repo_dir"; then
    pass "this repository's own commands/descriptions.json validates against its own commands/ directory"
else
    fail "this repository's own commands/descriptions.json validates against its own commands/ directory" "the shipped file/script pair does not validate — see the errors logged above"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "== summary =="
echo "passed: $_sm_pass"
echo "failed: $_sm_fail"

if [ "$_sm_fail" -gt 0 ]; then
    exit 1
fi
exit 0
