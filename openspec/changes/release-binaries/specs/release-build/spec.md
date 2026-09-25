## Purpose

How a release of `cloak` is built: from which commits, for which platforms, into what
bundle, what the binary says about its own build, what every bundle must pass before
anyone can download it, and what is published beside it so a person can check it.

## ADDED Requirements

### Requirement: Every build names its inputs

A release SHALL be built from one commit of `cloak-cli`, whose committed files pin every
input: every package, including the sibling libraries `libcloak`, `libspiffy`,
`tstokenlib` and `ricochet`, which are published on pub.dev, by the version and content
digest in a committed `pubspec.lock`; the Dart SDK version and the Rust toolchain. Nothing is
a path or git dependency; the coordinator, which the localnet tests run, is an application
of its own and not a dependency of this package or its tests. tstokenlib's
kernels SHALL come through tstokenlib's own build hook, run by `dart build cli`: the
prebuilt library published for the crate in the locked `tstokenlib` version, refused unless
its SHA-256 is the one that package pins, or, where none is published for a platform, the
crate built from that package's source. Isar's core library SHALL be built from source, from
the commit of the Isar repository that the pinned `isar` package version was released from
(Isar publishes no Linux arm64 library, so none is downloaded for any platform). The
release build SHALL resolve with the lock file enforced, so it gets exactly what is
committed or fails. A build SHALL fail, and publish nothing, when a pinned package cannot be fetched, its digest differs from the lock, or the resolution would change
the lock file.

#### Scenario: A pinned version missing
- **WHEN** the release workflow runs with `pubspec.lock` naming a `libcloak` version that
  pub.dev does not have, or a digest that differs from pub.dev's
- **THEN** the workflow SHALL fail before compiling, naming `libcloak`, and no release
  SHALL be created

#### Scenario: A fresh machine resolves
- **WHEN** `cloak-cli` is cloned alone, with no sibling checkouts and no
  `pubspec_overrides.yaml`, and its dependencies are resolved with the lock file enforced
- **THEN** resolution SHALL succeed without changing `pubspec.lock`

#### Scenario: The native libraries' sources are named
- **WHEN** a release's workflow run is inspected
- **THEN** its log SHALL name the `tstokenlib` version whose kernels were bundled and the
  Isar commit its core library was built from, and the only library fetched ready-built
  SHALL be the kernels, matching the SHA-256 tstokenlib pins

### Requirement: A release is made from a version tag that matches the program

A release SHALL be made only from a tag `v<version>` where `<version>` equals the version
in `pubspec.yaml`. A mismatch SHALL fail the workflow before anything is built.

#### Scenario: A tag that disagrees
- **WHEN** the tag `v0.2.0` is pushed while `pubspec.yaml` says `0.1.0`
- **THEN** the workflow SHALL fail naming both versions, and no release SHALL be created

### Requirement: The binary says what it was built from

`cloak --version` SHALL print the program version and the `cloak-cli` commit it was built
from; `--version --json` SHALL add the version of each sibling library it was built
against. A binary built outside a release build (the workflow, or the macOS build) SHALL say it is a development build
rather than name a commit it cannot vouch for. Printing it SHALL need no wallet, no native library and no
network.

#### Scenario: A released binary
- **WHEN** `cloak --version --json` is run on a bundle built by a release build
- **THEN** the object SHALL carry the version, the `cloak-cli` commit, and the version of
  `libcloak`, `libspiffy`, `tstokenlib` and `ricochet`, each equal to the version
  `pubspec.lock` pins

#### Scenario: A developer's binary
- **WHEN** `cloak --version` is run from `dart run bin/cloak.dart`
- **THEN** it SHALL print the version followed by `development build`

### Requirement: Three platforms, one bundle each

Each release SHALL carry one bundle for each of macOS on arm64, Linux on amd64 and Linux on
arm64: for Linux a `cloak-<version>-linux-<arch>.tar.gz` with `<arch>` one of `amd64` and
`arm64`, and for macOS the disk image `cloak-<version>-macos-arm64.dmg` that
`macos-notarization` describes. Each SHALL hold a single directory
`cloak-<version>-<os>-<arch>/` holding
the program `bin/cloak`, the two native libraries under `lib/`,
`README.md`, `LICENSE` and `THIRD_PARTY_NOTICES`, and nothing else.

#### Scenario: What a bundle holds
- **WHEN** a released Linux bundle is listed, or the macOS image's volume
- **THEN** its entries SHALL be exactly those named above, under one top-level directory
  `cloak-<version>-<os>-<arch>/`

#### Scenario: A bundle holds no one's secrets
- **WHEN** a released bundle is searched for wallet files (`wallet.enc`, `keys.enc`,
  `identity.seed`, `notes.store`), private keys in WIF, hex or PEM form, the signing key
  as a PKCS#12 file, and the signing password (a certificate alone is public, and the Linux
  Dart runtime carries root certificates in every program built on it)
- **THEN** none SHALL be found

### Requirement: A bundle links only to what every machine of its platform has

The program and both libraries SHALL link only to the operating system's own libraries:
on macOS, `/usr/lib/` and `/System/Library/Frameworks/`; on Linux, the C library, the math
library, the dynamic loader, `libpthread`, `libdl`, `librt` and `libgcc_s`. The Linux
bundles SHALL run on glibc 2.35 and later. A library SHALL NOT record the build machine's
path as its own name.

#### Scenario: Checking what links
- **WHEN** the build inspects each Mach-O with `otool -L` and each ELF file with
  `readelf -d`
- **THEN** every dependency SHALL be on the lists above, and no library's own name SHALL
  contain the build directory, or the build SHALL fail naming the file and the
  dependency

### Requirement: Nothing is published that was not checked

Before a bundle is attached to a release, the build that made it SHALL, on that bundle's
own platform (the workflow for Linux, the maintainer's Mac for macOS):

- run `dart analyze lib bin test` with no issues, and the default suite with no failures;
- unpack the bundle into a fresh directory and, from an unrelated working directory with
  an environment holding only `HOME`, `PATH` and `CLOAK_PASSPHRASE`, run `--version`,
  `--help`, `init --network regtest`, `address`, `address --transparent`, `status` and
  `balance`, each exiting 0, with `status` reporting both native libraries present;
- check that the smoke run created no file outside the wallet directory it named.

A failure on any platform SHALL publish no release at all. The workflow SHALL create the
release as a draft holding the Linux bundles only when both passed; the macOS image is added
to that draft by the macOS build; a person publishes the draft once it holds all three.

#### Scenario: One platform fails
- **WHEN** the Linux arm64 smoke run fails
- **THEN** no release SHALL be created, including for the platforms that passed

#### Scenario: A passing run
- **WHEN** every platform passes
- **THEN** a draft release SHALL exist for the tag with the two Linux bundles and the
  checksum file attached, and SHALL NOT be visible to the public until a person publishes
  it

### Requirement: A release carries checksums and provenance

Each release SHALL carry `SHA256SUMS`, listing the SHA-256 of every bundle and the image,
and a build provenance attestation for each Linux bundle binding it to the workflow run,
the tag and the `cloak-cli` commit. The macOS image, built off GitHub, is vouched for by
its Developer ID signature and Apple's notarization instead. The README SHALL say how to
check each.

#### Scenario: Checking a download
- **WHEN** a bundle is downloaded with `SHA256SUMS` and checked with `shasum -a 256 -c`
- **THEN** the check SHALL pass, `gh attestation verify` on a Linux bundle SHALL name the
  workflow and the tag, and `spctl --assess --type open --context context:primary-signature`
  on the image SHALL name the Developer ID

### Requirement: Licenses and notices travel with the program

Each bundle SHALL carry `LICENSE`, MIT, for `cloak-cli`, and `THIRD_PARTY_NOTICES`
holding, for every Dart package compiled into the program and each of the two native
libraries, its name, version and the full text of its license. The build SHALL fail when a
package compiled into the program has no license it can find.

#### Scenario: Every package accounted for
- **WHEN** the notices of a bundle are compared with the packages the release build
  resolved, less those only used by tests and tools
- **THEN** every package SHALL appear with a license text, and so SHALL tstokenlib's kernels
  (Apache-2.0) and Isar's core library (Apache-2.0)

### Requirement: A bundle stays small enough to download

A compressed bundle SHALL be at most 25 MB. Measured 2026-09-24 on macOS arm64: the program
18.3 MB, the kernels 0.6 MB, the Isar library 2.2 MB, about 8 MB compressed together.

#### Scenario: Size checked
- **WHEN** a bundle or the image is assembled
- **THEN** the build SHALL fail if it is larger than 25 MB, printing its size

### Requirement: No secret is stored on GitHub

The release workflow SHALL need no secret beyond the token GitHub gives every run: it builds
and checks the Linux bundles and creates the draft, and signs nothing. Whatever signs the
macOS release stays on the maintainer's Mac (`macos-notarization`), and no bundle, image,
log or workflow artifact SHALL hold a signing secret.

#### Scenario: A workflow with no secrets
- **WHEN** the release workflow's definition and its run's environment are inspected
- **THEN** they SHALL name no repository or environment secret
