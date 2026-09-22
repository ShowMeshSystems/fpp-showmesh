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

/* --- coordinator URL validation --- */

t_assert("a valid http address passes validation", sm_validate_coordinator_url('http://coordinator.local:8080') === null, sm_validate_coordinator_url('http://coordinator.local:8080'));
t_assert("a valid https address passes validation", sm_validate_coordinator_url('https://coordinator.local') === null, sm_validate_coordinator_url('https://coordinator.local'));
t_assert("a leading/trailing-space address still passes validation once trimmed", sm_validate_coordinator_url('  https://coordinator.local  ') === null, sm_validate_coordinator_url('  https://coordinator.local  '));
t_assert("an empty address is refused", sm_validate_coordinator_url('') !== null, 'expected a refusal reason');
t_assert("a non-http(s) scheme is refused", sm_validate_coordinator_url('ftp://coordinator.local') !== null, 'expected a refusal reason');
t_assert("an address with no scheme at all is refused", sm_validate_coordinator_url('coordinator.local') !== null, 'expected a refusal reason');
t_assert("an address with no host is refused", sm_validate_coordinator_url('http://') !== null, 'expected a refusal reason');

$configPath = $stateDir . '/config.json';
@unlink($configPath);

$badWrite = sm_write_config('not a url');
t_assert("writing an invalid address is refused", $badWrite['status'] === 'error', var_export($badWrite, true));
t_assert("a refused write leaves no config.json behind", !is_file($configPath), 'config.json was written despite a refused address');

$goodWrite = sm_write_config('https://coordinator.example:9443');
t_assert("writing a valid address succeeds", $goodWrite['status'] === 'ok', var_export($goodWrite, true));
$r = sm_read_config();
t_assert("the saved address round-trips through config.json", sm_field($r['data'], 'coordinatorUrl') === 'https://coordinator.example:9443', var_export($r, true));

@unlink($configPath);
$r = sm_read_config();
t_assert("a missing config.json renders unknown", $r['status'] === 'unknown' && $r['data'] === null, var_export($r, true));

/* --- pairing state rendering --- */

$pairingStatusPath = $stateDir . '/pairing-status.json';
$pairingCodePath = $stateDir . '/pairing-code';
$pairingRequestPath = $stateDir . '/pairing-request';
@unlink($pairingStatusPath);
@unlink($pairingCodePath);
@unlink($pairingRequestPath);

$r = sm_read_pairing_status();
t_assert("a missing pairing-status.json renders idle (not paired), not unknown", $r['status'] === 'ok' && sm_field($r['data'], 'state') === 'idle', var_export($r, true));

file_put_contents($pairingStatusPath, json_encode(array(
    'state' => 'waiting', 'code' => 'ABCD-1234', 'principalId' => '', 'pairedAtMillis' => 0,
    'lastError' => '', 'updatedAtMillis' => SM_SHOWMESH_NOW_MILLIS,
)));
$r = sm_read_pairing_status();
t_assert("a waiting pairing-status.json renders waiting", sm_field($r['data'], 'state') === 'waiting', var_export($r, true));

file_put_contents($pairingCodePath, json_encode(array('code' => 'ABCD-1234', 'expiresAtMillis' => SM_SHOWMESH_NOW_MILLIS + 600000)));
$code = sm_read_pairing_code();
t_assert("pairing-code is readable while waiting", $code !== null && $code['code'] === 'ABCD-1234', var_export($code, true));

@unlink($pairingCodePath);
t_assert("a missing pairing-code reads as null, not a fabricated code", sm_read_pairing_code() === null, 'expected null');

file_put_contents($pairingStatusPath, json_encode(array(
    'state' => 'paired', 'code' => '', 'principalId' => 'p1', 'pairedAtMillis' => SM_SHOWMESH_NOW_MILLIS,
    'lastError' => '', 'updatedAtMillis' => SM_SHOWMESH_NOW_MILLIS,
)));
$r = sm_read_pairing_status();
t_assert("a paired pairing-status.json renders paired", sm_field($r['data'], 'state') === 'paired', var_export($r, true));

file_put_contents($pairingStatusPath, json_encode(array(
    'state' => 'expired', 'code' => '', 'principalId' => '', 'pairedAtMillis' => 0,
    'lastError' => '', 'updatedAtMillis' => SM_SHOWMESH_NOW_MILLIS,
)));
$r = sm_read_pairing_status();
t_assert("an expired pairing-status.json renders expired", sm_field($r['data'], 'state') === 'expired', var_export($r, true));

file_put_contents($pairingStatusPath, json_encode(array(
    'state' => 'failed', 'code' => '', 'principalId' => '', 'pairedAtMillis' => 0,
    'lastError' => 'connection refused', 'updatedAtMillis' => SM_SHOWMESH_NOW_MILLIS,
)));
$r = sm_read_pairing_status();
t_assert("a failed pairing-status.json renders failed with its error", sm_field($r['data'], 'state') === 'failed' && sm_field($r['data'], 'lastError') === 'connection refused', var_export($r, true));

file_put_contents($pairingStatusPath, '{not valid json');
$r = sm_read_pairing_status();
t_assert("malformed pairing-status.json renders unknown, not a fabricated state", $r['status'] === 'unknown' && $r['data'] === null, var_export($r, true));

@unlink($pairingStatusPath);

/* --- pairing-request write --- */

@unlink($pairingRequestPath);
t_assert("sm_write_pairing_request reports success", sm_write_pairing_request() === true, 'expected true');
t_assert("sm_write_pairing_request creates pairing-request", is_file($pairingRequestPath), 'pairing-request was not created');
$written = json_decode(file_get_contents($pairingRequestPath), true);
t_assert("pairing-request's shape matches CONTRACT.md", is_array($written) && isset($written['requestedAtMillis']) && is_int($written['requestedAtMillis']), var_export($written, true));
@unlink($pairingRequestPath);

/* --- millisecond time formatting --- */

t_assert("a zero millis value formats as null (unknown), not epoch", sm_format_millis_time(0, 'H:i') === null, 'expected null');
t_assert("a non-numeric millis value formats as null", sm_format_millis_time('not a number', 'H:i') === null, 'expected null');
$expected = date('H:i', (int) (SM_SHOWMESH_NOW_MILLIS / 1000));
t_assert("a valid millis value formats using the given format", sm_format_millis_time(SM_SHOWMESH_NOW_MILLIS, 'H:i') === $expected, sm_format_millis_time(SM_SHOWMESH_NOW_MILLIS, 'H:i'));

/* --- brightness readout for the fallback endpoint --- */

$readout = sm_brightness_readout(array('lastAppliedCeiling' => 60, 'ceilingFadeStartMillis' => SM_SHOWMESH_NOW_MILLIS - 1000, 'ceilingFadeEndMillis' => SM_SHOWMESH_NOW_MILLIS + 1000));
t_assert("brightness readout carries the applied ceiling", $readout['ceiling'] === 60, var_export($readout, true));
t_assert("brightness readout reports fade active while a fade is running", $readout['fadeActive'] === true, var_export($readout, true));
t_assert("brightness readout reports unknown fields as null when the file carries no gain, not a fabricated zero", $readout['transitionGain'] === null && $readout['effectiveOutput'] === null, var_export($readout, true));

$readout = sm_brightness_readout(array('lastAppliedCeiling' => 80, 'lastAppliedGain' => 50));
t_assert("brightness readout maps transitionGain from lastAppliedGain", $readout['transitionGain'] === 50, var_export($readout, true));
t_assert("brightness readout computes effectiveOutput as ceiling * gain / 100", $readout['effectiveOutput'] === 40, var_export($readout, true));

$readout = sm_brightness_readout(array('lastAppliedCeiling' => 'not a number', 'lastAppliedGain' => 50));
t_assert("effectiveOutput is null when the ceiling is not numeric, never a guessed value", $readout['effectiveOutput'] === null, var_export($readout, true));

/* --- redirect-after-post target: drops old flags, keeps the rest --- */

$target = sm_post_redirect_target('/plugin.php?plugin=fpp-showmesh&page=plugin.php', 'smPaired', '1');
t_assert("a fresh redirect target keeps the page's own query params", strpos($target, 'plugin=fpp-showmesh') !== false, $target);
t_assert("a fresh redirect target carries the new flag", strpos($target, 'smPaired=1') !== false, $target);
t_assert("a fresh redirect target keeps the path", strpos($target, '/plugin.php?') === 0, $target);

$target = sm_post_redirect_target('/plugin.php?smConfigSaved=1&plugin=fpp-showmesh', 'smConfigError', 'bad address');
t_assert("an old outcome flag is dropped when a new one is set", strpos($target, 'smConfigSaved') === false, $target);
t_assert("the new outcome flag replaces it, value included", strpos($target, 'smConfigError=bad') !== false, $target);

printf("\n== php unit summary ==\n");
printf("passed: %d\n", $pass);
printf("failed: %d\n", $fail);
exit($fail > 0 ? 1 : 0);
