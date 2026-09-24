## Why

`cloak` works, end to end on localnet, but only for a person who can check out eight
repositories side by side, build a Rust crate and point an environment variable at it.
Nobody else can run it. This change turns it into something a person downloads: a
signed, checksummed bundle for macOS on Apple silicon and for Linux on amd64 and
arm64, published on GitHub, installable by one command, and for macOS a notarized disk
image.

It is needed now because the compiled binary, unlike `dart run`, has already been shown
to break in ways the suite could not see (section 10 of `docs/DESIGN.md`): a wordlist
read as a package resource, native kernels looked for beside a source tree, and a
database library downloaded at run time. A download for strangers has to be built,
checked and published the same way every time, by a machine.

## What Changes

**In the program.** Almost none of this is new wallet behaviour; it is where two native
libraries are found, and what the binary says about itself.

- **Native libraries found in the bundle** (new). An installed `cloak` finds tstokenlib's
  kernels (ML-KEM, which every key derivation needs) and Isar's core library in the
  bundle it was installed from, and **never downloads a library**. Today Isar fetches
  its library from GitHub on first use and writes it beside the executable, which is a
  network request nobody asked for and fails in a read-only install directory.
- **A missing library is a refusal a person can act on** (new). Today a missing kernels
  library stops `cloak address` with tstokenlib's own build instructions under the step
  `unexpected`. It becomes a refusal naming the file that is missing and saying the
  install is incomplete.
- **`cloak status` names the native libraries it found**, and where (new, small): the
  smoke test and a support question both need it.
- **`cloak --version` names the build**: the program version, the commit it was built
  from, and the versions of the sibling libraries it was built against (new, small).
- **No launcher.** The `cloak` a person runs is the program itself, reached through a
  link. tstokenlib 2.0.1 finds its kernels in `lib/` beside the program's `bin/`, from the
  program's real path, so nothing has to be set before it starts.

**Around the program.**

- **Pinned, reproducible builds.** The sibling libraries come from pub.dev
  (`libcloak` 0.1.1, `tstokenlib` 2.1.0, `libspiffy` 3.0.0 and `ricochet` 0.1.0), and
  `pubspec.lock` is committed, pinning every package by version and digest. The suite no
  longer depends on `pool-coordinator`, an application of its own: the end-to-end run
  builds it from its checkout and runs it as a process. A developer keeps working against checkouts
  side by side through a `pubspec_overrides.yaml` that is not committed. This also fixes
  a fault found while planning: a fresh resolution of `cloak-cli` fails today, because
  pool-coordinator now takes tstokenlib from pub.dev while `cloak-cli` takes it by path; the
  build only works on this machine because of a lock file nobody else has.
- **A release workflow on a `v*` tag, for Linux.** Native runners (`ubuntu-22.04`,
  `ubuntu-22.04-arm`) build the kernels and the binary, assemble
  `cloak-<version>-linux-<arch>.tar.gz`, check what it links against, smoke-test it from
  a clean environment, and publish a **draft** release with `SHA256SUMS` and build
  provenance attestations. It needs no secret.
- **macOS, built on the maintainer's Mac.** A script builds and checks the same bundle,
  signs the binary and both libraries with the Werkswinkel team's Developer ID under the
  hardened runtime, packs them in a disk image, has Apple notarize it, staples the ticket,
  and adds it to the draft. No signing secret goes to GitHub. A Dart AOT binary is killed at
  start under the hardened runtime unless it carries
  `com.apple.security.cs.allow-unsigned-executable-memory` (measured 2026-09-24); that is
  the one entitlement it gets.
- **Installation.** An `install.sh` that picks the right bundle, checks its checksum and
  installs into the person's home directory (on macOS, from the disk image). Homebrew is
  left for later.
- **Licenses.** MIT LICENSE files for cloak-cli and for `libcloak`, the one sibling that
  still has none (ricochet, `merkledag` and `dart_libp2p_merkle_crdt` gained theirs when
  they were published), and a `THIRD_PARTY_NOTICES` in every bundle covering every package and native library in it.
- **The README** gains installing from a release, verifying it, platform minimums and
  upgrading.

## Capabilities

### New Capabilities

- `native-libraries`: how an installed `cloak` finds and loads its two native libraries,
  that it never downloads one, what it says when one is missing, and what `status`
  reports about them.
- `release-build`: the pinned inputs, the build per target, what a bundle
  contains, `--version`'s build facts, the checks a bundle passes before it is published,
  checksums and provenance, and licenses and notices.
- `macos-notarization`: the macOS disk image, built on the maintainer's Mac: signing every
  Mach-O under the hardened runtime with the one entitlement, notarizing and stapling, and
  what happens when signing is not
  available.
- `installation`: the link that reaches the program, `install.sh`, upgrading and
  removing, and the platforms supported.

### Modified Capabilities

None under `openspec/specs/`: the change `cloak-cli`, whose `command-shell` capability
owns `status` and `--version`, is not archived yet. The two small additions to those
commands are specified here under `native-libraries` and `release-build`, and fold into
`command-shell` when both changes are archived.

## Impact

**Numbers this change must stay inside.**

| measured (2026-09-24, Apple M3 Pro) | now | bound | a requirement? |
|---|---|---|---|
| `cloak --help`, first run of a compiled binary | 314 to 403 ms direct | **500 ms** (cloak-cli's `command-shell`) | already one, on the program itself; unchanged here |
| first run of a freshly copied binary | 570 ms, once | none | no: dominated by the operating system's first look at a new file, and on macOS by notarization's check; recorded per platform |
| bundle size, macOS arm64 | binary 18.3 MB, kernels 0.6 MB, `libisar` 2.2 MB; about 8 MB compressed | **25 MB compressed** | yes |
| network requests made by `--help`, `--version`, `status`, `balance` | Isar may download a library on first chain start | **none**, for every command, for a library | yes |

**The non-functional contract, by capability.** What the specs require, and what does not
apply:

| concern | `native-libraries` | `release-build` | `macos-notarization` | `installation` |
|---|---|---|---|---|
| untrusted input | a library planted in the working directory is never loaded | no native library is downloaded ready-built; both are built from pinned source | not applicable: it signs only what the build made | a download is checked against `SHA256SUMS` before anything is installed |
| secrets and privacy | no library is ever downloaded, so no request says who runs `cloak` | the workflow holds no secret; a bundle holds no wallet or key | the certificate and notary credentials stay in the maintainer's keychain | `install.sh` contacts GitHub only, sends nothing, and never opens a wallet |
| trust | libraries only from the bundle or the person's own `STARK_KERNELS_LIB` | provenance attestations bind a Linux bundle to the run and the tag | Apple's notarization, stapled | the checksum and the attestation, both checkable by the person |
| determinism | not applicable | every input pinned; `--version` names the commit and versions | not applicable | not applicable |
| compatibility | not applicable | glibc 2.35 and later; only system libraries linked | macOS 14 on Apple silicon | platforms named; others refused by name |
| performance and resources | not applicable: finding a file costs nothing measurable | at most 25 MB compressed | not applicable | not applicable: a link adds no process |
| failure | a missing library is a refusal naming it; the wallet is unchanged | any failure on any platform publishes nothing; releases are drafts | no Developer ID, no release | a failed install leaves the installed version as it was |

**Code.** `pubspec.yaml` and a committed `pubspec.lock`, `.gitignore`,
`lib/src/chain/spiffy_chain.dart` (Isar started from the bundle, never downloading), `lib/src/shell/cli.dart` and `wallet_commands.dart` (`--version`,
`status`), a new `lib/src/native/` for finding the libraries, `lib/src/build_facts.dart` (build
facts, written by the release build), new `tool/release/` (bundle assembly and checks), `.github/workflows/`, `install.sh`, `README.md`.

**Other repositories.** `libcloak` published on pub.dev with a license, by its owner (done:
0.1.1, Apache-2.0). No code change is asked of tstokenlib or pool-coordinator.

**Secrets and accounts.** A **Developer ID Application** certificate for the Werkswinkel Pte
Ltd team (`32XLPKQ5TF`): the team's identity on this machine is an Apple Development
certificate, which Apple's notary service does not accept, and only the team's account
holder can create the Developer ID one (Xcode, Manage Certificates). A `notarytool`
keychain profile on the same Mac. Nothing is stored on GitHub.

**Not in scope.** Windows, Intel Macs, Linux packages (`.deb`, `.rpm`), publishing the
libraries to pub.dev, and mainnet as the default network: the first releases are `0.x`
pre-releases with `testnet` as the default, because a seed alone cannot yet restore a
wallet.
