<?php
/* ShowMesh status and control page. Reads and writes only the state files
 * CONTRACT.md names (config.json, pairing-request, pairing-status.json,
 * pairing-code); never touches the credential file or any token. Every
 * rendered value is escaped. */

require_once __DIR__ . '/lib.php';

/* The live brightness readout's own fallback: JS calls this when
 * /api/plugin-apis/showmesh/brightness 404s, since that route is served
 * by the resident worker, not this page. */
if (isset($_GET['smAjax']) && $_GET['smAjax'] === 'brightness') {
    header('Content-Type: application/json');
    $smBrightness = sm_read_brightness_state();
    if ($smBrightness['status'] === 'ok') {
        echo json_encode(sm_brightness_readout($smBrightness['data']));
    } else {
        echo json_encode(array('error' => $smBrightness['reason']));
    }
    exit;
}

$smConfigError = null;
$smConfigSaved = false;
if (isset($_SERVER['REQUEST_METHOD']) && $_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['smAction'])) {
    if ($_POST['smAction'] === 'save-config') {
        $result = sm_write_config(isset($_POST['coordinatorUrl']) ? $_POST['coordinatorUrl'] : '');
        if ($result['status'] === 'ok') {
            $smConfigSaved = true;
        } else {
            $smConfigError = $result['reason'];
        }
    } elseif ($_POST['smAction'] === 'pair') {
        sm_write_pairing_request();
    }
}

$smVersion = sm_read_version();
$smBrightness = sm_read_brightness_state();
$smObservation = sm_read_observation_status();
$smConfig = sm_read_config();
$smPairing = sm_read_pairing_status();
$smPairingState = $smPairing['status'] === 'ok' ? sm_field($smPairing['data'], 'state') : 'idle';
$smCoordinatorUrl = $smConfig['status'] === 'ok' ? sm_field($smConfig['data'], 'coordinatorUrl') : '';
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

<h2>Coordinator</h2>
<?php if ($smConfigSaved): ?>
<p>The coordinator address was saved. The plugin picks it up automatically, no restart needed.</p>
<?php elseif ($smConfigError !== null): ?>
<p><?php echo sm_h($smConfigError); ?> Nothing was saved.</p>
<?php endif; ?>
<form method="post">
<input type="hidden" name="smAction" value="save-config">
<label for="smCoordinatorUrl">Coordinator address</label>
<input type="text" id="smCoordinatorUrl" name="coordinatorUrl" size="40"
    value="<?php echo sm_h($smCoordinatorUrl !== null ? $smCoordinatorUrl : ''); ?>">
<button type="submit">Save</button>
</form>

<h2>Pairing</h2>
<?php if ($smPairingState === 'waiting'):
    $smCode = sm_read_pairing_code();
?>
<p>Waiting for the coordinator to confirm pairing.</p>
<?php if ($smCode !== null): ?>
<p class="sm-pairing-code"><?php echo sm_h(sm_field($smCode, 'code')); ?></p>
<?php $smExpires = sm_format_millis_time(sm_field($smCode, 'expiresAtMillis'), 'H:i:s'); ?>
<p>Expires at <?php echo $smExpires !== null ? sm_h($smExpires) : 'unknown'; ?>.</p>
<?php endif; ?>
<?php elseif ($smPairingState === 'paired'):
    $smPairedAt = sm_format_millis_time(sm_field($smPairing['data'], 'pairedAtMillis'), 'H:i');
?>
<p>This FPP is paired with the coordinator<?php echo $smPairedAt !== null ? ', as of ' . sm_h($smPairedAt) . '.' : '.'; ?></p>
<form method="post">
<input type="hidden" name="smAction" value="pair">
<button type="submit">Pair with coordinator</button>
</form>
<?php elseif ($smPairingState === 'expired'): ?>
<p>The pairing code expired before the coordinator confirmed it.</p>
<form method="post">
<input type="hidden" name="smAction" value="pair">
<button type="submit">Pair with coordinator</button>
</form>
<?php elseif ($smPairingState === 'failed'): ?>
<p>Pairing failed: <?php echo sm_h(sm_field($smPairing['data'], 'lastError')); ?>.</p>
<form method="post">
<input type="hidden" name="smAction" value="pair">
<button type="submit">Pair with coordinator</button>
</form>
<?php else: ?>
<p>This FPP is not paired with a coordinator.</p>
<form method="post">
<input type="hidden" name="smAction" value="pair">
<button type="submit">Pair with coordinator</button>
</form>
<?php endif; ?>

<h2>Brightness ceiling</h2>
<?php
$lastApplied = $smBrightness['status'] === 'ok' ? sm_field($smBrightness['data'], 'lastAppliedCeiling') : null;
if ($smBrightness['status'] === 'ok'):
    $b = $smBrightness['data'];
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

<p>
<label for="smCeiling">Brightness ceiling (percent)</label>
<input type="range" id="smCeiling" min="0" max="100" step="1"
    value="<?php echo is_numeric($lastApplied) ? (int) $lastApplied : 0; ?>">
</p>
<table>
<tr><th>Ceiling</th><td id="smReadoutCeiling">unknown</td></tr>
<tr><th>Transition gain</th><td id="smReadoutTransitionGain">unknown</td></tr>
<tr><th>Effective output</th><td id="smReadoutEffectiveOutput">unknown</td></tr>
<tr><th>Fade</th><td id="smReadoutFade">unknown</td></tr>
</table>

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
<script>
(function () {
    "use strict";
    var ceiling = document.getElementById("smCeiling");
    var readout = {
        ceiling: document.getElementById("smReadoutCeiling"),
        transitionGain: document.getElementById("smReadoutTransitionGain"),
        effectiveOutput: document.getElementById("smReadoutEffectiveOutput"),
        fade: document.getElementById("smReadoutFade")
    };
    var fallbackUrl = window.location.pathname + window.location.search +
        (window.location.search ? "&" : "?") + "smAjax=brightness";
    var debounceTimer = null;

    function percent(value) {
        return (value === null || value === undefined || value === "") ? "unknown" : value + "%";
    }

    function renderReadout(data) {
        if (!data || data.error) {
            return;
        }
        readout.ceiling.textContent = percent(data.ceiling);
        readout.transitionGain.textContent = percent(data.transitionGain);
        readout.effectiveOutput.textContent = percent(data.effectiveOutput);
        readout.fade.textContent = data.fadeActive === true ? "in progress" : (data.fadeActive === false ? "none" : "unknown");
    }

    function pollReadout() {
        fetch("/api/plugin-apis/showmesh/brightness")
            .then(function (response) {
                if (response.status === 404) {
                    return fetch(fallbackUrl).then(function (r) { return r.json(); });
                }
                return response.json();
            })
            .then(renderReadout)
            .catch(function () {});
    }

    function sendCeiling(value) {
        fetch("/api/command", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ command: "ShowMesh: Set Brightness Ceiling", args: [String(value)] })
        }).catch(function () {});
    }

    if (ceiling) {
        ceiling.addEventListener("input", function () {
            var value = ceiling.value;
            if (debounceTimer) {
                clearTimeout(debounceTimer);
            }
            debounceTimer = setTimeout(function () { sendCeiling(value); }, 250);
        });
    }

    pollReadout();
    setInterval(pollReadout, 3000);
})();
</script>
<?php if (is_file('common/footer.inc')) { include 'common/footer.inc'; } ?>
</body>
</html>
