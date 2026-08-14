# Source capture: FPP 9.5.3

What this file is, precisely: a written record of specific file paths,
line numbers, and quoted source that this repository's packaging logic
was built and corrected against. It exists so a reader can check the
claims made throughout this repository's comments and README without
having to stand up a container themselves, and so the next correction has
something concrete to update rather than a comment asserting a fact with
no citation.

**Provenance.** These reads were performed directly against a running,
containerized FPP 9.5.3 instance and its own C++/PHP/shell source, by the
person coordinating this repository's build, and relayed here along with
the corrections they produced. This repository's own tooling did not run
that container and has not independently re-executed these reads — there
is no bench container available inside this environment. Treat this file
as a transcription of reported source reads, not as this repository's own
independent verification. If FPP's source changes, or if these reads are
ever re-run, this file is what should be updated.

**FPP version:** 9.5.3, matching what `bench/fpp-multisync/` pins
elsewhere in the ShowMesh project. Two version regimes are asserted
structurally beyond this pinned version — FPP 9.x-and-earlier and FPP
10 — on the strength of a separate, prior finding that `install_plugin`
and its 9.x siblings are byte-identical across the 8.4–9.4 range. None of
that broader claim is bench-verified; only 9.5.3 is.

## 1. `scripts/install_plugin`, fresh-install invocation

Line 43:

```sh
$SUDO ${PLUGINDIR}/$1/scripts/fpp_install.sh FPPDIR=${FPPDIR} SRCDIR=${FPPDIR}/src
```

`FPPDIR=${FPPDIR}` and `SRCDIR=${FPPDIR}/src` are ordinary argv words
following the command, not shell assignments preceding it. `fpp_install.sh`
therefore receives `$1` as the literal string `FPPDIR=/opt/fpp` (or
whatever `FPPDIR` resolves to), and neither value is exported into the
environment by this line.

## 2. `www/api/controllers/plugin.php`, upgrade invocation

Lines 239 and 253 (both branches of the upgrade path use the same shape):

```php
system($SUDO . "  FPPDIR=" . $fppDir . " SRCDIR=" . $fppDir . "/src " . $install_script, ...)
```

Here the assignments sit *before* the command in the constructed shell
string, which makes them shell environment assignments carried by `sudo`
rather than argv words for the invoked script. On this path, the installed
script's `$1` is empty and `FPPDIR`/`SRCDIR` arrive as environment
variables instead — the exact mirror of §1.

**Consequence, applied in `scripts/lib/common.sh`'s `sm_fppdir`:** a fresh
install puts the value in argv and nothing in the environment; an upgrade
puts it in the environment and nothing in argv. A script reading only one
of the two breaks on the other path.

## 3. `scripts/common`, whether the environment survives `sudo`

Line 66:

```sh
SUDO=${SUDO:-sudo -E}
```

`-E` preserves the invoking environment across `sudo` — this is the
opposite of stripping it. Line 56 exports `FPPDIR` (alongside `PATH`)
before this point, so a caller relying on `sudo -E` genuinely does see
`FPPDIR` in its environment, subject to `sudoers` permitting `SETENV`.
`SUDO` is set to the empty string only in FPP's macOS branch, which does
not apply to a deployed Linux host.

**This corrects a Fact this project had previously recorded** (as part of
the plugin-distribution research this repository was built from) stating
that the Plugin Manager "exports bare `sudo` rather than `sudo -E`,
stripping the exported values." That statement is true of the
fresh-install path (§1, which never exports `FPPDIR` regardless of
`sudo -E`) and false of the upgrade path (§2, which does export it, and
whose `sudo -E` call is exactly the mechanism this line documents). A
rule built on the stronger, false version of the claim — "never read
`$FPPDIR` from the environment" — forbade the one mechanism that
actually works on the upgrade path, and has been removed from this
repository's code and comments in favor of checking both sources, in the
order §1 and §2 establish they can arrive.

## 4. `commands/descriptions.json`'s schema

Source: `Plugins.cpp`, `LoadPluginCommands`.

- The file is parsed as a JSON **array**; each element is handed to a
  `ScriptCommand`.
- Exactly two fields are read from each element: `name` (becomes the
  command's name) and `script` (resolved relative to the plugin's
  `commands/` directory, and removed from the object before it is exposed
  to the UI or API).
- Every other field in the object passes through untouched as the
  command's description.

Confirmed live against a running instance: `GET /api/commands` returns
`args[]` entries shaped as `name`, `description`, `type` (`bool`, `int`,
or `string`), `optional`, and optionally `default`, `allowBlanks`,
`contentListUrl`.

## 5. `ScriptCommand::IsOk()` — the silent-drop check

`ScriptCommand::IsOk()` is exactly a file-existence test:
`FileExists(directory + "/" + script)`. When it returns false, FPP drops
the command silently: no error, no log line, no entry in the UI, and no
entry in `GET /api/commands`. It does not itself check the executable
bit — existence only.

## 6. The fired-command exec environment

A command fired through `commands/descriptions.json` reaches its script
via `execve` carrying exactly three variables — `MEDIADIR`, `FPPDIR`,
`SCRIPTDIR` — and no `PATH`. Declared arguments are appended positionally
after the script path.

## 7. `scripts/functions`, `runPreStartScripts`

`preStart.sh` is invoked as `/bin/bash <file>` with **no arguments at
all**, unlike the install/upgrade convention in §1–2. It inherits
`fppd_start`'s own shell environment rather than the stripped
three-variable `execve` environment in §6 — a third, distinct convention
from the other two used anywhere in this repository's five entrypoint
scripts.

## What this does not cover

Everything in this repository's README under "still unverified" is still
unverified by this file too: the on-host install path end to end,
filesystem permissions and mount-option interactions on real hardware,
behavior across an actual FPP major-version upgrade, the candidate `fppd`
and dynamic-linker paths `scripts/lib/arch.sh` probes, and what FPP's
restart-flag setting actually does when called on a live host (a question
this repository declined to answer automatically at all — see
`scripts/lib/install-core.sh`'s `sm_note_possible_restart_need`). This
file captures source reads; it does not upgrade any of them to a bench
result.
