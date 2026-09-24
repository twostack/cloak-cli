## Context

See proposal.md for why. The facts the approach rests on, all established on 2026-09-24
(the second and fifth revised the same day, when tstokenlib 2.0.1, libspiffy 3.0.0 and
ricochet 0.1.0 were published on pub.dev):

- `cloak` compiles with `dart compile exe` to one 18.3 MB Mach-O or ELF file, and needs
  two native libraries at run time: tstokenlib's kernels (`libstark_kernels`, Rust;
  ML-KEM has no Dart fallback, and key derivation uses it, so even `cloak address` needs
  it) and Isar's core (`libisar`, Rust with a C database underneath).
- tstokenlib 2.0.1's `StarkKernels.tryLoad()` looks for the kernels in
  `STARK_KERNELS_LIB`, then beside `Platform.resolvedExecutable` and in `../lib` from it,
  then in `native/stark_kernels/target/release/` under the working directory and up to
  three of its parents, then beside its own package source. It caches the first answer,
  and a call with an explicit path does not fill that cache. A library whose interface
  version differs is skipped without a word, and the search goes on, down to the working
  directory. The published package carries the crate's source (not its build output).
- Isar's `initializeIsarCore` runs once per process; later calls return at once. Called
  with `download: true` and no path, it fetches the library from GitHub and writes it
  beside `Platform.script`, which in a compiled program is the executable. eventador and
  libspiffy both call it with `download: true`. Isar 3.1.0+1 publishes libraries for
  macOS and Linux x64, not Linux arm64.
- Under the hardened runtime a Dart AOT binary needs
  `com.apple.security.cs.allow-unsigned-executable-memory` and nothing else; with it, it
  loads a library signed by the same identity. This machine holds Apple Development
  identities only.
- `cloak-cli` depends on its siblings by path and ignores `pubspec.lock`. Its resolution
  fails, because pool-coordinator (a dev dependency, by path) now takes tstokenlib and
  ricochet from pub.dev, with a `pubspec_overrides.yaml` for sibling checkouts. `libcloak`
  and `pool-coordinator` are not published. ricochet 0.1.0 takes `merkledag` and
  `dart_libp2p_merkle_crdt` from pub.dev; older commits named them by absolute paths on
  one machine, which is where this repository's lock file got its absolute entries.
- tstokenlib's kernels crate links only system libraries on macOS when built with default
  features; the experimental `metal` feature, which the local build has on, adds Metal
  and CoreGraphics. Its install name is the build directory.

## Goals / Non-Goals

**Goals:**
- A release is a function of one `cloak-cli` commit: running the workflow again on the
  same tag builds the same program from the same sources.
- Nothing about finding libraries depends on where a person happens to be standing.
- No change asked of tstokenlib, libspiffy or Isar's code: the released versions on
  pub.dev are what a release is built from.

**Non-Goals:**
- Byte-for-byte reproducible binaries. Pinned inputs are the promise; identical bytes
  across runners are not.
- Running the localnet end-to-end suite in CI. It needs Docker, a regtest node, ARC and a
  ricochet server; it stays a checklist step before publishing a draft.
- Automatic updates from inside `cloak`. A program that phones home for new versions is
  a request the person did not ask for.

## Decisions

### No launcher: tstokenlib finds the kernels beside the program

The bundle is `bin/cloak` and `lib/`, and `install.sh` links straight to
`bin/cloak`. tstokenlib 2.0.1 looks in `../lib` from `Platform.resolvedExecutable`, which
is the real path with every link followed, so the program finds the bundled kernels
whatever the working directory, with nothing set before it starts.

- *Considered first, and dropped: a launcher script* setting `STARK_KERNELS_LIB` and
  running `libexec/cloak`. It was the plan while tstokenlib looked only in the variable,
  the working directory and its own source tree. With 2.0.1 it would add a process and a
  shell's start-up to every command, and a second file to keep correct, for nothing.
- *Considered: loading the library first with an explicit path.* tstokenlib does not cache
  an explicit-path load, so its own later lookup would search again.

What closes the working-directory search is the program's own check, below: tstokenlib
reaches the working directory only when neither the variable nor `../lib` names a loadable
library of its version, and a released build never asks tstokenlib anything in that state.

### The program checks the kernels before a command that needs them

A new `lib/src/native/` holds one place that knows the bundle layout. It learns whether it
is a released build from a compile-time define (`cloak.release`), set only by the release
build. Before any command that opens the wallet's keys or builds a transfer, it checks
the file tstokenlib would take first: the one `STARK_KERNELS_LIB` names when it is set,
otherwise, in a released build, the kernels in the bundle's `lib/`. The file must exist,
open, and report an `sk_version` equal to `StarkKernels.abiVersion`; any failure is
`Refusal('native library', ...)` naming the file, the directory and both versions where
there are two. So tstokenlib's own search always stops at a file the program has already
checked, and never goes on to the working directory. A development build (no define) keeps today's behaviour,
so the suite and `dart run` are unchanged. As a backstop, the shell maps tstokenlib's
`StateError` about the native crate to the same refusal, so no path can print `cargo` to
a person.

Commands that need no keys (`--help`, `--version`, `status`, `balance`, `notes`,
`journal`) never reach the check.

### Isar is started first, from the bundle, never downloading

`SpiffyChain.start` already initializes Isar before libspiffy runs. In a released build it
passes `libraries: {Abi.current(): <bundle>/lib/libisar.<ext>}` and `download: false`,
after checking the file exists (a missing file is the `native library` refusal, before
Isar is touched). Because Isar's initializer runs once per process, the later
`download: true` calls in eventador and libspiffy return without effect. Passing the path
explicitly also sidesteps Isar's `localName`, which throws on Linux arm64. The bundle
directory comes from `Platform.resolvedExecutable` (the real `bin/cloak`), up one.

### Siblings come from pub.dev, and the lock file is committed

`libcloak`, `libspiffy`, `tstokenlib` and `ricochet` become hosted dependencies (0.1.1,
3.0.0, 2.1.0 and 0.1.0 on 2026-09-25). `pool_coordinator` stops being a dependency at all:
it was a dev dependency, for the localnet tests, and an application does not belong in a
package's dependencies, even its tests'. The end-to-end run builds the coordinator from
its checkout with `dart build cli` and runs `create` and `run` as processes, which is also
how it runs in the world; the transport tests play its end of ricochet with a small class
of their own. `pubspec.lock` leaves `.gitignore` and is committed: it pins every hosted package by
version and content digest. The release build runs `dart pub get --enforce-lockfile`.

A developer who wants live checkouts writes `pubspec_overrides.yaml` with path overrides,
which stays out of git (a sample is committed as `pubspec_overrides.yaml.example`). This is
pool-coordinator's arrangement, so both repositories move their pins the same way.

- *Considered: git dependencies pinned by commit* for every sibling. It was the plan before
  three of them were published; pub.dev's versions and digests pin just as firmly, need no
  git on the build machine, and are what pool-coordinator already uses.
- *Considered: keeping path dependencies* and having CI clone each sibling at a commit
  named in a manifest. It keeps two sources of truth, gives `pub` no say in whether they
  agree, and does not fix the failing resolution.

`--version`'s sibling versions are read from `pubspec.lock` by the release build and written,
with the `cloak-cli` commit and the release flag, into `lib/src/build_facts.dart` just before
`dart build cli` runs; the committed file, describing a development build, is put back
afterwards. A file rather than `--define`, because `dart build cli` takes none. Nothing is
read at run time.

### Native libraries are built from pinned source on native runners

Each platform builds on its own machine: the maintainer's Mac (arm64), and the runners
`ubuntu-22.04` (amd64) and `ubuntu-22.04-arm` (arm64). Ubuntu 22.04 fixes the glibc floor
at 2.35.

- The kernels come through tstokenlib 2.1.0's build hook, which `dart build cli` runs (and
  `dart compile exe` refuses to: it does not support build hooks). By default the hook
  downloads the prebuilt library published for the crate's exact source and refuses it
  unless its SHA-256 is the one `native/prebuilt.json` in the locked package pins; where
  none is published it builds the crate with cargo. The pin is the package's, so the lock
  pins the kernels too. On 2026-09-25 the macOS arm64 prebuilt matched its pin
  (`b2805026...`); `dart build` then rewrites its install name to `@rpath/lib/...`. It links
  Metal and CoreGraphics, both system frameworks. The earlier plan built the kernels from
  the crate here, and was set aside when the person pointed at the hook
  (superseded, 2026-09-25):
  ~~built with `cargo build --release` from the crate source inside the locked `tstokenlib`
  package, which pub has already fetched (its path is read from `.dart_tool/package_config.json`), with
  default features, so no Metal. On macOS the install name is set to
  `@rpath/libstark_kernels.dylib`; on Linux the soname is checked.~~
- Isar's core is built from the Isar repository at the commit its 3.1.0+1 release was cut
  from (`6643d064`), for all three platforms, rather than downloading Isar's published
  libraries for two and building one. One path for all three is one path to check, and
  nothing ready-built is trusted. That repository keeps no `Cargo.lock`, so its Rust
  dependencies would float to the newest on the day (on 2026-09-24 one already needed a
  newer compiler than the pinned 1.84). `tool/release/isar/Cargo.lock` pins them, resolved
  with the resolver that keeps to the pinned toolchain, and the build uses it `--locked`.
  Built so on macOS arm64 it took 27 s and was 1.0 MB, and the bundle passed its smoke
  test with it.
- *Considered: cross-compiling from one host.* `dart compile exe --target-os` can, but both
  Rust libraries would need cross toolchains and a C cross-compiler for Isar's database;
  native runners avoid all of it and test on the platform they build for.

The Rust toolchain is pinned by version in the workflow. Builds of the two libraries are
cached per platform and source version.

### Linux on GitHub, macOS on the maintainer's Mac

The person does not want signing secrets on GitHub, so the two halves are built in two
places, by the same scripts in `tool/release/`.

**Linux** is built by the release workflow on its native runners, which needs no secret:
each job resolves with the lock enforced, analyzes, runs the suite, builds both libraries,
compiles, assembles, checks links (`readelf -d`), runs the smoke test and the secret scan,
and uploads the bundle as a workflow artifact. A final job, run only if both passed, writes
`SHA256SUMS`, attests provenance with GitHub's attestation action, and creates the release
as a draft.

**macOS** is built by `tool/release/macos.sh` on the maintainer's Mac, from a clean checkout
of the tag. It refuses first if there is no Developer ID Application identity or no
`notarytool` keychain profile, naming what it found. Then it does what a Linux job does,
and signs the two libraries, then the program with `--options runtime --timestamp
--entitlements tool/release/cloak.entitlements`, verifies all three, and assembles and
checks the bundle from the signed files. It packs the bundle directory into a compressed,
read-only disk image with `hdiutil`, signs the image, submits it with `notarytool submit
--wait --keychain-profile`, and staples the ticket to it. It checks the result as a
downloader would (quarantined, mounted, copied out, run), then adds the image to the tag's
draft release with `gh release upload` and rewrites `SHA256SUMS` over all three files.
Publishing the draft is a person's act, once it holds all three.

- *Considered: signing on a GitHub macOS runner*, with the certificate and an API key as
  environment secrets. The person declined to put signing secrets on GitHub.
- *Considered: a tar.gz for macOS too.* A ticket cannot be stapled to a bare Mach-O file,
  so a program from a tar.gz is checked online the first time it runs, and refused offline
  unless the person clears the quarantine mark. A disk image carries a stapled ticket, and
  its contents are known to Gatekeeper once it is opened, offline included.
- *Considered: an installer package (`.pkg`).* It also staples, but installs as root into a
  system directory, and `cloak` needs neither.

The price is that the macOS image has no provenance attestation: GitHub can only attest what
its runners built. It is vouched for by the Developer ID signature and Apple's notarization
instead, and `SHA256SUMS` still covers it.

### install.sh

`install.sh` is plain POSIX `sh`, needing only `uname`, `curl`, `tar`, `shasum` or
`sha256sum`, and on macOS `hdiutil`. It installs versions side by side under
`~/.local/share/cloak/<version>/` and moves one link, so an upgrade that fails leaves the
old version working and a rollback is moving the link back. On macOS it takes the bundle
out of the image, mounted read-only and detached again whatever happens.

- *Dropped: a Homebrew tap.* It needed a token able to push to the tap stored on GitHub, and
  the person passed on Homebrew for now; it can follow from the same bundles.

## Risks / Trade-offs

- [Isar's core does not build for Linux arm64 at its 3.1.0+1 commit] → The first task is a
  spike building it on `ubuntu-22.04-arm`. If it fails, the fallback is the
  community-maintained Isar fork's core for that platform, pinned by commit, provided its
  on-disk format and API match the `isar` package in use; that is a change to
  `release-build`'s requirement on where Isar is built from, and is raised with the person
  before it is made. If neither works, Linux arm64 waits for a later release, which is a
  change to the platforms the person chose and is raised the same way.
- [tstokenlib moves its search order again] → The program's check names the file
  tstokenlib takes first under 2.0.1's order; a tstokenlib upgrade is a lock change, and
  the planted-library test runs on every push, so a new order that reaches the working
  directory first fails there.
- [The 25 MB bundle bound] → Measured at about 8 MB. If Linux bundles miss it, the program
  is stripped of symbols in the bundle (kept as a separate workflow artifact for crash
  reports) before the bound is questioned.
- [A macOS release depends on one Mac] → The build is a script run from a clean checkout of
  the tag, and the signing identity can be exported to another Mac by the team's account
  holder. What it produces is checked by Apple (notarization) and by `SHA256SUMS`.
- [A future sibling commit breaks the resolution again] → The pins move only in one commit
  that also updates `pubspec.lock`, and the workflow on every push resolves with the lock
  enforced, so a bad move fails on the push, not on the release.
- [A release built with a development define] → The smoke test checks `--version` names
  commits and not `development build`, so a bundle without the release define fails.

## Migration Plan

1. The code changes and the dependency switch land first, on `main`, with the suite
   passing and `dart run` behaving as today.
2. The workflow is exercised by manual dry runs (`workflow_dispatch`), which build and
   check the Linux bundles and create no release, including the runs that must fail. There
   are no pre-release tags.
3. `v0.1.0` is tagged: the workflow makes the draft, `tool/release/macos.sh` adds the
   image, the draft is checked against the release checklist, and published.

Rollback: a published release can be marked pre-release or deleted. Installed copies keep
working, since each version is its own directory.

## Open Questions

- Whether to offer Homebrew later, from the same bundles, once there is a way to update a
  tap that the person is content with.
