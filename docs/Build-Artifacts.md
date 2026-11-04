# Per-Branch Build Artifacts

Builds are separated by git branch so switching branches cannot overwrite another branch's kext or zip.

## Usage

```sh
tools/build-branch.sh -y
```

The script detects the current branch, sanitizes it, and invokes xmake with
`NRED_BUILD_BRANCH`. Artifacts land under:

```text
build/branches/<branch>/<platform>/<arch>/<mode>/
```

For example:

```text
build/branches/feature-tahoe-26.7.1/macosx/x86_64/release/NootedRed.kext
build/branches/feature-tahoe-26.7.1/macosx/x86_64/release/NootedRed-0.9.0-RELEASE.zip
```

A detached HEAD uses `detached-<short-sha>`. To override:

```sh
NRED_BUILD_BRANCH=my-test tools/build-branch.sh -y
```

Direct `xmake -y` (without the wrapper) uses `build/branches/shared/...`; the wrapper is the supported
interface for per-branch output.

## Building without xmake (Command Line Tools only)

Both `xmake` and `xcodebuild` require a full Xcode install. On a machine that only has the Xcode
Command Line Tools, use the manual build instead:

```sh
tools/build-manual.sh
```

It writes the same per-branch layout as the xmake wrapper:

```text
build/branches/<branch>/macosx/x86_64/release/NootedRed.kext
```

and reproduces what the AppleForge LiluPlugIn rule does: kext compile flags, generated
`KModInfo.c`, linking against MacKernelSDK's kmod stubs, rendered `Info.plist`, ad-hoc signature.

The version is read from `set_version()` in `xmake.lua` rather than duplicated in the script. The
bundle identifier defaults to `org.ChefKiss.NootedRed`; override with `NRED_BUNDLE_ID`.

The script needs an AppleForge checkout including submodules:

```sh
git clone --depth 1 --recurse-submodules https://git.chefkiss.dev/AppleHax/AppleForge.git ~/Desktop/AppleForge
```

Put it elsewhere and point at it explicitly:

```sh
AppleForgePath=/path/to/AppleForge tools/build-manual.sh
```

Branch override works the same as the xmake wrapper (`NRED_BUILD_BRANCH=my-test`).

Ad-hoc signing is best-effort. If `codesign` cannot write into the bundle, the script removes the
partial signature instead of leaving a `_CodeSignature` that no longer matches the binary; the
resulting unsigned kext still injects fine through OpenCore.

## Why

The kext and zip are versioned by branch (for example the stable 15.8.1 build and the experimental
26.7.1/VDA builds). Keeping them under one branch-specific directory avoids accidentally installing or
sharing a kext from another branch.
