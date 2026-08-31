<?php
/* ShowMesh status page. Read-only: reads fixed absolute paths, escapes
 * every rendered value, never accepts request input, writes nothing. */

require_once __DIR__ . '/lib.php';

$smVersion = sm_read_version();
$smBrightness = sm_read_brightness_state();
$smObservation = sm_read_observation_status();
?>
<!DOCTYPE html>
<html lang="en">
<head>
<?php if (is_file('common/menuHead.inc')) { include 'common/menuHead.inc'; } ?>
<title>ShowMesh Status</title>
</head>
<body>
<div id="bodyWrapper">

<h1>ShowMesh Status</h1>

<table>
<tr><th>Plugin version</th><td><?php echo $smVersion !== null ? sm_h($smVersion) : 'unknown'; ?></td></tr>
<tr><th>Instance ID</th><td><?php
    if ($smBrightness['status'] === 'ok') {
        $instanceId = sm_field($smBrightness['data'], 'instanceId');
        echo $instanceId !== null ? sm_h($instanceId) : 'unknown';
    } else {
        echo 'unknown (' . sm_h($smBrightness['reason']) . ')';
    }
?></td></tr>
</table>

<h2>Brightness ceiling</h2>
<?php if ($smBrightness['status'] === 'ok'):
    $b = $smBrightness['data'];
    $lastApplied = sm_field($b, 'lastAppliedCeiling');
    $fadeStatus = sm_ceiling_fade_status($b);
?>
<table>
<?php if ($smBrightness['source'] === 'backup'): ?>
<tr><th>Source</th><td>brightness-state.bak (primary state file failed to parse)</td></tr>
<?php endif; ?>
<tr><th>Applied ceiling</th><td><?php echo $lastApplied !== null ? sm_h($lastApplied) : 'unknown'; ?></td></tr>
<tr><th>Fade</th><td><?php
    if ($fadeStatus === 'running') {
        echo 'in progress, target ' . sm_h(sm_field($b, 'ceilingTarget'));
    } elseif ($fadeStatus === 'finished') {
        echo 'finished';
    } else {
        echo 'none';
    }
?></td></tr>
</table>
<?php else: ?>
<p>unknown (<?php echo sm_h($smBrightness['reason']); ?>)</p>
<?php endif; ?>

<h2>Observer</h2>
<?php if ($smObservation['status'] === 'ok'):
    $o = $smObservation['data'];
    $configured = sm_field($o, 'configured');
?>
<table>
<tr><th>Configured</th><td><?php echo $configured === true ? 'yes' : ($configured === false ? 'no' : 'unknown'); ?></td></tr>
<?php if ($configured === false): ?>
<tr><th>Configuration error</th><td><?php echo sm_h(sm_field($o, 'configurationError')); ?></td></tr>
<?php endif; ?>
<tr><th>Last outcome</th><td><?php echo sm_h(sm_field($o, 'lastOutcome')); ?></td></tr>
<tr><th>Last status code</th><td><?php echo sm_h(sm_field($o, 'lastStatusCode')); ?></td></tr>
<tr><th>Last error</th><td><?php echo sm_h(sm_field($o, 'lastError')); ?></td></tr>
</table>
<?php else: ?>
<p>unknown (<?php echo sm_h($smObservation['reason']); ?>)</p>
<?php endif; ?>

</div>
<?php if (is_file('common/footer.inc')) { include 'common/footer.inc'; } ?>
</body>
</html>
