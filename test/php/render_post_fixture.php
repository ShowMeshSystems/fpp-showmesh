<?php
/* Simulates a POST to plugin.php and prints whatever it writes to stdout,
 * so a shell test can assert the redirect-after-post path never renders
 * the page body (headers_list() reports nothing under the CLI SAPI, so
 * this checks the observable stand-in: no HTML reaches the client).
 * $argv[1] = state dir, $argv[2] = repo root, $argv[3] = request URI,
 * $argv[4] = POST body as a query string (e.g. "smAction=pair"). */

define('SM_SHOWMESH_STATE_DIR', $argv[1]);
define('SM_SHOWMESH_PLUGIN_DIR', $argv[2]);
define('SM_SHOWMESH_NOW_MILLIS', 2000000000000);

$_SERVER['REQUEST_METHOD'] = 'POST';
$_SERVER['REQUEST_URI'] = $argv[3];
parse_str($argv[4], $_POST);

chdir($argv[2]);
require $argv[2] . '/plugin.php';
