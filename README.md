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

There is also no root `Makefile` here, and the original reason for that was
correct: FPP really does compile any plugin directory that contains one, on
every core upgrade.

`compileBinaries()` in `scripts/functions` loops `${MEDIADIR}/plugins/*` and,
for each directory holding a `Makefile`, runs
`make -C "${p}" -f "${p}/Makefile" -j ${CPUS} SRCDIR=${FPPDIR}/src`, then
`chown -R` over that whole plugin directory. `cleanCompiledBinaries()` runs
the same loop with `clean`. Both are present in FPP 9.5.3
(`7979a4bb0bb9068fea71f3b447e273d5c0ea01e3`, `scripts/functions:667` and
`:481`) and FPP 10.0 (`370e62ed7e8c8318da6ee5b01312b8b75082d952`,
`scripts/functions:515` and `:59`), and `compileBinaries` is reached from
`scripts/upgrade_FPP`, `scripts/git_pull` and `scripts/git_branch`, which are
the core-upgrade paths.

So adding a root `Makefile` here would opt this plugin into FPP building it
on every core upgrade, against that host's `SRCDIR`, with no say over when.
For a repository whose binary is fetched prebuilt and verified against a
committed digest, that is a second, unverified way for a binary to appear.
Do not add one.

None of that changes where the resident component is compiled, because the
compile hook this repository uses is a different mechanism: FPP runs this
plugin's own scripts, by design. `www/api/controllers/plugin.php` resolves
`scripts/fpp_install.sh` (falling back to a root `fpp_install.sh`), and on
FPP 10 the post-pull step runs `fpp_upgrade.sh` if present, else
`fpp_install.sh`. FPP 9.5.3 has no `fpp_upgrade.sh` handling at all.
`src/Plugins.cpp` only ever `dlopen`s a path; FPP never builds the object.

Two consequences worth knowing before changing the install path:

- `callbacks` is what makes the resident C++ component loadable at all. A
  plugin directory with no `callbacks` file loads nothing, and FPP reports
  that as success. See that file's own comment for why it prints `c++` and
  nothing else.
- fppd resolves the shared object as `lib<plugin-directory-name>.so`,
  `libfpp-showmesh.so` here, unless `callbacks` names one after `c++:`.
  Install-time FPP-major detection is what decides which built adapter
  (`libshowmesh-fpp9.so` or `libshowmesh-fpp10.so`) takes that name.

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

**Verification is not optional, and it is not against a downloaded
manifest.** `artifacts.lock.json`, committed at this repository's own
root, is the trust anchor: for the pinned `VERSION`, it records each
tarball's exact filename and expected SHA-256, and the installer refuses
to install anything whose downloaded bytes do not match the lock entry
for that exact filename; a missing lock, a version-mismatched lock, or
several specific malformed shapes within the matching artifact entry
(no match for the requested filename, a missing or misordered "sha256"
field, more than one "sha256" occurrence, an empty or non-hex hash
value, or more than one entry naming the same filename) all refuse the
install outright rather than falling back to anything else. The lookup
is a grep/sed reader, not a full JSON parser, and a malformed lock
outside those specific shapes is not guaranteed to be refused: an
artifact object closed early by a stray brace, or a truncated file, can
still return a hash read from outside the intended object at exit 0;
see `scripts/lib/lock.sh` for exactly what is and is not caught. This is
a deliberate change from checking a `SHA256SUMS` manifest
fetched from the same base URL as the tarball: that manifest and the
tarball both arrive over the same connection, so a compromised or
redirected host can make them agree with each other regardless of what
either actually contains, which checking one against the other cannot
catch. `artifacts.lock.json` arrives with this repository's own checked-
out tree, under FPP's control when it clones the plugin, not over curl,
so it is a hash source a compromised download host cannot also serve. A
`SHA256SUMS` manifest may still be published alongside a release, but
nothing in the installer treats it as authoritative any more; see
`scripts/lib/lock.sh` and `scripts/lib/verify.sh`.

**The default URL above resolves to nothing today.** CI for the binary
this installer fetches builds and self-verifies all three architectures'
artifacts, and — by the owner's decision — publishes none of them yet.
So a fresh install against the default host, with no override set, will
fail at the download step until a release is actually published.
Publication is enabled when the plugin first targets real hardware.

### The bench override

The default host above can be replaced two ways, checked in this order:
`SHOWMESH_PLUGIN_ARTIFACT_BASE_URL`, then an override file, then the
pinned default if neither is set. **Only the host varies.** The filenames,
the tag format, the manifest format, and the verification step are
identical no matter which of the three is in effect; there is no separate
bench-only code path to keep in sync with the real one.

**The environment variable does not reach a fresh install.** FPP's Plugin
Manager runs a fresh install's `fpp_install.sh` under plain `sudo`, not
`sudo -E`, so `sudo` builds a new environment containing only the two
values FPP passes explicitly and discards everything else, including
`SHOWMESH_PLUGIN_ARTIFACT_BASE_URL` however it was set (shell export,
container environment, `/etc/environment`). An upgrade is different:
`plugin.php`'s upgrade path exports `FPPDIR` and calls `sudo -E`, which
does preserve the environment, so the variable still works there. See
"How `FPPDIR` actually arrives" below for the source read this rests on.

For a fresh install, use the override file instead:
`$(sm_state_dir)/artifact-base-url`, which on a stock host is
`/home/fpp/media/plugindata/fpp-showmesh/artifact-base-url`. Write the
target base URL as its only content, as root, before installing the
plugin through FPP's Plugin Manager. That directory is not the plugin
directory (which the Plugin Manager only creates during install, too late
for an operator to stage anything in it); it is the plugin's own state
directory under FPP's media tree, which an operator can create ahead of
time with plain `mkdir -p` and `ssh` access, and which the installer's own
scaffold step also creates before it reads this file if it is not already
there. The file is trimmed of all whitespace before use; empty or
whitespace-only content is treated the same as the file being absent.

**Pointing this at a bench host is not, by itself, enough to make a bench
install pass.** `artifacts.lock.json` as committed to this repository
carries the real `sha256` digests of one specific set of built artifacts
(see the lock file's own `"note"` field for which build they came from).
Those artifacts are a private candidate build rather than a published
release, so this does not contradict the paragraph above: the default
host still serves nothing for this version. Real digests mean the lock
is a usable trust anchor for a bench that serves that exact build, and
for the same build if it is published later.
Verification is against this committed lock, never against anything
fetched from the bench host itself (see "The artifact contract" above).
So a bench install passes the checksum step only when the tarball the
bench host serves is byte-for-byte the artifact the lock names, and fails
it every time otherwise. There is no tooling in this repository that
regenerates the lock automatically; it means hand-editing
`artifacts.lock.json`'s `artifacts[]` array so each entry's `sha256` is
the real digest of the bench tarball it names (`sha256sum` against the
actual file the bench host serves, or the real per-artifact digest from
the `release-manifest.json` of whatever built that tarball) and its
`version` matches the `VERSION` file at this repository's root. Do this
before attempting a bench install, not after one fails confusingly on a
checksum mismatch.

The override must still carry an explicit `http://` or `https://` scheme
— a bare host with no scheme is rejected rather than silently mishandled.
A plain `http://` override is accepted (the bench needs it) but logged
plainly rather than passed through silently, since the default host is
always `https://` and a scheme-downgraded override should be visible in
the install log, not just in the URL string a human would have to go
looking for.

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

**This method answers exactly one question — 64-bit kernel hiding a
32-bit userspace — and no other.** It cannot distinguish ARM instruction
set *versions*: the ELF class byte is a 32- vs 64-bit flag, not an ARMv6
vs ARMv7 flag. A first pass of this file ran ARMv6 hosts (`uname -m`
reporting `armv6l` directly — a Pi 1 or Pi Zero) through the same
disambiguation path as `aarch64`, found "agreement" at 32-bit, and
answered `armv7` — the one answer certainly wrong for that hardware, from
the one module whose entire premise is refusing to guess. `armv6l` is now
refused outright, before any probing, and a literal `armv7l` report from
the kernel is answered directly with no probing at all, because a 32-bit
kernel cannot itself be hiding a 64-bit userspace — the ambiguity this
method resolves only exists for a 64-bit kernel report.

## Repository layout

```
pluginInfo.json              FPP's plugin manifest (strict JSON)
VERSION                      the release version scripts/fpp_install.sh fetches
artifacts.lock.json          the trust anchor: expected filename/sha256 per artifact for VERSION
docs/
  bench-capture-fpp-9.5.3.md  file paths, line numbers, and quoted source for every
                              claim below marked "confirmed against FPP 9.5.3"
commands/
  descriptions.json          registers the "ShowMesh: Run Macro" command (a JSON array)
  run-macro.sh                the script FPP forks to fire a macro run — lives here,
                              not under scripts/, because FPP resolves a command's
                              "script" relative to commands/
scripts/
  fpp_install.sh             validate, fetch, verify, and place the binary; scaffold local state
  fpp_upgrade.sh             additive: same core as install, honored by FPP 10 only
  fpp_uninstall.sh           removes the credential, state, and scaffold-staging directories this
                              plugin created outside its own directory
  preStart.sh                cheap repair check at fppd startup; a no-op in the common case
  lib/
    common.sh                 absolute-path tool resolution, logging, shared paths, mode/owner verification
    arch.sh                    the two-signal architecture probe, plus the arch-stamp comparison
    fetch.sh                   artifact naming, download, base-URL scheme enforcement
    verify.sh                  checksum verification (both a manifest-based check and the
                              lock-anchored sm_verify_sha256 the installer actually trusts)
    commands.sh                validates descriptions.json against the scripts it names
    lock.sh                    looks up the expected sha256 for a filename from artifacts.lock.json
    activate.sh                 stage-then-swap binary activation with rollback
    install-core.sh            the shared install/upgrade body
test/
  run_tests.sh                unit tests: arch probe, checksum verification, lock lookup,
                              stage/activate rollback, the sm_install_binary / sm_install_or_upgrade
                              pipeline end to end (network calls shadowed), command-script
                              validation, sm_fppdir, URL scheme, mode verification, the
                              preStart.sh repair-decision function, committed executable
                              bits, and this repo's own shipped descriptions.json
```

## What each script does

- **`fpp_install.sh`** — called by FPP's Plugin Manager as root after it
  clones this repository into the plugin directory. First validates that
  every script named in `commands/descriptions.json` exists and is
  executable (see below), entirely locally and before any network access.
  Then detects the host architecture, looks up the expected SHA-256 for
  that architecture's tarball in `artifacts.lock.json`, downloads the
  tarball and verifies it against that lock entry, extracts it, stages the
  binary and validates the stage (mode `0755`, ownership) before ever
  touching the live target, then activates it with a single atomic rename
  that preserves the previous binary until the rename is known to have
  succeeded (see "The artifact contract" and `scripts/lib/activate.sh`).
  It also creates the plugin's credential directory and non-secret state
  directory (two separate locations — see "Paths" below) and their files
  if they do not already exist. Never overwrites an existing credential or
  config on a re-run.
- **`fpp_upgrade.sh`** — the same core as install, including the same
  command-script validation. FPP 10 calls this first on upgrade; FPP 9.x
  and earlier ignore it entirely and call `fpp_install.sh` again instead,
  so this script is purely additive.
- **`fpp_uninstall.sh`** — FPP deletes the plugin directory itself
  regardless of what this script returns, so this script's only job is
  everything outside that directory. That is **three** separate
  locations, not one (see "Paths" below for why the first two are
  split): the credential directory, the non-secret state directory, and
  the root-only scaffold staging directory
  (`sm_scaffold_stage_root()`) that install/upgrade/repair creates under
  `/etc` and nothing else on the host ever cleans up. Idempotent; a
  second run, or a run against a host where install never completed,
  exits `0`.
- **`preStart.sh`** — runs at every `fppd` start, and its two checks are
  both purely local (a file test, plus a handful of local file reads for
  architecture detection — never the network), so they cost nothing on
  every boot; only an actual repair reaches the network. It repairs on
  either of two conditions: the binary missing or not executable at all,
  or the binary present and executable but stamped with a different
  architecture than a fresh detection now reports — exactly what a disk
  image cloned from a host of a different architecture produces, and a
  case a plain `[ -x ]` check cannot see (a cloned binary is present and
  executable; it is just wrong). Either condition re-runs the full
  install/upgrade path, not only the binary fetch, so a repair also
  re-scaffolds permissions, and its network calls use a much tighter
  timeout budget than a foreground, human-initiated install, since this
  blocks `fppd` starting and must not eat minutes of a networkless boot.
  There is no local, networkless repair path: an earlier version of this
  script tried promoting a preserved `.previous` or `.staging` binary
  before reaching the network, gated on a sha256 recorded next to the
  binary, but that recorded hash sat in the same, equally writable
  directory as the candidate it was meant to authorize, and the
  promotion itself followed symlinks through `stat`, the hash check, and
  `mv -f`. Both are real root-privilege escalation paths on a directory
  this project does not otherwise treat as trusted, and the crash window
  local repair existed to cover — the old two-rename activation briefly
  leaving the target unoccupied — is already closed by the hard-linked
  backup and single atomic rename this repository now uses instead, so
  the tradeoff no longer has a justification. A missing or wrong binary
  now always waits for the network repair above.
- **`commands/run-macro.sh`** — the script FPP forks when the registered
  `ShowMeshRunMacro` command fires. Locates the installed binary and execs
  `showmesh-fpp-plugin run --config-dir <statedir> -- <macroId>`; every
  command execution FPP fires is published in cleartext to its own MQTT
  `command/run` topic, so no credential is ever passed as a command
  argument, and the binary's credential path is not configurable at all
  (see below). The `--` before the macro id keeps an id that happens to
  start with a hyphen from being misread as a flag.

## A wrong `script` filename makes a command silently vanish

`commands/descriptions.json` is a JSON array; each element is handed
straight to FPP's `ScriptCommand`, which reads exactly two fields —
`name`, and `script`, resolved relative to `commands/` and stripped from
what is exposed to the UI and API. Everything else in the object passes
through untouched as the command's description, which is why
`descriptions.json` below carries a `displayName`, a `displayHint`, and an
`args[]` array shaped to match what a live FPP instance actually returns
from `GET /api/commands` (`name`, `description`, `type`, `optional`, and
optionally `default`, `allowBlanks`, `contentListUrl`).

FPP's own existence check for `script` (`ScriptCommand::IsOk()`) is a
plain file-existence test — no error, no log line, no UI entry, and no
entry in `GET /api/commands` if it fails. It also does not check the
executable bit, so a script that exists but was committed non-executable
would pass that check and then fail silently the first time it is
actually fired, since a fired command reaches its script by `execve`,
which the kernel refuses on a non-executable file. `scripts/lib/commands.sh`
checks both conditions — existence and the executable bit — for every
`script` named in `descriptions.json`, and `fpp_install.sh`/
`fpp_upgrade.sh` fail the install loudly if either is wrong, before
attempting anything else. This exact mechanism is what caught
`run-macro.sh` initially being placed under `scripts/` instead of
`commands/` during this repository's own development — the case it is
here to prevent happening again, silently, on a real host.

## Paths this repository assumes about the installed plugin

The credential and the plugin's other state live in **two separate
locations**, not one — this changed during review, and the reason is
worth stating rather than just the new paths. FPP serves its own
`media/config/` tree **unauthenticated** over its own HTTP API: a `GET`
returns file contents with no credential check, and an unauthenticated
`POST` to the same endpoint can create subdirectories under it. A
credential living anywhere under that tree is one unauthenticated request
away from anything that can reach the FPP web UI — a strictly worse
exposure than the general cleartext-on-the-show-LAN posture this project
otherwise accepts for commands and telemetry, which is tolerated
specifically because it does not extend to secrets. `/etc` is outside
everything FPP's API serves, so the credential moved there and out of
FPP's tree entirely.

- **Credential directory:** `/etc/showmesh-fpp-plugin/`, mode `0700`,
  owned `fpp:fpp`.
- **Credential file:** `/etc/showmesh-fpp-plugin/credential`, mode `0600`,
  owned `fpp:fpp`, created empty by the installer and left for separate
  provisioning — this repository does not put a real credential on the
  host. Its path is not otherwise configurable: the binary always reads
  from exactly this file. (An earlier version of this document claimed
  this was true of the *whole* config directory and that there was
  "exactly one place on the host a token can end up" — that was false even
  at the time, since the binary's config-directory resolution has always
  accepted a flag, an environment variable, and a `MEDIADIR`-derived
  fallback ahead of a literal default. Only the credential's own path was
  ever fixed; the sentence overstated it to the whole directory. Splitting
  the credential out to a location with no resolution chain at all is
  what actually makes a strong version of that sentence true, and this is
  it.)
- **State directory:** `/home/fpp/media/plugindata/fpp-showmesh/`, mode
  `0700`, owned `fpp:fpp` — non-secret plugin state, staying under FPP's
  media tree since none of it is a credential.
- `<statedir>/config.json`, `status.json`, `failures.json`,
  `macro-cache.json` — created at mode `0600`, owned `fpp:fpp`, with empty
  defaults if absent, never overwritten if present. (0600 to match what
  the binary itself uses when it rewrites these files — an earlier version
  of the scaffold created them at `0644`, disagreeing with the binary from
  the moment install finished; picked one mode rather than leaving that
  standing.)
- `<statedir>/artifact-base-url`: not scaffolded by the installer, and
  present only if an operator wrote it there themselves before a fresh
  install; see "The bench override" above. Read, never created or
  overwritten, by `sm_artifact_base_url`.
- The binary itself, installed to the plugin directory at mode `0755`.
- `.installed-arch`, alongside the binary in the plugin directory —
  records which architecture was actually fetched, so `preStart.sh` can
  compare a fresh detection against it (see above). Gitignored, like the
  binary itself.
- **Scaffold staging directory:** `/etc/showmesh-fpp-plugin.stage`, mode
  `0700`, owned `root:root` — a third location outside the plugin
  directory, not a sibling of either directory above and never chowned
  to `fpp:fpp`; every credential and state file is prepared inside it
  before being renamed into place (see the trust-boundary section
  below). `fpp_uninstall.sh` removes it along with the credential and
  state directories.

Every `chown` and `chmod` in the scaffold is checked, and every `chmod` is
followed by reading the mode back rather than trusting the exit code
alone — a vfat or exFAT mount (FPP explicitly supports running its media
directory from a USB stick) reports `chmod` as successful while actually
deriving every file's mode from mount options, silently ignoring the
request. Catching that at install time is the difference between a clear
install failure and the binary refusing to start at showtime because a
0600 credential file measures as something else entirely.

These paths, and the artifact contract above, are a pinned interface
between this repository and the binary it fetches. A change to either side
needs to change both.

## The command hand-off, and what is and is not pinned

The binary's invocation contract is pinned by the team building it:
`showmesh-fpp-plugin run --config-dir <statedir> -- <macroId>`.
`commands/run-macro.sh` passes `--config-dir` explicitly with this
repository's own pinned state directory (see "Paths" above), so the binary
reads its non-secret config/status/failures/macro-cache files from exactly
where the installer scaffolds them, rather than depending on the binary's
own `MEDIADIR`-based resolution to land on the same place independently.
That choice — passing the flag rather than relying on the fallback — is
this repository's own decision, not something confirmed against a running
install. The credential is not part of `--config-dir` at all and has no
flag or resolution chain of its own: the binary reads it from one fixed
location (see "Paths" above), which is deliberate — a resolution chain is
exactly the kind of indirection that makes "where could this secret end up"
a harder question to answer, and the whole point of moving the credential
out of FPP's tree was to make that question have one answer.

## What has been verified, and what has not

This repository has not been installed on a real FPP host. But not
everything above rests on the same footing, and conflating the two tiers
would make the weaker one sound better than it is.

**Read from FPP 9.5.3's own source and confirmed against a running
containerized instance of it**, and nothing else stated in this README
carries that weight. `docs/bench-capture-fpp-9.5.3.md` is the committed
record of exactly which file, line, and quoted source each of these rests
on, so this list is checkable rather than asserted:

- `commands/descriptions.json`'s schema — a top-level JSON array, `name`
  and `script` are the only fields FPP's own code reads, `script` is
  resolved relative to `commands/` and stripped before exposure, and the
  `args[]` shape (`name`, `description`, `type`, `optional`, and
  optionally `default`, `allowBlanks`, `contentListUrl`) was checked
  against a live `GET /api/commands` response.
- The silent-drop behavior of a missing `script` file
  (`ScriptCommand::IsOk()`), and that it is an existence check only, not
  an executable-bit check.
- The fired-command exec environment: exactly `MEDIADIR`, `FPPDIR`,
  `SCRIPTDIR`, no `PATH`, arguments appended positionally after the
  script path.
- `preStart.sh`'s invocation: `/bin/bash <file>` with no arguments,
  inheriting `fppd_start`'s environment rather than the exec environment
  above.
- **How `FPPDIR` actually arrives at `fpp_install.sh`/`fpp_upgrade.sh`,
  and it is two different shapes, not one.** A fresh install
  (`scripts/install_plugin`) passes `FPPDIR=<dir>` as a literal argv
  word — not a shell assignment — with nothing exported. An upgrade
  (`www/api/controllers/plugin.php`) instead exports `FPPDIR` before
  invoking `sudo -E`, with `$1` arriving empty. `sm_fppdir` in
  `scripts/lib/common.sh` checks the environment first, then strips a
  `FPPDIR=` prefix from `$1`, then falls back to `/opt/fpp`, specifically
  because neither source alone covers both of FPP's own callers.
- **`sudo -E` preserves the environment across the Plugin Manager's own
  `sudo` call; it does not strip it.** This corrects a Fact previously
  recorded in this project's plugin-distribution research, which stated
  that the Plugin Manager "exports bare `sudo` rather than `sudo -E`,
  stripping the exported values." That was true of the fresh-install path
  only (which never exports `FPPDIR` regardless of `sudo -E`) and false of
  the upgrade path (which does export it, via exactly the `sudo -E` call
  the original Fact said did not happen). This repository's first pass
  built a rule directly on the stronger, false version — "never read
  `$FPPDIR` from the environment" — which forbade the one mechanism that
  actually works on the upgrade path. The rule is gone; both sources are
  checked now, in the order above.

**Still unverified, and this work does not change that**: the on-host
install path end to end, filesystem permissions and mount-option
interactions on a real image, behavior across an actual FPP major-version
upgrade, whether the candidate `fppd` and dynamic-linker paths
`scripts/lib/arch.sh` probes are correct on a real Pi, BeagleBone, or
PocketBeagle image, and whether `fpp:fpp` ownership and the credential/
state directory scaffold actually succeed against a real `fpp` system
user (nothing on this developer machine has one, so the scaffold's
`chown` calls have only been exercised as far as confirming they fail
loudly rather than silently, never as far as confirming they succeed).
Also still unverified: what FPP's restart-flag setting actually does when
called on a host that may be running a live show — which is exactly why
`sm_note_possible_restart_need` in `scripts/lib/install-core.sh` no longer
calls it automatically at all, and only logs a message telling the
operator to restart FPP themselves. The first version of this function
called that endpoint unattended and reasoned about only the failing case;
the case that was never examined was the call *succeeding* mid-show, and
without a confirmed answer for what that does, an unattended install or
upgrade is exactly the context where a bad outcome would go uncaught.

Also unverified in a different sense: `pluginInfo.json` declares support
from FPP 9.4 through a full FPP 10.x entry, but the bench evidence above
covers 9.5.3 only. FPP 8 is not supported and the floor is pinned at 9.4,
not lower: an earlier version of this document argued for reaching the
floor down to 8.4 on the strength of a prior finding that FPP's
install/uninstall scripts are byte-identical across the whole 8.4–9.4
range. That finding is about script identity, not about this plugin
having been exercised anywhere in the 8.4–9.3 span, and the accepted
support commitment for this project is FPP 9.4 through 9.x and FPP 10.x
only, so the `versions[]` entry now says exactly that instead of trading
on identical scripts to claim a wider floor than the project has agreed
to support.
**The FPP 10 entry carries no equivalent grounding.** FPP 10 restructures
install into two phases with a dependency-resolution callback and honors
`fpp_upgrade.sh` first rather than ignoring it — a genuinely different
install regime, none of which has been exercised here even at the source-
read level this section otherwise credits. The entry is kept because an
open-ended `maxFPPVersion` silently degrades to major-scoped and hidden
rather than erroring when a new FPP major appears, so omitting an FPP 10
entry is not a neutral choice either; keeping it and stating the limit
here is the honest version of keeping it silently.

What has been exercised, directly and repeatedly, on this machine, without
any FPP host involved:

- The architecture probe's ELF-class and dynamic-linker-presence logic,
  including the disagreement case in both directions, the `armv6l`
  refusal, and the `armv7l` direct-answer path, against synthetic
  fixtures.
- The `preStart.sh` repair-decision function (`sm_arch_repair_reason`)
  against a matching stamp, a mismatched stamp, no stamp at all, and a
  failed fresh detection — each producing the right decision and, for the
  mismatch case, a message naming both architectures.
- `sm_fppdir` against all four combinations of the two FPP calling
  conventions above, plus the case where both happen to be present.
- Checksum verification, including a genuinely tampered artifact and a
  missing manifest entry, both rejected.
- `artifacts.lock.json` lookup: a filename that is in the lock, one that
  is not, a lock pinned to a different version than the one being
  installed, and the compromised-host case: a downloaded tarball and a
  downloaded `SHA256SUMS` that agree with each other but disagree with the
  committed lock, rejected on the lock's authority, not the manifest's.
  Two entries naming the same filename are refused as ambiguous, both one
  per line and minified onto a single physical line (a naive line-count
  guard undercounts the minified case as one match). An artifact object
  whose `sha256` key is written before its `filename` key, which this
  parser does not guess an order for, is refused rather than silently
  returning the wrong hash, including the case that used to return a
  neighbouring artifact's hash on a minified, multi-object line.
- Stage-then-swap binary activation (`sm_stage_binary`, `sm_activate_binary`,
  `sm_activate_commit`, `sm_activate_rollback`): a clean fresh install with
  no previous binary, a failure injected during post-staging validation
  (mode/ownership) leaving the previous binary untouched, a failure
  injected in the atomic-rename swap itself after staging succeeded (the
  previous binary is left exactly as it was, since a failed rename never
  touches its destination, so no separate rollback rename happens or is
  needed), and `sm_activate_rollback` itself restoring the preserved
  previous binary after a failure that happens after the swap already
  succeeded. The backup mechanism itself: `sm_activate_binary` calls the
  atomic rename exactly once when a previous binary exists, because the
  backup is a hard link, not a second rename, proven by a call count and
  by device/inode identity captured on the live target BEFORE the swap
  runs, so the comparison cannot pass by coincidence once the target's
  inode has already changed; and the `cp -p` fallback for a filesystem
  that does not support hard links, exercised for real with `ln` itself
  shadowed to fail, not only by hand. `sm_write_stamp`: an ordinary
  write; a symlinked destination or a symlinked temp path both refused
  without writing through them; a leftover directory at the temp path
  cleared so the write can proceed instead of failing forever; and a
  write that genuinely cannot create its temp file leaving an existing
  stamp untouched rather than truncated.
- `sm_stage_binary`'s chmod/chown never run against the shared staging
  path at all: both execute against the private extraction workdir
  BEFORE the binary is ever given a name inside the plugin directory,
  proven structurally by wrapping the resolved `chmod`/`chown` and
  asserting neither is ever invoked with the staging path as an
  argument, closing the window where a root chmod/chown run AFTER
  staging could be redirected onto an arbitrary path by a symlink raced
  into place between the rename and the chmod. A directory planted at
  the staging path ahead of a fresh install is refused rather than
  silently accepted with the new binary moved inside it.
- Scaffold symlink hardening, beyond the leaf-path refusal already
  covered above: a symlinked PARENT path component (not just the final
  component) under a scaffold directory is refused rather than followed,
  exercised both directly against `sm_scaffold_dir` and end to end
  through `sm_ensure_config_scaffold` itself with a symlinked component
  under the state directory; a hard link occupying a scaffold file's own
  path is refused a chown/chmod run in place (which would have mutated
  whatever the hard link's other name pointed at) in favor of preparing
  the file's content in `sm_scaffold_stage_root()` (`common.sh`), a
  root:root staging directory whose own PARENT is `/etc` (writable by
  nothing but root), and activating it with one rename. That staging
  directory is deliberately NOT a sibling under the `fpp`-owned
  `sm_credential_dir`/`sm_state_dir`: `fpp` has no access to it, or
  anything created inside it, at any point in its life, so the chown and
  chmod that follow run against it directly, with nothing to race and no
  identity check needed. An earlier version of this construction instead
  staged inside the `fpp`-owned scaffold directory and guarded its own
  chown/chmod with a device/inode identity check taken just before each;
  measured over 3000 trials per configuration, that construction let a
  hard-link attacker mutate ownership 820 times and mode 181 times out of
  3000 — worse on both axes than the plain baseline it replaced — and
  gave a symlink attacker no protection at all, since `chmod(1)` follows
  a symlink with no `-h` and GNU `stat` reads a symlink's own identity by
  default, so the identity check's two reads always agreed with each
  other regardless of what the symlink pointed to. The current
  construction, measured the same way against both attacks: 0 ownership
  mutations, 0 mode mutations. That does not mean every trial activates:
  under a continuous symlink attacker the scaffold correctly refuses
  activation outright in roughly 75 percent of trials rather than
  mutating anything, which is the fail-closed behavior this construction
  is for, not a shortfall — the attacker in that configuration never
  touches a path this construction actually checks, so the safety
  figures above stand on their own regardless of how often activation
  itself succeeds. What makes the final step safe regardless of timing
  is `rename(2)` itself: it replaces a destination NAME outright and
  never dereferences a symlink or hard link already sitting there, so
  the swap is safe no matter what currently occupies the scaffold file's
  own path. A directory (or anything else that is not a regular file)
  sitting at a scaffold file's own path is refused rather than chowned,
  chmoded, and reported healthy.

  `sm_scaffold_dir`'s own chmod, unlike `sm_scaffold_file`'s, is still
  issued by PATH rather than through the private staging construction
  above: a directory scaffold must not disturb a directory that already
  exists at that path (a re-run must never touch an already-populated
  state directory), and `rename(2)` onto a non-empty destination fails
  outright, so the stage-then-rename swap that closes the file case does
  not carry over to a directory that may already hold content. This is
  pre-existing, not introduced by this branch. `chown -h` immediately
  above closes the ownership half of the same race by acting on the
  symlink itself via `lchown(2)`; there is no `lchmod(2)` on Linux, so
  the repeated `sm_refuse_symlink` check immediately before the chmod
  call is the only defense available for that step, and it is a
  check-then-act gap, not a closed one. A reviewer raced a symlink into
  that gap and got a root `chmod 0700` applied to a directory outside
  this repository's tree in 98 of 2000 trials; ownership was untouched
  in every trial, since `chown -h` holds. Closing this the way
  `sm_scaffold_file`'s chmod was closed is not available here without
  changing what a re-run is allowed to do to an existing directory's
  contents, so it stands documented rather than fixed in this commit.

  A rename is only atomic within one filesystem, and the staging root
  and a scaffold file's own target can legitimately be on different ones,
  since this repository supports the media directory (and therefore
  `sm_state_dir`) on removable storage. No code in this repository
  handles that case specially any more: plain `mv -f` already does, on
  its own. GNU `mv` catches `EXDEV` internally and falls back to copying
  the file and then unlinking the source, exiting 0 with empty stderr,
  so `sm_scaffold_file`'s single `mv -f` never surfaces `EXDEV` as a
  distinguishable failure for a regular file — an earlier version of
  this repository added `sm_scaffold_activate_cross_device` to handle
  that case explicitly, instrumented it with a marker, forced a genuine
  cross-device pair confirmed by `rename(2)` itself returning `EXDEV`,
  and the marker never printed; no test in this suite ever referenced
  that function, `EXDEV`, or cross-device activation either. It was dead
  code, and has been removed. Verified directly instead: a cross-device
  `mv` onto a symlink or hard-link destination unlinks that destination
  name and creates a fresh file there rather than following it, and it
  preserves the staged file's mode and ownership. Measured over 3000
  trials per configuration against a symlink attacker on both the
  destination name and `mv`'s own temp name: 0 ownership mutations, 0
  mode mutations. The residual is that the copy itself is not atomic: a
  torn write if the destination name is replaced mid-copy, not a
  privilege escalation, since nothing on this path lets an attacker
  redirect a chown or chmod this repository issues (`mv` performs its
  own attribute preservation on this path, not a chown/chmod this
  repository runs). This has been exercised only in a container with a
  bind-mounted tmpfs standing in for removable media, never against real
  removable storage on an FPP host.
- `sm_install_binary` and `sm_install_or_upgrade`, end to end, with
  `sm_detect_arch` and `sm_download` shadowed so nothing here touches the
  network: a clean fresh install; a lock hash that disagrees with the
  served bytes, refused with the previous binary surviving byte-identical
  and executable; a fresh install whose swap fails, leaving nothing
  half-installed; and a post-activation mode-verification failure (on
  both an upgrade and a fresh install) rolling the live binary back, or
  removing an unverified fresh install with nothing to roll back to,
  before the transaction commits. Once the transaction has committed, a
  failed architecture-stamp write is reported as a failure but no longer
  rolls the binary back: the newly activated binary already passed mode
  re-verification and stays live, since rolling it back at that point
  would restore an older binary while leaving a stamp already rewritten
  to describe the one just discarded. There is no installed-version
  stamp; an earlier version of this code wrote one alongside the
  architecture stamp, but nothing ever read it back, so it was removed
  rather than given a reader it does not need. The architecture stamp is
  confirmed written after a successful install, and a failed write on a
  fresh path (nothing recorded there before) is self-correcting rather
  than permanently invisible to the repair guard that reads it back; see
  `sm_write_stamp_or_sentinel`'s comment in `scripts/lib/activate.sh`.
  `sm_install_or_upgrade`'s own orchestration (command-script
  validation gating the config scaffold, the config scaffold gating the
  binary install) is exercised with `sm_ensure_config_scaffold` shadowed,
  so this suite never touches `/etc` or the real plugin state directory
  on the machine running it.
- Command-script validation: a script that exists and is executable, one
  that is missing, one that exists but is not executable, and a missing
  `descriptions.json`, each producing a distinguishable message — run both
  against synthetic fixtures and against this repository's own shipped
  `commands/descriptions.json` and `commands/run-macro.sh`, so the exact
  save that caught the `scripts/`-vs-`commands/` placement bug during this
  repository's own development is now a standing check rather than a
  one-time one.
- Base URL scheme enforcement: `https://` accepted silently, `http://`
  accepted but logged, no scheme and an unrecognized scheme both rejected.
- Mode verification (`sm_verify_mode`) against a mode that was actually
  set, a mode that was not, and a nonexistent path.
- Every entrypoint script's and library file's executable bit as recorded
  in git, so a lost `chmod +x` on any of them — including on
  `fpp_install.sh` itself, whose loss would silently skip everything else
  in this list on a real host — fails the suite rather than waiting to be
  discovered on a Pi.
- The full fetch → verify → extract → place pipeline, end to end, against
  a local HTTP server standing in for a release host, including its
  refusal of a tampered download, and including confirming the installed
  binary's mode reads back as `0755`.
- `commands/run-macro.sh` run directly under a synthetic environment
  matching the confirmed exec contract exactly (`env -i` plus only
  `SCRIPTDIR`, `MEDIADIR`, `FPPDIR`), including the no-`SCRIPTDIR` fallback
  path and the missing-argument case.

`test/run_tests.sh` covers everything except the last two, which were
checked by hand against a local HTTP server and are not yet part of the
automated suite. Running the suite does not require FPP, root, or any of
the paths above to exist; see the script for how it stubs kernel and
filesystem probes without touching real system paths.

None of this raises the plugin-distribution research record's evidence
level. It stays at what a bench container and a source read can support;
only running this against a real FPP instance moves the on-host tier
above.

## Trust boundary: what the lock and activation controls actually defend

This repository's own controls, the symlink refusals, the atomic stage-
then-swap binary activation, and `artifacts.lock.json` verified before
anything downloaded is ever extracted or executed, all run as ROOT out of
the plugin's own installed directory. That directory is not a neutral
place for them to live. This section states plainly what those controls
can and cannot defend against, given where they run.

**The plugin directory is writable by the unprivileged `fpp` user, at
rest, under normal FPP operation — this is an FPP platform property, not
a misconfiguration and not something this repository can fix from
inside itself.** Confirmed by reading FPP's own Plugin Manager and boot
source directly, against both the pinned FPP 9.x and FPP 10.x trees this
project targets:

- A fresh plugin install ends with `$SUDO chown -R fpp:fpp <plugin dir>`
  (`scripts/install_plugin`, FPP 9 line 36-38 and FPP 10 line 127-129),
  run as root via `$SUDO`, with no accompanying `chmod` that ever
  restricts write access below whatever `git clone` already left (owner
  read/write on every file, since `fpp` is the owner, not merely a
  group member). Nothing in either tree narrows this afterward.
- An upgrade's `git pull` (or, on FPP 10, its fetch/reset/clean fallback
  in `scripts/upgrade_plugin`) runs as root and does not itself re-run
  that `chown`, so a file an upgrade rewrites can land root-owned
  momentarily. FPP 9 has no `scripts/upgrade_plugin` at all; its upgrade
  path is `www/api/controllers/plugin.php:227-246`, which runs `git pull`
  under `sudo` instead. Still root either way. That momentary gap is
  closed automatically, system-wide, not just for this plugin:
  `setFileOwnership()` (`src/boot/FPPINIT_Config.cpp:560-562` on FPP 10,
  `src/boot/FPPINIT.cpp:886-888` on FPP 9) runs `chown -R fpp:fpp` over a hardcoded
  `/home/fpp/media`, including every installed plugin's directory, on
  every boot's `postNetwork` phase, unconditionally, before `preStart`
  scripts run. That re-assertion is narrower than a blanket "every boot"
  claim, though: `scripts/common` honours `www/media_root.txt` for a
  relocated media root, but this hardcoded boot-time chown does not, so a
  host with a relocated media root does not get this plugin directory
  re-covered every boot. The install-time chown in `scripts/install_plugin`
  still applies regardless, so the directory is still writable by `fpp`
  at rest either way; only the "self-heals every boot" part is narrower
  than claimed for a relocated media root.
- `preStart.sh` is what actually runs this plugin's install/repair path
  at every `fppd` start. It is invoked with no privilege change
  (`runPreStartScripts()`, `scripts/functions:512-520` on FPP 10 and
  `scripts/functions:714-722` on FPP 9, doing a plain `/bin/bash ${FILE}`)
  from `fppinit`'s `bootPre` boot action (`src/boot/FPPINIT.cpp:435-442`
  on FPP 10, where the `runScripts("preStart", true)` call itself sits on
  line 442), which `fppd.service` runs via `ExecStartPre` with no
  `User=` directive — `fppinit`, and therefore every `preStart.sh` it
  runs, executes as root. `fppd` itself also has no `User=` directive and
  drops no privilege anywhere in its own source, so the resident
  component this project's C++ side eventually becomes also runs
  in-process with `fppd`, as root, not as `fpp`.

Put together: `preStart.sh`, `fpp_install.sh`, `fpp_upgrade.sh`,
`fpp_uninstall.sh`, and every file under `scripts/lib/`, are read and
executed as root, out of a directory the `fpp` user can write to at any
time. `fpp` is not the account this plugin's own binary or the commands
FPP fires against it run as: a fired plugin command reaches its script by
`execve` with no privilege drop (`Plugins.cpp:315` on FPP 10, `Plugins.cpp:308`
on FPP 9), same as
`fppd` itself (see above), so both run as root, same as the scripts. The
`fpp`-level actor in this picture is the FPP web UI: `SD/FPP_Install.sh:2084`
on FPP 10 (`SD/FPP_Install.sh:1344` on FPP 9) sets `APACHE_RUN_USER` to the FPP user, so Apache, and
the PHP it runs (including the upgrade path cited above), is what
actually executes as `fpp`. Nothing internal to those scripts, no symlink
refusal, no atomic rename, no lock-file check, can be a trust boundary
against an attacker who can already write into that directory: that
attacker does not need to race a TOCTOU window or defeat a hash check at
all, they can simply edit `preStart.sh` (or any `scripts/lib/*.sh` file
it sources) directly, and it runs as root, unmodified logic included, the
next time `fppd` starts. This holds under standard FPP operation on both
pinned trees; the one documented exception is macOS, where `install_plugin`
skips the `chown -R fpp:fpp` step entirely (`scripts/install_plugin`,
guarded by `if [ "${FPPPLATFORM}" != "MacOS" ]`) — not a real FPP host,
so not a mitigating case for a production install. Whether the FPP web
UI's own PHP process (which triggers install/upgrade over `$SUDO`) has a
passwordless sudo grant is asserted by `www/config.php` but the sudoers
file itself does not ship in either pinned tree, so that specific link
in the chain is provisioned by the base OS image, outside what either
tree's source confirms.

**What this means for the claims this repository can honestly make.**
Nothing in this repository can be a defense against an attacker who
already has `fpp`-level code execution on the host: FPP's own plugin
model hands that attacker root on the next `fppd` start regardless of
anything this repository does to its own scripts. That is not a gap this
project introduced and not one it can close from inside a plugin
directory FPP itself makes writable; closing it would mean changing how
FPP's Plugin Manager owns and mounts plugin trees, which is out of scope
for this repository (see "What this repository is NOT" above).

What this repository's controls DO deliver, and the one claim actually
confirmed with no bypass found by a prior adversarial review, is
narrower and real: **the network path.** A release artifact fetched from
`SHOWMESH_PLUGIN_ARTIFACT_BASE_URL` is verified against this
repository's own committed `artifacts.lock.json`, which arrives on the
host as part of the plugin's own checked-out tree (installed/upgraded by
FPP's `git clone`/`git pull`, not fetched over the same channel as the
binary), before that artifact is ever extracted or executed. That
ordering, verify before extract-or-execute, holds regardless of what a
compromised or malicious release host serves: a tampered tarball is
rejected on the lock's authority before `tar` ever runs against it, and
before the stage-then-swap activation in `scripts/lib/activate.sh` ever
gives it a name next to the live binary. This is the actual, delivered
guarantee this repository can stand behind: a release host that goes
bad, or a network path that gets tampered with, cannot get an unverified
binary run. It says nothing about, and cannot defend against, an
attacker who already reached the plugin directory some other way (over
`fpp`-level access to the host itself, not over the network path this
lock protects) — the symlink refusals and atomic activation this
project has hardened make the difference between that attacker's write
being caught immediately versus silently succeeding at whatever a
specific mutation was aimed at, but neither outcome changes the deeper
fact that the scripts themselves are not a trusted input once `fpp` can
already write to their own directory.

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
