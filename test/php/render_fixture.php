<?php
/* Runs the real plugin.php end to end against a fixture state directory
 * and prints the rendered HTML to stdout. $argv[1] = state directory,
 * $argv[2] = repo root, $argv[3] = optional query string for $_GET. */

define('SM_SHOWMESH_STATE_DIR', $argv[1]);
define('SM_SHOWMESH_PLUGIN_DIR', $argv[2]);
define('SM_SHOWMESH_NOW_MILLIS', 2000000000000);

if (isset($argv[3]) && $argv[3] !== '') {
    parse_str($argv[3], $_GET);
}

chdir($argv[2]);
require $argv[2] . '/plugin.php';
