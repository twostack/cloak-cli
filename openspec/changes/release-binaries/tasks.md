# Tasks

Every task says how it is shown done. Numbers are recorded in `docs/DESIGN.md` in a new
dated section, appended, never rewritten, with the machine or runner they were taken on.

Group 0 is work **outside this repository**: in sibling repositories, in accounts only the
person holds, or on GitHub. It is named here rather than absorbed, and nothing in it is
done without the person's go-ahead for that repository or account.

## 0. Work owed outside this repository

- [x] 0.1 **Person**: create a *Developer ID Application* certificate for the Werkswinkel Pte
  Ltd team (`32XLPKQ5TF`), in Xcode: Settings, Accounts, the team, Manage Certificates, +,
  Developer ID Application (only the account holder can). The team's identity here now is
  an Apple Development certificate, which notarization refuses. *Verified by*:
  `security find-identity -v -p codesigning` on this machine lists a
  `Developer ID Application: Werkswinkel Pte Ltd (32XLPKQ5TF)` identity.
- [x] 0.2 **Person**: store notary credentials in the keychain as the profile
  `cloak-notary`: `xcrun notarytool store-credentials cloak-notary` with an app-specific
  password for the team's Apple ID, or an App Store Connect API key. Nothing goes to GitHub.
  *Verified by*: `xcrun notarytool history --keychain-profile cloak-notary` answers.
- [x] 0.4 **In `../libcloak`**, by its owner: a `LICENSE`, `tstokenlib` as a hosted
  dependency, and the package published on pub.dev. *Verified by*: pub.dev lists
  `libcloak` 0.1.1, depending on `tstokenlib` ^2.1.0, with an Apache-2.0 `LICENSE`, which
  the notices carry.
- [ ] 0.5 ~~In `../pool-coordinator`: its move to hosted dependencies committed~~. No longer
  owed: the person pointed out that a package depending on an application is backwards, so
  `cloak-cli` no longer depends on `pool_coordinator` at all (task 2.5), and its commits do
  not bear on this repository's lock.
- [ ] 0.6 Spike: build Isar's core library from the Isar repository at the commit behind
  `isar` 3.1.0+1 on `ubuntu-22.04-arm`, `ubuntu-22.04` and `macos-14`, in a scratch
  workflow. *Verified by*: each run produces a library that `Isar.initializeIsarCore` loads
  and a Dart script opens a database with. If Linux arm64 fails, stop and raise it with the
  person (design.md, Risks) before continuing past group 5.

## 1. Native libraries in the program

- [x] 1.1 Add `lib/src/native/`: the bundle's layout (`bin/cloak`, `lib/`), whether this is
  a release build (the `cloak.release` define), and the paths of both libraries from
  `Platform.resolvedExecutable`. *Verified by*: a unit test with a fake executable path in
  a temporary bundle gets both paths, and gets them through a symbolic link to the
  executable; on a real bundle, the smoke test's "Run from anywhere".
- [x] 1.2 Check the kernels before any command that opens keys or builds a transfer: the
  file tstokenlib takes first (the one `STARK_KERNELS_LIB` names, else, in a release
  build, the bundle's) exists, opens, and reports `StarkKernels.abiVersion`; otherwise
  `Refusal('native library', ...)` naming the file, the directory, and both versions when
  they differ. A development build with the variable unset keeps tstokenlib's search.
  *Verified by*: tests for "The kernels library removed" and "A library of the wrong version" (a stub library built in the test reporting another version).
- [x] 1.3 Map tstokenlib's `StateError` about the native crate to the same refusal in the
  shell, and confirm a planted library is never reached: "A planted library is not loaded"
  (a file of the kernels library's name under the working directory, with the bundled one
  removed; the test asserts the refusal and that the file was never opened). *Verified by*: a test forcing it prints `native library` and no `cargo`.
- [x] 1.4 Start Isar from the bundle in a release build: explicit path, `download: false`,
  refusal before Isar is touched when the file is missing. *Verified by*: the test for
  "Isar's library absent", run on the bundle with a read-only directory, asserting no file
  was created anywhere.
- [x] 1.5 `cloak status` reports both libraries, path and presence, without loading them.
  *Verified by*: tests for "Both present" and "One missing", and the existing "status touches no network" assertion still holding.
- [x] 1.6 Confirm the commands that need no native library never load one. *Verified by*:
  the test for "A bundle with no libraries" over `--help`, `--version`, `status`,
  `balance`, `notes`, `journal`.
- [x] 1.7 Robustness: a mutation test over the kernels library file (truncated, zeroed,
  random bytes, a different platform's library) and over `STARK_KERNELS_LIB` values
  (a directory, a missing path, an empty string). *Verified by*: every case is a
  `native library` refusal with exit 1 and no stack trace, recorded with its counts.

## 2. Pinned inputs

- [x] 2.1 Switch `libcloak`, `libspiffy`, `tstokenlib` and `ricochet` to their pub.dev
  versions; add `pubspec_overrides.yaml.example` for side-by-side checkouts and keep
  `pubspec_overrides.yaml` ignored. *Verified by*: `dart analyze lib bin test` clean and the
  default suite passing with and without the overrides file.
- [x] 2.2 Commit `pubspec.lock` (remove it from `.gitignore`). *Verified by*: the test for
  "A fresh machine resolves": a clone of `cloak-cli` alone in a temporary directory
  resolves with `dart pub get --enforce-lockfile` and the lock is unchanged.
- [x] 2.5 Remove the dev dependency on `pool_coordinator`: the localnet end-to-end run builds
  the coordinator from its checkout (`../pool-coordinator`, or `POOL_COORDINATOR`) and runs
  its `create` and `run` as processes, and the two localnet transport tests play its end of
  ricochet with `test/support/coordinator_end.dart`. *Verified by*: the end-to-end run and
  the localnet transport and sync tests passing, and "The runtime dependency graph" asserting
  neither the program nor the suite depends on it.
- [x] 2.3 `--version` build facts: the release build writes the `cloak-cli` commit and each
  sibling's version from `pubspec.lock` into `lib/src/build_facts.dart` (`dart build cli`
  takes no `--define`) and puts the committed file back; without them the program
  says `development build`. *Verified by*: tests for "A developer's binary" and, in the smoke test, "A released binary".
- [x] 2.4 Update `openspec/config.yaml`'s context, which still says tstokenlib is on
  `feature/shielded-pool` and a path dependency. *Verified by*: the context names the
  hosted versions, the lock and the overrides file.

## 3. The bundle

- [x] 3.1 Reached through a link: in the smoke test, run the bundle's `bin/cloak` through a
  symbolic link in another directory, from a bundle unpacked under a path with a space.
  *Verified by*: the tests for "A path with spaces" and "Reached through a link".
- [x] 3.2 Write the bundle assembly (`tool/release/assemble.sh`): layout, `LICENSE`,
  `README.md`, notices. *Verified by*: the test for "What a bundle holds" on a locally
  assembled macOS bundle.
- [x] 3.3 Generate `THIRD_PARTY_NOTICES` from the resolved packages that are compiled in,
  plus the two native libraries; fail on a package with no license found. *Verified by*:
  the test for "Every package accounted for", and a test that removing one package's
  license file fails the generation naming it.
- [x] 3.4 Add `LICENSE` (MIT) to `cloak-cli`. *Verified by*: the file exists and the bundle
  carries it.
- [x] 3.5 ("Checking what links") Write the link check (`tool/release/check-links.sh`) against the spec's allowed
  lists, including install names. *Verified by*: it passes on a bundle whose kernels were
  built as task 5.2 builds them, and fails, naming the file, on the kernels library as
  built locally today, whose install name is its build directory.
- [x] 3.6 Write the smoke test (`tool/release/smoke.sh`): a fresh directory, an environment
  of `HOME`, `PATH` and `CLOAK_PASSPHRASE` only, the commands the spec lists, the
  "no file outside the wallet directory" check and the planted-library check. *Verified by*: it passes on a local bundle and fails when `lib/` is removed.
- [x] 3.7 Write the secret scan of a bundle (wallet files, WIF and hex keys, the
  certificate). *Verified by*: the test for "A bundle holds no one's secrets" passes on a
  real bundle and fails on one with a planted `wallet.enc`.

## 4. The macOS signing

- [x] 4.1 Add `tool/release/cloak.entitlements` with the one entitlement, and
  `tool/release/sign-macos.sh` signing the libraries then the program with the hardened
  runtime and a timestamp. *Verified by*: the tests for "Signatures checked" and "The signed program runs and loads its libraries", run with the Developer ID from 0.1.
- [x] 4.2 Pack the signed bundle into the disk image, sign it, notarize it with
  `notarytool submit --wait --keychain-profile`, keep the log, and staple the ticket.
  *Verified by*: "Accepted" for a local image, and "Quarantined" on it; "Rejected" by
  submitting an image whose program was signed without the hardened runtime.
- [ ] 4.3 Write `tool/release/macos.sh`, the whole macOS build from a clean checkout of a
  tag: the refusal without a Developer ID or notary profile, the checks a Linux job runs,
  signing, the image, notarization, and adding the image to the tag's draft with
  `SHA256SUMS` rewritten. *Verified by*: "No Developer ID" (run on this machine before 0.1,
  where it must refuse and leave no image), and "The draft gains the image" on
  `v0.1.0-rc.1`.

## 5. The workflows

- [ ] 5.1 A `ci.yml` on every push and pull request: resolve with the lock enforced,
  analyze, run the default suite, on `macos-14` and `ubuntu-22.04`. No secret. *Verified by*: a green
  run on `main`.
- [ ] 5.2 A `release.yml` on `v*` tags, with no secret: the tag and version check, the two
  Linux jobs building both native libraries from pinned source and the program with the
  release defines, the link check, the size check ("Size checked"), the smoke test and the
  secret scan. *Verified by*: "A workflow with no secrets", and the tests for "A tag that disagrees", "A pinned version missing" and "The native libraries' sources are named" on
  pre-release tags.
- [ ] 5.3 The publishing job: only when both Linux jobs passed, `SHA256SUMS`, provenance
  attestations, a draft release. *Verified by*: the tests for "One platform fails" (a forced failure) and "A passing run" on `v0.1.0-rc.1`, and "Checking a download" against
  its assets.
- [ ] 5.4 Cache Isar's build per platform and source commit. *Verified by*: a second
  run on the same commits reports cache hits and builds no Rust.

## 6. Installation

- [ ] 6.1 Write `install.sh`, taking the bundle out of the disk image on macOS. *Verified by*: tests for "A clean install", "An Intel Mac" (the platform check with `uname` faked), the glibc refusal (faked), "Upgrade" and "Uninstall",
  run in a temporary `HOME` against the `v0.1.0-rc.1` assets.
- [x] 6.2 Robustness: a mutation test of `install.sh` over the download (truncated bundle or image,
  flipped bytes, a `SHA256SUMS` missing the line, naming another file, or malformed, and a
  failed download part way). *Verified by*: "A corrupted download", and every case exits non-zero, names what failed,
  and leaves `~/.local/share/cloak` and the link as they were; counts recorded.
- [ ] 6.4 Rewrite the README's install section: `install.sh`, the macOS disk image by hand, a
  manual Linux download with its checksum and attestation checks, checking the image's
  notarization, platforms, upgrading and uninstalling.
  *Verified by*: the README test still matches the command table, and task 7.2 follows the
  section ("Instructions checked").

## 7. The first release and the record

- [ ] 7.1 Measure on each platform's bundle: the first run of a fresh install, the bundle's compressed size (bound
  25 MB), and `cloak --help` against `cloak-cli`'s 500 ms bound. *Verified by*: the numbers
  in `docs/DESIGN.md`; a missed bound is handled as design.md's Risks say.
- [ ] 7.2 The release checklist in `docs/RELEASING.md`, and run it for `v0.1.0`: the localnet
  end-to-end run against the built macOS bundle, the README's install section followed on
  a clean macOS arm64 machine and on Linux amd64 and arm64, then publishing the draft.
  *Verified by*: the checklist completed for `v0.1.0` and recorded in `docs/DESIGN.md`.
- [ ] 7.3 Run `dart analyze lib bin test` and the suite forms, and record the counts.
  *Verified by*: zero analyzer issues and the counts in `docs/DESIGN.md`.
