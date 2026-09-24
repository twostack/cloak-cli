## Purpose

Makes the macOS release something macOS will run when a person downloads it: a disk image
built on the maintainer's own Mac, every executable file in it signed with a Developer ID
under the hardened runtime (with the one exception the Dart runtime needs), the image itself
signed, notarized by Apple and stapled. No signing secret leaves that Mac.

## ADDED Requirements

### Requirement: Every Mach-O in the macOS bundle is signed

The program and both native libraries in the macOS bundle SHALL be signed with a Developer
ID Application identity, with the hardened runtime and a secure timestamp. The program
SHALL carry exactly one entitlement, `com.apple.security.cs.allow-unsigned-executable-memory`;
the libraries SHALL carry none.

The entitlement is measured, not assumed: on 2026-09-24, on macOS 14.6 on an Apple M3 Pro,
a Dart 3.11.5 AOT binary signed with the hardened runtime and no entitlement was killed at
start (exit 137), and with `com.apple.security.cs.allow-jit` alone likewise; with this one
it ran, and loaded a kernels library signed by the same identity.

#### Scenario: Signatures checked
- **WHEN** the build runs `codesign --verify --strict` on each Mach-O in the bundle
- **THEN** each SHALL pass, `codesign -d --entitlements -` SHALL show exactly the one
  entitlement on the program and none on the libraries, and each SHALL show the hardened
  runtime flag and a timestamp

#### Scenario: The signed program runs and loads its libraries
- **WHEN** the signed bundle is copied out of the image and `cloak init --network regtest`
  then `cloak address` are run through a link to the program
- **THEN** both SHALL exit 0

### Requirement: The macOS release is a signed, notarized, stapled disk image

The macOS release SHALL be one disk image, `cloak-<version>-macos-arm64.dmg`, read-only
and compressed, whose volume holds the bundle directory `cloak-<version>-macos-arm64/`
exactly as `release-build` lists a bundle's entries, and nothing else. The image SHALL be
signed with the same Developer ID, submitted to Apple's notary service, and published only
once the submission is accepted, with the ticket stapled to the image. The notary log SHALL
be kept beside the build's output.

#### Scenario: Accepted
- **WHEN** the build submits the signed image
- **THEN** it SHALL wait for Apple's answer, continue only on `Accepted`, staple the
  ticket, and `xcrun stapler validate` and
  `spctl --assess --type open --context context:primary-signature` SHALL both accept the
  image

#### Scenario: Rejected
- **WHEN** Apple answers `Invalid`
- **THEN** the build SHALL fail, print the issues from the notary log, and leave no image
  named as a release

### Requirement: A downloaded image runs without a warning

A disk image downloaded through a browser, and so marked quarantined, SHALL open, and the
program copied out of it SHALL run, with no Gatekeeper dialog and no command from the person
to clear the mark. Because the ticket is stapled, this SHALL hold on a machine that cannot
reach Apple.

#### Scenario: Quarantined
- **WHEN** the image is given the `com.apple.quarantine` attribute, mounted, its bundle
  copied out with the attribute carried over, and the program run with `--version`
- **THEN** it SHALL print the version and exit 0, where a program that was not notarized is
  killed by macOS; and `spctl --assess --type open --context context:primary-signature` on
  the image SHALL name `Notarized Developer ID` (`spctl`'s execute assessment judges only
  app bundles, and says of any command-line program that it "does not seem to be an app")

### Requirement: Signing stays on the maintainer's Mac

The Developer ID certificate's private key and the notary service's credentials SHALL be
kept only in the maintainer's keychain: the credentials as a `notarytool` keychain profile.
Neither SHALL be stored in the repository, in GitHub (no secret, no environment), in a log,
or in a bundle or image. The macOS build SHALL be run by the maintainer on their own Mac.
When no Developer ID Application identity or no notary profile is found, it SHALL refuse
before building anything, naming what is missing and the identities it did find, and SHALL
produce no image named as a release.

#### Scenario: No Developer ID
- **WHEN** the macOS build is run on a Mac whose keychain holds only Apple Development
  identities
- **THEN** it SHALL exit non-zero naming `Developer ID Application` and listing the
  identities found, and no `cloak-<version>-macos-arm64.dmg` SHALL exist afterwards

### Requirement: The image joins its release

The image SHALL be added to the draft release the workflow made for the same tag, and the
release's `SHA256SUMS` SHALL be rewritten to list it beside the Linux bundles. The macOS
build SHALL refuse when its tag has no draft release or the draft's version differs, and a
release SHALL NOT be published without its macOS image.

#### Scenario: The draft gains the image
- **WHEN** the macOS build finishes for a tag whose draft release holds the two Linux
  bundles
- **THEN** the draft SHALL hold the three files and a `SHA256SUMS` with a line for each,
  and `shasum -a 256 -c SHA256SUMS` SHALL pass over them
