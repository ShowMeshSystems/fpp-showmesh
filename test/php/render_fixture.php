<?php
/* Runs the real plugin.php end to end against a fixture state directory
 * and prints the rendered HTML to stdout, so a shell test can grep the
 * actual page output rather than a function's return value.
 * $argv[1] = state directory, $argv[2] = repo root (plugin directory). */

define('SM_SHOWMESH_STATE_DIR', $argv[1]);
define('SM_SHOWMESH_PLUGIN_DIR', $argv[2]);
define('SM_SHOWMESH_NOW_MILLIS', 2000000000000);

chdir($argv[2]);
require $argv[2] . '/plugin.php';
