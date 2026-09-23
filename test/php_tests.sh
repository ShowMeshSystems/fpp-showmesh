#!/bin/sh
# Exercises plugin.php and lib.php: PHP syntax, the read/degrade logic in
# lib.php in isolation, and one full end-to-end render of plugin.php
# against fixture state files, asserting on the actual HTML it produces.
#
# Kept out of test/run_tests.sh on purpose: that suite is plain POSIX sh
# with no PHP dependency, and this one needs a PHP interpreter. Prefers a
# native `php` on PATH; falls back to `docker run php:8-cli` when Docker
# is reachable and no native php is present; skips outright, via the same
# skip() convention as run_tests.sh, when neither is available. Never
# makes Docker a requirement for the rest of this repository's tests.
#
# Run with: sh test/php_tests.sh

set -u

_sm_test_dir=$(cd "$(dirname "$0")" && pwd)
_sm_repo_dir=$(cd "$_sm_test_dir/.." && pwd)

_sm_pass=0
_sm_fail=0

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

skip() {
    printf 'skip - %s (%s)\n' "$1" "$2"
}

assert_contains() {
    # $1 = description, $2 = haystack, $3 = needle
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1" "expected output to contain [$3]" ;;
    esac
}

assert_not_contains() {
    # $1 = description, $2 = haystack, $3 = needle that must be absent
    case "$2" in
        *"$3"*) fail "$1" "expected output NOT to contain [$3]" ;;
        *) pass "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Runner selection
# ---------------------------------------------------------------------------

_sm_php_mode=""
if command -v php >/dev/null 2>&1; then
    _sm_php_mode="native"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    _sm_php_mode="docker"
fi

if [ -z "$_sm_php_mode" ]; then
    skip "all plugin.php / lib.php tests" "neither a native php interpreter nor a reachable Docker daemon was found"
    echo
    echo "== php summary =="
    echo "passed: 0"
    echo "failed: 0"
    exit 0
fi

sm_php() {
    if [ "$_sm_php_mode" = "native" ]; then
        php "$@"
    else
        docker run --rm -i -v "$_sm_repo_dir":/w -w /w php:8-cli php "$@"
    fi
}

echo "== php runner: $_sm_php_mode =="

# ---------------------------------------------------------------------------
# Syntax check
# ---------------------------------------------------------------------------

_sm_lint_out=$(sm_php -l plugin.php 2>&1)
_sm_lint_status=$?
if [ "$_sm_lint_status" -eq 0 ]; then
    pass "plugin.php has no PHP syntax errors"
else
    fail "plugin.php has no PHP syntax errors" "$_sm_lint_out"
fi

_sm_lint_out=$(sm_php -l lib.php 2>&1)
_sm_lint_status=$?
if [ "$_sm_lint_status" -eq 0 ]; then
    pass "lib.php has no PHP syntax errors"
else
    fail "lib.php has no PHP syntax errors" "$_sm_lint_out"
fi

# ---------------------------------------------------------------------------
# Unit tests: lib.php's read/degrade/escape logic, no HTTP context
# ---------------------------------------------------------------------------

_sm_fixture_dir=$(mktemp -d "$_sm_repo_dir/.php-test-tmp.XXXXXX")
trap 'rm -rf "$_sm_fixture_dir"' EXIT

_sm_unit_out=$(sm_php test/php/unit_tests.php . "$(basename "$_sm_fixture_dir")" 2>&1)
_sm_unit_status=$?
printf '%s\n' "$_sm_unit_out" | grep -E '^(ok|FAIL) ' | while IFS= read -r _sm_line; do
    printf '%s\n' "$_sm_line"
done
_sm_unit_pass=$(printf '%s\n' "$_sm_unit_out" | grep -c '^ok   - ')
_sm_unit_fail=$(printf '%s\n' "$_sm_unit_out" | grep -c '^FAIL - ')
_sm_pass=$((_sm_pass + _sm_unit_pass))
_sm_fail=$((_sm_fail + _sm_unit_fail))
if [ "$_sm_unit_status" -ne 0 ] && [ "$_sm_unit_fail" -eq 0 ]; then
    fail "test/php/unit_tests.php ran to completion" "$_sm_unit_out"
fi

# ---------------------------------------------------------------------------
# Integration: render the real plugin.php end to end
# ---------------------------------------------------------------------------

# Starts from a clean fixture directory: the unit tests above reuse this
# same directory and leave a brightness-state file behind, which would
# otherwise make the "absent brightness-state" assertion below false by
# accident rather than by what this render actually does.
rm -f "$_sm_fixture_dir/brightness-state" "$_sm_fixture_dir/observation-status.json"

# A hostile observation-status.json: the exact rule under test is that
# escaping happens on EVERY rendered value, so this deliberately reuses
# both an HTML tag and an attribute-breakout quote in fields the page
# renders, and asserts the raw characters never reach the output.
cat > "$_sm_fixture_dir/observation-status.json" <<'EOF'
{
  "configured": false,
  "configurationError": "credential file missing\" onerror=\"alert(1)",
  "lastOutcome": "<script>alert(document.cookie)</script>",
  "lastStatusCode": 401,
  "lastError": "<img src=x onerror=alert(1)>",
  "reportsRefusedReason": "<b>unauthorized</b> onerror=\"alert(1)\""
}
EOF

_sm_render_out=$(sm_php test/php/render_fixture.php "$(basename "$_sm_fixture_dir")" . 2>&1)

assert_not_contains "rendered page never contains a raw <script> tag from lastOutcome" "$_sm_render_out" "<script>alert(document.cookie)</script>"
assert_contains "rendered page contains the escaped form of lastOutcome" "$_sm_render_out" "&lt;script&gt;alert(document.cookie)&lt;/script&gt;"

assert_not_contains "rendered page never contains a raw onerror= attribute from lastError" "$_sm_render_out" "<img src=x onerror=alert(1)>"
assert_contains "rendered page contains the escaped form of lastError" "$_sm_render_out" "&lt;img src=x onerror=alert(1)&gt;"

assert_not_contains "rendered page never contains a raw attribute-breakout quote from configurationError" "$_sm_render_out" 'missing" onerror="alert(1)'
assert_contains "rendered page contains the escaped form of configurationError" "$_sm_render_out" "missing&quot; onerror=&quot;alert(1)"

assert_not_contains "rendered page never contains a raw tag from reportsRefusedReason" "$_sm_render_out" "<b>unauthorized</b>"
assert_contains "rendered page contains the escaped form of reportsRefusedReason" "$_sm_render_out" "&lt;b&gt;unauthorized&lt;/b&gt;"
assert_contains "rendered page shows the reports-refused warning row when reportsRefusedReason is set" "$_sm_render_out" 'class="sm-warning-row"'

# An accepted outcome carries no reportsRefusedReason at all, matching
# what the native client actually writes once the notice clears.
cat > "$_sm_fixture_dir/observation-status.json" <<'EOF'
{
  "configured": true,
  "lastOutcome": "accepted",
  "lastStatusCode": 202,
  "lastError": ""
}
EOF
_sm_render_out=$(sm_php test/php/render_fixture.php "$(basename "$_sm_fixture_dir")" . 2>&1)
assert_not_contains "rendered page shows no reports-refused warning row once accepted" "$_sm_render_out" 'class="sm-warning-row"'

# No brightness-state fixture is present for this render, so the ceiling
# section must degrade to unknown, not a confident zero.
assert_contains "rendered page shows the ceiling as unknown when brightness-state is absent" "$_sm_render_out" "unknown (file missing or unreadable)"

# A genuinely valid brightness-state renders the real ceiling, end to end
# through the real checksum verification, with no backup note.
rm -f "$_sm_fixture_dir/brightness-state" "$_sm_fixture_dir/brightness-state.bak"
_sm_valid_line='{"lastAppliedCeiling":73,"instanceId":"bench-1"}'
_sm_valid_hash=$(printf '%s' "$_sm_valid_line" | sm_php -r 'echo hash("sha256", stream_get_contents(STDIN));')
printf '%s\n%s\n' "$_sm_valid_line" "$_sm_valid_hash" > "$_sm_fixture_dir/brightness-state"
_sm_render_out=$(sm_php test/php/render_fixture.php "$(basename "$_sm_fixture_dir")" . 2>&1)
assert_contains "rendered page shows the real applied ceiling from a genuinely valid record" "$_sm_render_out" "<th>Applied ceiling</th><td>73</td>"
assert_not_contains "a valid primary record shows no backup-source note" "$_sm_render_out" "brightness-state.bak"

# A corrupt primary with a valid backup renders the backup's ceiling and
# names the backup as the source, matching the resident component's own
# fallback order rather than reporting unknown while it runs fine.
printf 'not a valid record at all' > "$_sm_fixture_dir/brightness-state"
_sm_backup_line='{"lastAppliedCeiling":21,"instanceId":"bench-1"}'
_sm_backup_hash=$(printf '%s' "$_sm_backup_line" | sm_php -r 'echo hash("sha256", stream_get_contents(STDIN));')
printf '%s\n%s\n' "$_sm_backup_line" "$_sm_backup_hash" > "$_sm_fixture_dir/brightness-state.bak"
_sm_render_out=$(sm_php test/php/render_fixture.php "$(basename "$_sm_fixture_dir")" . 2>&1)
assert_contains "rendered page falls back to the backup ceiling when the primary is corrupt" "$_sm_render_out" "<th>Applied ceiling</th><td>21</td>"
assert_contains "rendered page names the backup as the source in use" "$_sm_render_out" "brightness-state.bak"
rm -f "$_sm_fixture_dir/brightness-state" "$_sm_fixture_dir/brightness-state.bak"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo
echo "== php summary =="
echo "passed: $_sm_pass"
echo "failed: $_sm_fail"

if [ "$_sm_fail" -gt 0 ]; then
    exit 1
fi
exit 0
