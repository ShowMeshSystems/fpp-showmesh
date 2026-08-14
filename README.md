# fpp-showmesh

An FPP (Falcon Player) plugin that registers a command an FPP schedule entry,
preset, or button can fire to ask a ShowMesh coordinator to run a macro, and
that records locally what happened.

## What this repository is

Packaging only. It holds plugin metadata, FPP integration glue, and the
install/upgrade/uninstall scripts that fetch, verify, and place a prebuilt
binary. It does not build anything, and it never vendors or commits that
binary.

## What this repository is NOT

There is no runtime implementation here. The plugin's actual behavior —
making the authenticated call to the coordinator, classifying the response,
writing the local status and failure records, caching a macro's fallback
policy — lives in a separately built Go binary that this repository's
`scripts/fpp_install.sh` downloads by version and architecture. This
repository does not contain that source and is not where a change to that
behavior belongs.

There is also no `Makefile` here, deliberately. FPP recompiles every plugin
directory containing one on every core upgrade, which would race a Go
binary this repository never built in the first place.

## The artifact contract

`scripts/fpp_install.sh` (and `scripts/fpp_upgrade.sh`, which shares its
core) fetch a release built and published elsewhere, named and laid out
like this:

- Release tag: `fpp-plugin-v<VERSION>`
- Per-architecture asset: `showmesh-fpp-plugin_<VERSION>_linux_<ARCH>.tar.gz`,
  where `<ARCH>` is one of `amd64`, `arm64`, `armv7`
- Each tarball contains exactly one file, `showmesh-fpp-plugin`, which the
  installer places at mode `0755`
- A checksum manifest, `showmesh-fpp-plugin_<VERSION>_SHA256SUMS`, in
  standard `sha256sum` format, covering every tarball in that release
- Default host:
  `https://github.com/ShowMeshSystems/showmesh/releases/download/fpp-plugin-v<VERSION>`

`<VERSION>` is read from the `VERSION` file at the root of this repository,
so bumping which release an installed plugin fetches is a one-line change
here, not a rebuild.

**Verification is not optional.** The installer downloads both the tarball
and its checksum manifest and refuses to install anything whose SHA-256
does not match the manifest entry for its exact filename.

### The bench override

`SHOWMESH_PLUGIN_ARTIFACT_BASE_URL`, if set, replaces the default host
above. This is how a bench environment points the installer at a local or
test artifact host instead of a public release. **Only the host varies.**
The filenames, the tag format, the manifest format, and the verification
step are identical whether this variable is set or not — there is no
separate bench-only code path to keep in sync with the real one.

## Never `uname -m` for architecture selection

A Raspberry Pi 4 or 5 can boot a 64-bit kernel under a 32-bit (armhf) FPP
userspace, in which case `uname -m` reports `aarch64` for a host that
actually needs the `armv7` artifact. `scripts/lib/arch.sh` instead reads two
independent signals and requires them to agree:

1. the ELF class byte of an actual FPP binary on the host (32-bit vs.
   64-bit), and
2. whether a 64-bit ARM dynamic linker is present on the host at all.

If the two disagree, the installer refuses to guess and names both
readings in its error message rather than silently shipping an artifact
that will not execute.

## Repository layout

```
pluginInfo.json              FPP's plugin manifest (strict JSON)
VERSION                      the release version scripts/fpp_install.sh fetches
commands/
  descriptions.json          registers the "ShowMesh: Run Macro" command
scripts/
  fpp_install.sh             fetch, verify, and place the binary; scaffold local state
  fpp_upgrade.sh             additive: same core as install, honored by FPP 10 only
  fpp_uninstall.sh           removes everything this plugin created outside its own directory
  preStart.sh                cheap repair check at fppd startup; a no-op in the common case
  run-macro.sh                the script FPP forks to fire a macro run
  lib/
    common.sh                 absolute-path tool resolution, logging, shared paths
    arch.sh                    the two-signal architecture probe
    fetch.sh                   artifact naming and download
    verify.sh                  checksum verification
    install-core.sh            the shared install/upgrade body
test/
  run_tests.sh                unit tests for the arch probe and checksum verification
```

## What each script does

- **`fpp_install.sh`** — called by FPP's Plugin Manager as root after it
  clones this repository into the plugin directory. Detects the host
  architecture, downloads the matching tarball and checksum manifest,
  verifies the checksum, extracts and installs the binary at mode `0755`,
  and creates the plugin's local state directory and files if they do not
  already exist. Never overwrites an existing credential or config on a
  re-run.
- **`fpp_upgrade.sh`** — the same core as install. FPP 10 calls this first
  on upgrade; FPP 9.x and earlier ignore it entirely and call
  `fpp_install.sh` again instead, so this script is purely additive.
- **`fpp_uninstall.sh`** — FPP deletes the plugin directory itself
  regardless of what this script returns, so this script's only job is
  everything outside that directory: the plugin's config directory,
  including its credential file. Idempotent; a second run, or a run
  against a host where install never completed, exits `0`.
- **`preStart.sh`** — runs at every `fppd` start. Checks whether the binary
  is present and executable and exits immediately if so — the common case
  must cost nothing on every boot. Only on a missing or non-executable
  binary (for example, an SD card image cloned from a host of a different
  architecture) does it re-run the fetch-and-verify path.
- **`run-macro.sh`** — the script FPP forks when the registered
  `ShowMeshRunMacro` command fires. Locates the installed binary and execs
  it with the macro id and the plugin's config paths; every command
  execution FPP fires is published in cleartext to its own MQTT
  `command/run` topic, so no credential is ever passed as a command
  argument.

## Paths this repository assumes about the installed plugin

- Config directory: `/home/fpp/media/config/plugin.fpp-showmesh/`
- Credential file: `<configdir>/credential`, mode `0600`, owned `fpp:fpp`,
  created empty by the installer and left for separate provisioning — this
  repository does not put a real credential on the host
- `<configdir>/config.json`, `status.json`, `failures.json`,
  `macro-cache.json` — created with empty defaults if absent, never
  overwritten if present
- The binary itself, installed to the plugin directory at mode `0755`

These paths, and the artifact contract above, are a pinned interface
between this repository and the binary it fetches. A change to either side
needs to change both.

## The command hand-off is provisional

`commands/descriptions.json` and `run-macro.sh` express this repository's
own choice for how the fired command reaches the binary (the command's
JSON shape, and the subcommand name and flags `run-macro.sh` invokes the
binary with). Neither has been checked against the binary's actual
argument parsing, because the two were built in parallel. This is the seam
most likely to need a small adjustment once both sides exist together, and
it is a one-file change on this side when that happens.

## What has not been verified

This repository has not been installed on a real FPP host. Everything
above about FPP's plugin manager mechanics — the exact invocation
convention for `fpp_install.sh`, `fpp_upgrade.sh`, `fpp_uninstall.sh`, and
`preStart.sh`; whether `commands/descriptions.json` is shaped exactly as
FPP expects; the candidate paths this repository probes for an FPP binary
and for the aarch64 dynamic linker; and the exact endpoint used to ask FPP
to pick up a new command definition — is written from documented and
inferred FPP behavior, not from having run this plugin.

What has been exercised, directly and repeatedly, on this machine, without
any FPP host involved:

- The architecture probe's ELF-class and dynamic-linker-presence logic,
  including the disagreement case in both directions, against synthetic
  fixtures.
- Checksum verification, including a genuinely tampered artifact and a
  missing manifest entry, both rejected.
- The full fetch → verify → extract → place pipeline, end to end, against
  a local HTTP server standing in for a release host, including its
  refusal of a tampered download.

`test/run_tests.sh` covers the first two. Running it does not require FPP,
root, or any of the paths above to exist; see the script for how it stubs
kernel and filesystem probes without touching real system paths.

None of this raises confidence in the on-host install path, filesystem
permissions, packaging shape, or cross-FPP-version behavior above
documented-and-inferred. Only running this against a real FPP instance
does that.

## Two things this repository does not solve

**Off-box reporting.** A plugin on this FPP host is going to make an
authenticated call to a coordinator the operator runs themselves. FPP's
plugin registry treats any off-box network call as suspect by default,
with a narrow exception for calls essential to the plugin's function. This
plugin's entire purpose is that call, but the determination of whether it
qualifies is made by a human reviewer at listing time, not by this
repository. Any submission should state the case plainly rather than
leave a reviewer to ask.

**Cross-project version compatibility.** FPP's plugin manifest can express
a version range against FPP itself and nothing else — there is no way to
declare "this plugin needs coordinator protocol version N or later." If
the plugin and the coordinator it talks to ever need to refuse an
incompatible pairing rather than fail confusingly, that check has to be
built into the plugin's own request/response handling, because FPP's
manifest format has no field for it. Nothing here builds that check; it is
an open obligation on whichever side implements the plugin's request
logic.

## License

Apache-2.0. See `LICENSE`.
