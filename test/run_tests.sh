#!/bin/sh
# Exercises the things in this repo worth failing loudly over: the
# architecture probe, checksum verification, and command-script validation.
# Every scenario here is something that would otherwise be discovered on a
# real Pi, the hard way.
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
trap 'rm -rf "$_sm_tmp"' EXIT

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

    for _sm_libfile in \
        scripts/lib/common.sh \
        scripts/lib/arch.sh \
        scripts/lib/fetch.sh \
        scripts/lib/verify.sh \
        scripts/lib/commands.sh \
        scripts/lib/install-core.sh
    do
        _sm_recorded_mode=$(cd "$_sm_repo_dir" && "$_sm_git" ls-files -s -- "$_sm_libfile" 2>/dev/null | awk '{print $1}')
        assert_eq "$_sm_libfile is committed non-executable (100644, it is only ever sourced)" "100644" "$_sm_recorded_mode"
    done
fi

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
