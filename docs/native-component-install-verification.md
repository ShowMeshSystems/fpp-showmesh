# Installing the resident component: what was verified, on what

Evidence for the install path that fetches, verifies, compiles, and activates
the resident C++ component. Recorded because this half of the install had never
run anywhere before, and because two of the things checked here contradicted
what was believed when the work started.

Verified 2026-08-24 against a containerized FPP 10.0 built from upstream tag
`10.0`, commit `370e62ed7e8c8318da6ee5b01312b8b75082d952`. Not on real
hardware; see "What this does not show".

## What FPP actually does with a plugin, read from source

Both release tags were cloned and read directly, because the previously
recorded rationale for shipping no root `Makefile` turned out to describe
behaviour neither version has.

- FPP 10.0 (`370e62ed7e8c8318da6ee5b01312b8b75082d952`) and FPP 9.5.3
  (`7979a4bb0bb9068fea71f3b447e273d5c0ea01e3`) contain **no** code that runs
  `make` on a plugin directory. Every `Makefile` reference in either tree is
  BeagleBone cape-overlay or WiFi-driver work.
- `www/api/controllers/plugin.php` resolves `scripts/fpp_install.sh`, falling
  back to a root `fpp_install.sh`. On FPP 10 the post-pull step runs
  `fpp_upgrade.sh` if present, else `fpp_install.sh`. FPP 9.5.3 has no
  `fpp_upgrade.sh` handling at all.
- `src/Plugins.cpp` only ever `dlopen`s a path. FPP never builds the object.
- `PluginManager::loadPlugin` returns success and loads nothing when the plugin
  directory has no `callbacks` file. That, not `pluginInfo.json`, is what makes
  a C++ component loadable.
- `PluginManager::loadUserPlugin` forks `callbacks` and reads its stdout as a
  comma-separated type list. `ScriptFPPPlugin`'s constructor consumes `media`,
  `playlist`, and `lifecycle` into script callbacks, and the `dlopen` branch is
  only reached when `hasCallback()` is false. Declaring any of those three
  alongside `c++` would silently prevent the shared library from ever loading.
- The object name defaults to `lib<plugin-directory-name>.so` unless
  `callbacks` names one after `c++:`.

## Two things that were wrong before this was checked

**FPP's generated version helper defines `getFPPMajorVersion()` twice.** On the
real image, `/opt/fpp/www/fppversion.php` contains two identical definitions,
so a naive extraction yields `10\n10` rather than `10`. `sm_fpp_major` takes
only the first line for that reason; without it the value would have failed the
adapter lookup and refused the install on a perfectly healthy FPP 10 host.
Observed, not anticipated.

**libcurl development headers are present, at a multiarch path.** An initial
probe for `/usr/include/curl/curl.h` reported them missing and that was wrong:
`libcurl4-openssl-dev` is installed on the stock image and the header is at
`/usr/include/aarch64-linux-gnu/curl/curl.h`. The compile succeeding is what
exposed the bad probe. So the adapter Makefile's note that libcurl is not a new
dependency on an FPP host holds for compiling as well as linking, on this
image.

## Observed on the stock FPP 10.0 image

| Prerequisite | Observed |
| --- | --- |
| `/opt/fpp/www/fppversion.php` | present, major reads `10` |
| `/opt/fpp/src` headers | present |
| `make`, `c++` | `/usr/bin/make`, `/usr/bin/c++` |
| `libcurl4-openssl-dev` | installed (`8.14.1-2+deb13u4`) |
| `pkg-config --cflags jsoncpp` | `-I/usr/include/jsoncpp` |
| `fpp` user | present |

## End to end, on a real FPP 10.0

The install script was run against a locally built fixture release served over
plain http, with `SM_REQUIRE_NATIVE=1` so a native failure would fail the run
rather than degrade:

```
[fpp-showmesh] detected architecture: arm64
[fpp-showmesh] installed showmesh-fpp-plugin 0.1.0 (arm64) to .../showmesh-fpp-plugin
[fpp-showmesh] detected FPP major version 10; building adapter fpp10
[fpp-showmesh] compiling the resident component (fpp10) against /opt/fpp/src
[fpp-showmesh] installed the resident component (libshowmesh-fpp10.so, FPP 10) to .../libfpp-showmesh.so
[fpp-showmesh] install complete
```

The activated object was `fpp:fpp` mode 0755 and exported `createPlugin`,
`fpp_plugin_api_version`, and `fpp_plugin_supports_unload`. No `.staging` or
`.previous` file was left behind, and no failure marker was written.

**A real fppd then loaded it**, which is the part that matters:

```
Plugins.cpp:523: Found Plugin: (fpp-showmesh)
Plugins.cpp:558: Processing Callbacks (.../fpp-showmesh/callbacks) for plugin: 'fpp-showmesh'
settings.cpp:178: Registered settings listener for ShowMeshChannelRanges setting with id fpp-showmesh
Plugins.cpp:775: Plugin fpp-showmesh supports unloading
Plugins.cpp:359: Plugin fpp-showmesh registered 2 command(s)
```

No plugin load errors. The settings-listener line is the resident component's
own constructor running inside fppd, and "supports unloading" means the Plugin
API 6 ABI gate accepted the object on the real 10.0 release, not on a beta.

## Compile failure degrades honestly

Re-run with one deliberate syntax error injected into the bundled source:

- The compiler diagnostic was surfaced in the install log between explicit
  begin and end markers.
- The macro helper stayed installed and executable.
- `native-install-failed.txt` was written on the host with the reason, so the
  failure outlives the install output.
- No object, no `.staging`, no `.previous`: nothing half-installed.
- The run exited 0, because the helper genuinely did install; with
  `SM_REQUIRE_NATIVE=1` the same failure exited 1.

## What this does not show

- **No real hardware.** This is a container under x86_64-on-arm64 emulation, not
  a Raspberry Pi. Compile duration on a Pi is unmeasured, and it is the one
  number an operator will care about during an install window.
- **No published release.** The fixture tarballs were built locally and hashed
  into a scratch copy of `artifacts.lock.json`. The committed lock still holds
  placeholder hashes, and a real install remains blocked on a real release.
- **No FPP 9 run of this path.** The adapter selection for major 9 is unit
  tested, and the FPP 9 adapter is exercised by the plugin repository's own
  load bench, but the install script's native path was not run end to end on a
  9.5.3 container.
- **No credential, in this install run.** The install creates an empty
  credential file by design. A provisioned credential and an observation
  actually reaching a coordinator came later, in the section below.
- **fppd was not restarted into a running show.** The installer deliberately
  never restarts fppd; a newly activated object is only picked up on the
  operator's own reload.

## End to end with a real coordinator: an observation was accepted

Run 2026-08-24, after the install above, on the same containerized FPP 10.0
with its normal web stack up. A coordinator built from `main` ran on the host
with a `scheduler` principal and a minted bearer token; the plugin was pointed
at it through `plugindata/fpp-showmesh/config.json` (`coordinatorUrl`) and the
credential at `/etc/showmesh-fpp-plugin/credential`, mode 0600.

One correction worth recording, because it cost a confusing cycle: fppd scans
`/home/fpp/media/plugins` at start, so an in-place restart issued while the
install was still finishing did not pick the plugin up, and the object sat on
disk unmapped. Restarting the container is what loaded it. `grep libfpp-showmesh
/proc/<fppd-pid>/maps` is the check that settles it, not the log, because the
plugin load lines are debug level and absent at the default level.

With the object mapped and `ShowMeshRunMacro` registered, starting a
three-entry playlist produced an **accepted** observation:

```
instanceUuid  M4-460b33e3d3834e8ead463fc22ed265da
playlistName  showmesh-obs   section MainPlaylist   position 2
playlistHash  bad718796026194456b8b2fba02df18591579b36cfde4a0633617be1aba3884f
entryKey      dd883c94081d03257cef9b96d6beb91a389299c3dd79fff2b289c77cbe896ff4
sequence      6    action query_next    coalescedSincePreviousAcknowledged 0
```

Acceptance is the load-bearing part: the coordinator re-derives the entry key
from the identity fields and refuses `400` when it disagrees, so an accepted
observation means both sides computed the same key independently.

The playlist definition was published as well and stored under the hash the
coordinator computed for itself, with all three entries enumerated through the
definition entries route.

**The sequence survived an fppd restart.** Before the restart the persisted
state held `8` in the primary and `7` in the backup, each with its own SHA-256.
After a full restart the next accepted observation carried sequence `14`, above
the pre-restart value, with the same `entryKey`. No `409`, and the coordinator
log and audit recorded no refusal of any class.

### Still not shown by this run

- **Brightness state was never persisted here**, because nothing ever set a
  ceiling or a gain, so there was nothing to write. That path has a unit
  acceptance test but was not exercised on a host.
- Still no real hardware, still a locally built fixture release rather than a
  published one, and still no FPP 9 run of the install script's native path.
- The coordinator ran without a broker. Nothing in this flow needs one, but a
  full show path does.
