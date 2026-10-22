# Releasing the ShowMesh FPP plugin

## Versioning

The plugin follows the versioning scheme in ShowMesh Core's
[`docs/RELEASING.md`](https://github.com/ShowMeshSystems/showmesh/blob/main/docs/RELEASING.md):
`MAJOR.MINOR.PATCH`, MAJOR names the show season (`0.x` is 2026, `1.x` is
2027), the `-alpha.N`, `-beta.N` and `-rc.N` suffixes, the January start of
the next season's line, and the compatibility rule that starts at `1.0.0`.
Those rules live in that one file; this one covers only what differs here.

- The plugin's MINOR and PATCH move independently of Core's. A plugin and a
  coordinator from the same season share a major number.
- `VERSION` in this repository is the plugin version. It changes only in the
  pull request that pins a new release.
- A plugin release spans two repositories: the binaries are built and
  published from `ShowMeshSystems/showmesh-fpp-plugin`, and this repository
  pins them.

## Cutting a release

1. Decide the version number per the scheme above.
2. In `showmesh-fpp-plugin`, on a clean checkout of the commit to release,
   build every artifact:

   ```sh
   make release-with-prebuilt-fpp10 VERSION=<VERSION>
   ```

   This builds the Go helper for amd64, arm64 and armv7, the native source
   bundle, and the three prebuilt FPP 10 objects, then writes and verifies
   `dist/showmesh-fpp-plugin_<VERSION>_SHA256SUMS` and
   `dist/release-manifest.json`. The arm64 and armv7 FPP 10 objects build
   under emulation and take a while.
3. Tag that commit `v<VERSION>` in `showmesh-fpp-plugin`, push the tag, and
   publish a GitHub prerelease titled `FPP plugin <VERSION>` with the seven
   artifacts and the `SHA256SUMS` file from `dist/`.
4. In this repository, set `VERSION` to `<VERSION>` and regenerate
   `artifacts.lock.json` from that release's `SHA256SUMS`: one entry per
   artifact with its filename, kind, architecture and SHA-256. Update the
   lock's `note` with the source commit. No tool does this step yet.
5. Merge that pull request. FPP's Plugin Manager installs from this
   repository's `main`, so the merge is what reaches players.

Every step is manual today. A plugin release does not need a Core release,
and a Core release does not need a plugin release. Core's changelog names the
plugin version each Core release was tested with.
