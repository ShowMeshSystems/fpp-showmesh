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
