<?php
/* Unit tests for lib.php's pure logic: run standalone, no HTTP context.
 * $argv[1] = repo root, $argv[2] = a writable directory this script owns
 * for fixture files. Output lines are "ok   - ..." / "FAIL - ..." to
 * match test/run_tests.sh's format; test/php_tests.sh tallies them. */

$repoRoot = $argv[1];
$stateDir = $argv[2];

define('SM_SHOWMESH_STATE_DIR', $stateDir);
define('SM_SHOWMESH_PLUGIN_DIR', $repoRoot);
define('SM_SHOWMESH_NOW_MILLIS', 2000000000000);

require $repoRoot . '/lib.php';

$pass = 0;
$fail = 0;

function t_pass($desc) {
    global $pass;
    $pass++;
    printf("ok   - %s\n", $desc);
}

function t_fail($desc, $detail) {
    global $fail;
    $fail++;
    printf("FAIL - %s\n       %s\n", $desc, $detail);
}

function t_assert($desc, $condition, $detail) {
    if ($condition) {
        t_pass($desc);
    } else {
        t_fail($desc, $detail);
    }
}

$brightnessPath = $stateDir . '/brightness-state';
$backupPath = $stateDir . '/brightness-state.bak';
$observationPath = $stateDir . '/observation-status.json';

/* --- brightness-state: missing/empty/malformed never yield a value --- */

@unlink($brightnessPath);
$r = sm_read_brightness_state();
t_assert("missing brightness-state renders unknown, not zero", $r['status'] === 'unknown' && $r['data'] === null, var_export($r, true));
t_assert("missing brightness-state names the reason", strpos($r['reason'], 'missing') !== false, $r['reason']);

file_put_contents($brightnessPath, '');
$r = sm_read_brightness_state();
t_assert("empty brightness-state renders unknown", $r['status'] === 'unknown' && $r['data'] === null, var_export($r, true));

file_put_contents($brightnessPath, "{\"lastAppliedCeiling\":50}\n");
$r = sm_read_brightness_state();
t_assert("brightness-state with no checksum line renders unknown", $r['status'] === 'unknown', var_export($r, true));
t_assert("the missing-checksum-line reason names the two-line framing", strpos($r['reason'], 'two lines') !== false, $r['reason']);

/* --- checksum gate: matches the resident component's own format --- */

@unlink($backupPath);

$validLine = '{"lastAppliedCeiling":42,"instanceId":"box-1"}';
$validHash = hash('sha256', $validLine);
file_put_contents($brightnessPath, $validLine . "\n" . $validHash . "\n");
$r = sm_read_brightness_state();
t_assert("a genuinely valid record verifies and renders", $r['status'] === 'ok', var_export($r, true));
t_assert("a genuinely valid record's data is readable", sm_field($r['data'], 'lastAppliedCeiling') === 42, var_export($r, true));
t_assert("a genuinely valid primary record is reported as read from the primary", $r['source'] === 'primary', var_export($r, true));

$tamperedLine = '{"lastAppliedCeiling":99,"instanceId":"box-1"}';
file_put_contents($brightnessPath, $tamperedLine . "\n" . $validHash . "\n");
$r = sm_read_brightness_state();
t_assert("a state line altered after hashing fails checksum verification", $r['status'] === 'unknown' && $r['data'] === null, var_export($r, true));
t_assert("the tampered-line reason names checksum verification", strpos($r['reason'], 'checksum') !== false, $r['reason']);

file_put_contents($brightnessPath, $validLine . "\n" . 'notarealsha256hexvalue' . "\n");
$r = sm_read_brightness_state();
t_assert("a checksum line that is not a real hash fails verification", $r['status'] === 'unknown', var_export($r, true));

file_put_contents($brightnessPath, $validLine . "\n" . $validHash . "\nunexpected third line\n");
$r = sm_read_brightness_state();
t_assert("a third line after the checksum makes the record invalid", $r['status'] === 'unknown', var_export($r, true));
t_assert("the third-line reason names the framing, not the checksum or JSON", strpos($r['reason'], 'two lines') !== false, $r['reason']);

/* --- backup fallback: mirrors the resident component's own order --- */

file_put_contents($brightnessPath, 'not a valid record at all');
$backupLine = '{"lastAppliedCeiling":17,"instanceId":"box-1"}';
$backupHash = hash('sha256', $backupLine);
file_put_contents($backupPath, $backupLine . "\n" . $backupHash . "\n");
$r = sm_read_brightness_state();
t_assert("a corrupt primary with a valid backup renders the backup, not unknown", $r['status'] === 'ok', var_export($r, true));
t_assert("a corrupt primary with a valid backup renders the backup's actual data", sm_field($r['data'], 'lastAppliedCeiling') === 17, var_export($r, true));
t_assert("reading from the backup is reported as such", $r['source'] === 'backup', var_export($r, true));

@unlink($brightnessPath);
$r = sm_read_brightness_state();
t_assert("a missing primary with a valid backup still renders the backup", $r['status'] === 'ok' && $r['source'] === 'backup', var_export($r, true));

file_put_contents($backupPath, 'also not a valid record');
$r = sm_read_brightness_state();
t_assert("both primary and backup failing renders unknown, not zero", $r['status'] === 'unknown' && $r['data'] === null, var_export($r, true));
t_assert("both failing reports no source", $r['source'] === null, var_export($r, true));

@unlink($backupPath);

/* --- observation-status.json: no checksum, but still degrades --- */

@unlink($observationPath);
$r = sm_read_observation_status();
t_assert("missing observation-status.json renders unknown", $r['status'] === 'unknown' && $r['data'] === null, var_export($r, true));

file_put_contents($observationPath, '{not valid json');
$r = sm_read_observation_status();
t_assert("malformed observation-status.json renders unknown", $r['status'] === 'unknown', var_export($r, true));
t_assert("malformed-JSON reason names it", strpos($r['reason'], 'JSON') !== false, $r['reason']);

file_put_contents($observationPath, json_encode(array(
    'configured' => true,
    'lastOutcome' => 'accepted',
    'lastStatusCode' => 200,
)));
$r = sm_read_observation_status();
t_assert("a valid observation-status.json renders ok", $r['status'] === 'ok', var_export($r, true));
t_assert("a valid observation-status.json's fields are readable", sm_field($r['data'], 'lastOutcome') === 'accepted', var_export($r, true));

/* --- fade status: a past end time is finished, never rendered running --- */

$future = array('ceilingFadeStartMillis' => SM_SHOWMESH_NOW_MILLIS - 1000, 'ceilingFadeEndMillis' => SM_SHOWMESH_NOW_MILLIS + 1);
t_assert("an end time one millisecond in the future is running", sm_ceiling_fade_status($future) === 'running', sm_ceiling_fade_status($future));

$exactlyNow = array('ceilingFadeStartMillis' => SM_SHOWMESH_NOW_MILLIS - 1000, 'ceilingFadeEndMillis' => SM_SHOWMESH_NOW_MILLIS);
t_assert("an end time exactly now is finished, not running", sm_ceiling_fade_status($exactlyNow) === 'finished', sm_ceiling_fade_status($exactlyNow));

$past = array('ceilingFadeStartMillis' => SM_SHOWMESH_NOW_MILLIS - 100000, 'ceilingFadeEndMillis' => SM_SHOWMESH_NOW_MILLIS - 1);
t_assert("an end time in the past is finished", sm_ceiling_fade_status($past) === 'finished', sm_ceiling_fade_status($past));

$none = array();
t_assert("no fade fields at all is none, not finished or running", sm_ceiling_fade_status($none) === 'none', sm_ceiling_fade_status($none));

/* --- escaping: sm_h() never lets raw markup or quotes through --- */

$xss = '<script>alert(1)</script>';
$escaped = sm_h($xss);
t_assert("sm_h escapes a script tag", strpos($escaped, '<script>') === false, $escaped);
t_assert("sm_h's escaped output contains the entity form", strpos($escaped, '&lt;script&gt;') !== false, $escaped);

$attrBreakout = '" onerror="alert(1)';
$escapedAttr = sm_h($attrBreakout);
t_assert("sm_h escapes a double quote used for attribute breakout", strpos($escapedAttr, '"') === false, $escapedAttr);
t_assert("sm_h's escaped output contains the quote entity", strpos($escapedAttr, '&quot;') !== false, $escapedAttr);

printf("\n== php unit summary ==\n");
printf("passed: %d\n", $pass);
printf("failed: %d\n", $fail);
exit($fail > 0 ? 1 : 0);
