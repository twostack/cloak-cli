# Releasing cloak

The checklist for a release. Linux is built and checked by the release workflow on GitHub,
which holds no secret; macOS is built, signed and notarized on the maintainer's Mac by
`tool/release/macos.sh`, so the signing certificate and the notary credentials never leave
it. What is here is what a person does around the two, in order, and records.

## Once, on the Mac that signs

- [ ] A *Developer ID Application* certificate for Werkswinkel Pte Ltd (team `32XLPKQ5TF`)
      in the login keychain: Xcode, Settings, Accounts, the team, Manage Certificates, +,
      Developer ID Application. Only the team's account holder can create one. The *Apple
      Development* certificate already there does not do: Apple notarizes only what a
      Developer ID signed. `security find-identity -v -p codesigning` should list
      `Developer ID Application: Werkswinkel Pte Ltd (32XLPKQ5TF)`.
- [ ] Notary credentials as a keychain profile:
      `xcrun notarytool store-credentials cloak-notary`, with the team's Apple ID and an
      app-specific password, or an App Store Connect API key. `xcrun notarytool history
      --keychain-profile cloak-notary` should answer.
- [ ] `gh auth login`, able to upload to `twostack/cloak-cli`'s releases.

`tool/release/macos.sh --trial` builds and checks everything but notarization and the upload,
with any signing identity, to try the machine out.

## Each release

1. **Pins.** `pubspec.yaml` and `pubspec.lock` name the sibling versions to release against,
   resolved without `pubspec_overrides.yaml`; `ci` is green on `main` at the commit to tag.
2. **Version.** `version:` in `pubspec.yaml` and `CloakVersion.program` agree, and the
   commit that sets them is on `main`.
3. **Tag.** `git tag v<version>` and push the tag. A tag that disagrees with `pubspec.yaml`
   fails at once.
4. **Linux.** The `release` run builds both Linux bundles and checks them (analyze, suite,
   links, size, smoke, secret scan), then makes a draft release holding them and
   `SHA256SUMS`. If either failed there is no draft; fix, delete the tag, tag again.
5. **macOS.** On the signing Mac, from a clean checkout of the tag with no
   `pubspec_overrides.yaml`: `tool/release/macos.sh`. It refuses without the Developer ID,
   the notary profile or the draft. It runs the same checks, signs, makes the disk image,
   notarizes and staples it, runs it quarantined, and adds it to the draft with
   `SHA256SUMS` over all three files. Keep `build/macos/notary-log.json`.
6. **End to end.** Run the localnet end-to-end suite against the signed program:
   `CLOAK_E2E_BINARY=build/macos/bundle/cloak-<version>-macos-arm64/bin/cloak
   POOL_LOCALNET=1 POOL_E2E=1 dart test -t e2e`, with `STARK_KERNELS_LIB` unset, which covers
   receive, deposit, pay, prove, check, acknowledge, withdraw and refund.
7. **The draft.** It holds the disk image, two Linux bundles and `SHA256SUMS`. Download each
   and check it as the README says: `shasum -a 256 -c`, `gh attestation verify` for Linux,
   `spctl --assess --type open` for the image.
8. **Clean machines.** Follow the README's install section, word for word, on a clean macOS
   arm64 machine (the install script, and the disk image by hand) and on Linux amd64 and
   arm64: `cloak --version` names the tag's commit, and `cloak init`, `cloak address` and
   `cloak status` work. Note the first run's time on each.
9. **Publish.** Publish the draft.
10. **Record.** Append a dated section to `docs/DESIGN.md`: the tag and commit, the run, the
    notarization's submission id, the sizes, the first-run times, and anything that went
    wrong.

## Undoing a release

Mark the release a pre-release or delete it. Installed copies keep working: each version is
its own directory.
