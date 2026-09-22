<?php
/* Pure logic for the ShowMesh status page: reading fixed state files and
 * deciding what they mean. No HTML here; plugin.php owns rendering. */

if (!defined('SM_SHOWMESH_STATE_DIR')) {
    define('SM_SHOWMESH_STATE_DIR', '/home/fpp/media/plugindata/fpp-showmesh');
}
if (!defined('SM_SHOWMESH_PLUGIN_DIR')) {
    define('SM_SHOWMESH_PLUGIN_DIR', __DIR__);
}
if (!defined('SM_SHOWMESH_NOW_MILLIS')) {
    define('SM_SHOWMESH_NOW_MILLIS', (int) round(microtime(true) * 1000));
}

function sm_h($value) {
    return htmlspecialchars((string) $value, ENT_QUOTES, 'UTF-8');
}

function sm_read_version() {
    $path = SM_SHOWMESH_PLUGIN_DIR . '/VERSION';
    if (!is_file($path) || !is_readable($path)) {
        return null;
    }
    $contents = @file_get_contents($path);
    if ($contents === false) {
        return null;
    }
    $version = trim($contents);
    return $version !== '' ? $version : null;
}

/* Matches the resident component's encodeRecord: line + "\n" + sha256Hex(line)
 * + "\n". The hash covers the state line's raw bytes, no trimming or
 * re-encoding. Not timing-sensitive (this is an integrity check on local
 * state, not a secret comparison); hash_equals is used anyway since it is
 * already the right tool for an exact byte comparison. */
function sm_verify_brightness_checksum($jsonLine, $checksumLine) {
    return hash_equals(hash('sha256', $jsonLine), $checksumLine);
}

/* Splits raw file contents into exactly the two lines encodeRecord writes.
 * A third line (any content after the second line's trailing newline) is
 * corruption, not slack, and is refused rather than ignored. */
function sm_split_brightness_record($contents) {
    $parts = explode("\n", $contents);
    if (count($parts) !== 3 || $parts[2] !== '') {
        return null;
    }
    return array($parts[0], $parts[1]);
}

/* Reads and verifies a single brightness-state-shaped file (the primary
 * or the backup). Returns array('status' => 'ok'|'unknown', 'reason' =>
 * string|null, 'data' => array|null); 'data' is only ever non-null when
 * 'status' is 'ok', and every string inside it is raw (unescaped) file
 * content. */
function sm_read_brightness_record_from_file($path) {
    if (!is_file($path) || !is_readable($path)) {
        return array('status' => 'unknown', 'reason' => 'file missing or unreadable', 'data' => null);
    }

    $contents = @file_get_contents($path);
    if ($contents === false || $contents === '') {
        return array('status' => 'unknown', 'reason' => 'file empty or unreadable', 'data' => null);
    }

    $lines = sm_split_brightness_record($contents);
    if ($lines === null) {
        return array('status' => 'unknown', 'reason' => 'malformed record framing (expected exactly two lines)', 'data' => null);
    }
    list($jsonLine, $checksumLine) = $lines;

    if ($checksumLine === '') {
        return array('status' => 'unknown', 'reason' => 'missing checksum line', 'data' => null);
    }

    if (!sm_verify_brightness_checksum($jsonLine, $checksumLine)) {
        return array('status' => 'unknown', 'reason' => 'checksum verification failed', 'data' => null);
    }

    $decoded = json_decode($jsonLine, true);
    if (!is_array($decoded)) {
        return array('status' => 'unknown', 'reason' => 'malformed JSON', 'data' => null);
    }

    return array('status' => 'ok', 'reason' => null, 'data' => $decoded);
}

/* Same return shape as sm_read_brightness_record_from_file, plus a
 * 'source' key ('primary'|'backup'|null). Mirrors the resident
 * component's own fallback order: if the primary fails to parse, it
 * tries brightness-state.bak before giving up, and this must agree with
 * what the component is actually running from rather than reporting
 * unknown while a valid backup is in active use. */
function sm_read_brightness_state() {
    $primary = sm_read_brightness_record_from_file(SM_SHOWMESH_STATE_DIR . '/brightness-state');
    if ($primary['status'] === 'ok') {
        $primary['source'] = 'primary';
        return $primary;
    }

    $backup = sm_read_brightness_record_from_file(SM_SHOWMESH_STATE_DIR . '/brightness-state.bak');
    if ($backup['status'] === 'ok') {
        $backup['source'] = 'backup';
        return $backup;
    }

    return array('status' => 'unknown', 'reason' => $primary['reason'], 'data' => null, 'source' => null);
}

/* Returns the same shape as sm_read_brightness_state, but observation
 * status carries no checksum line: only missing/unreadable/malformed
 * JSON degrade to unknown. */
function sm_read_observation_status() {
    $path = SM_SHOWMESH_STATE_DIR . '/observation-status.json';

    if (!is_file($path) || !is_readable($path)) {
        return array('status' => 'unknown', 'reason' => 'file missing or unreadable', 'data' => null);
    }

    $contents = @file_get_contents($path);
    if ($contents === false || trim($contents) === '') {
        return array('status' => 'unknown', 'reason' => 'file empty or unreadable', 'data' => null);
    }

    $decoded = json_decode($contents, true);
    if (!is_array($decoded)) {
        return array('status' => 'unknown', 'reason' => 'malformed JSON', 'data' => null);
    }

    return array('status' => 'ok', 'reason' => null, 'data' => $decoded);
}

/* $data is the decoded brightness-state document. Returns one of
 * 'running', 'finished', 'none'. A fade whose end time is in the past is
 * 'finished', never rendered as running. */
function sm_ceiling_fade_status($data) {
    $end = isset($data['ceilingFadeEndMillis']) ? $data['ceilingFadeEndMillis'] : null;
    $start = isset($data['ceilingFadeStartMillis']) ? $data['ceilingFadeStartMillis'] : null;

    if (!is_numeric($end) || !is_numeric($start)) {
        return 'none';
    }
    if ((int) $end <= SM_SHOWMESH_NOW_MILLIS) {
        return 'finished';
    }
    return 'running';
}

function sm_field($data, $key) {
    return isset($data[$key]) ? $data[$key] : null;
}

/* Reads <statedir>/config.json. Same degrade shape as the other readers;
 * missing/malformed both render unknown rather than an empty string that
 * could be mistaken for "no coordinator configured on purpose". */
function sm_read_config() {
    $path = SM_SHOWMESH_STATE_DIR . '/config.json';
    if (!is_file($path) || !is_readable($path)) {
        return array('status' => 'unknown', 'reason' => 'file missing or unreadable', 'data' => null);
    }
    $contents = @file_get_contents($path);
    if ($contents === false || trim($contents) === '') {
        return array('status' => 'unknown', 'reason' => 'file empty or unreadable', 'data' => null);
    }
    $decoded = json_decode($contents, true);
    if (!is_array($decoded)) {
        return array('status' => 'unknown', 'reason' => 'malformed JSON', 'data' => null);
    }
    return array('status' => 'ok', 'reason' => null, 'data' => $decoded);
}

/* Validates a coordinator address per CONTRACT.md: must parse as a full
 * http or https address with a host. Returns null when valid, or a plain
 * sentence naming what is wrong, for the page to show as a refusal. */
function sm_validate_coordinator_url($url) {
    $url = trim((string) $url);
    if ($url === '') {
        return 'The coordinator address is empty.';
    }
    $parts = parse_url($url);
    $scheme = is_array($parts) && isset($parts['scheme']) ? strtolower($parts['scheme']) : null;
    $host = is_array($parts) && isset($parts['host']) ? $parts['host'] : '';
    if ($scheme !== 'http' && $scheme !== 'https') {
        return 'The coordinator address must start with http:// or https://.';
    }
    if ($host === '') {
        return 'The coordinator address is missing a host.';
    }
    return null;
}

/* Validates and writes config.json as {"coordinatorUrl":"<url>"}. Returns
 * array('status' => 'ok'|'error', 'reason' => string|null). Never writes
 * on a validation failure. */
function sm_write_config($url) {
    $url = trim((string) $url);
    $error = sm_validate_coordinator_url($url);
    if ($error !== null) {
        return array('status' => 'error', 'reason' => $error);
    }
    $path = SM_SHOWMESH_STATE_DIR . '/config.json';
    $written = @file_put_contents($path, json_encode(array('coordinatorUrl' => $url)));
    if ($written === false) {
        return array('status' => 'error', 'reason' => 'The coordinator address could not be saved.');
    }
    return array('status' => 'ok', 'reason' => null);
}

/* Reads pairing-status.json. A missing file means the worker has never
 * changed pairing state, which is "not paired" rather than "unknown": the
 * worker only writes this file on a state change, so its absence on a
 * fresh install is expected, not a read failure. A present-but-malformed
 * file still degrades to unknown, since that is corruption, not absence. */
function sm_read_pairing_status() {
    $path = SM_SHOWMESH_STATE_DIR . '/pairing-status.json';
    if (!is_file($path) || !is_readable($path)) {
        return array('status' => 'ok', 'reason' => null, 'data' => array('state' => 'idle'));
    }
    $contents = @file_get_contents($path);
    if ($contents === false || trim($contents) === '') {
        return array('status' => 'ok', 'reason' => null, 'data' => array('state' => 'idle'));
    }
    $decoded = json_decode($contents, true);
    if (!is_array($decoded) || !isset($decoded['state'])) {
        return array('status' => 'unknown', 'reason' => 'malformed JSON', 'data' => null);
    }
    return array('status' => 'ok', 'reason' => null, 'data' => $decoded);
}

/* Reads pairing-code while a pairing is open. Returns null (not an
 * unknown-shaped array) when absent or malformed, since the page only
 * ever consults this alongside a 'waiting' pairing-status and has nothing
 * useful to say about it on its own. */
function sm_read_pairing_code() {
    $path = SM_SHOWMESH_STATE_DIR . '/pairing-code';
    if (!is_file($path) || !is_readable($path)) {
        return null;
    }
    $contents = @file_get_contents($path);
    if ($contents === false || trim($contents) === '') {
        return null;
    }
    $decoded = json_decode($contents, true);
    if (!is_array($decoded) || !isset($decoded['code'])) {
        return null;
    }
    return $decoded;
}

/* Writes pairing-request to ask the worker to start (or restart) pairing.
 * Returns true on success. */
function sm_write_pairing_request() {
    $path = SM_SHOWMESH_STATE_DIR . '/pairing-request';
    $written = @file_put_contents($path, json_encode(array('requestedAtMillis' => SM_SHOWMESH_NOW_MILLIS)));
    return $written !== false;
}

/* $millis is a millisecond timestamp. Returns null when it is not a
 * positive number, so callers render "unknown" instead of a bogus clock
 * time such as 1970's midnight. */
function sm_format_millis_time($millis, $format) {
    if (!is_numeric($millis) || $millis <= 0) {
        return null;
    }
    return date($format, (int) ((int) $millis / 1000));
}

/* Pulls the brightness readout fields (CONTRACT.md's plugin GET route
 * schema) out of a decoded brightness-state document, for the page's own
 * fallback render when the live plugin route is unreachable. Any field
 * the file does not carry renders as null (unknown), never a fabricated
 * zero. */
function sm_brightness_readout($data) {
    return array(
        'ceiling' => sm_field($data, 'lastAppliedCeiling'),
        'transitionGain' => sm_field($data, 'transitionGain'),
        'effectiveOutput' => sm_field($data, 'effectiveOutput'),
        'fadeActive' => sm_ceiling_fade_status($data) === 'running',
    );
}
