<?php
/* Runs the real plugin.php end to end against a fixture state directory
 * and prints the rendered HTML to stdout. $argv[1] = state directory,
 * $argv[2] = repo root, $argv[3] = optional query string for $_GET,
 * $argv[4] = optional ShowMeshExcludeChannelRanges value and $argv[5] =
 * optional ShowMeshChannelRanges value, standing in for the $settings
 * array FPP's own plugin.php has in scope. */

define('SM_SHOWMESH_STATE_DIR', $argv[1]);
define('SM_SHOWMESH_PLUGIN_DIR', $argv[2]);
define('SM_SHOWMESH_NOW_MILLIS', 2000000000000);

if (isset($argv[3]) && $argv[3] !== '') {
    parse_str($argv[3], $_GET);
}

if (isset($argv[4])) {
    $settings = array('ShowMeshExcludeChannelRanges' => $argv[4]);
}
if (isset($argv[5])) {
    $settings['ShowMeshChannelRanges'] = $argv[5];
}

chdir($argv[2]);
require $argv[2] . '/plugin.php';
