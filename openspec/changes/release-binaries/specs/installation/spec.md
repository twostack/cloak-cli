## Purpose

How a person gets `cloak` onto their machine, keeps it up to date and takes it off again:
the link that reaches it, a one-command installer and the macOS disk image, on the
platforms a release supports.

## ADDED Requirements

### Requirement: The program is run through a link to it

The `cloak` a person runs SHALL be the program itself, `bin/cloak` in the bundle, reached
through a symbolic link that `install.sh` or the person places on their path. There is
no launcher script between them: tstokenlib 2.0.1 finds its kernels in `lib/` beside the
program's `bin/`, from the program's real path, so nothing needs setting before the program
starts, and a script would only add a process and a shell's start-up to every command.
Arguments, standard input and the exit code are the program's own.

#### Scenario: A path with spaces
- **WHEN** the bundle is unpacked under a directory whose name contains a space, and
  `cloak init --network regtest` then `cloak address` are run through a link to
  `bin/cloak` placed in another directory
- **THEN** both SHALL exit 0

### Requirement: One command installs it

An `install.sh`, published with each release and at a stable address in the repository,
SHALL install `cloak` for the person running it, without `sudo`:

- it SHALL recognise macOS on arm64 and Linux on x86_64 and aarch64, and refuse any other
  platform naming it and the platforms that are supported;
- on Linux it SHALL refuse, naming both versions, a C library older than glibc 2.35;
- it SHALL download the bundle for the platform (on macOS, the disk image) and `SHA256SUMS`
  from the GitHub release, the latest one or the version given, over HTTPS only;
- it SHALL check the bundle against `SHA256SUMS` and, on any mismatch or failed download,
  install nothing and leave any installed version as it was;
- it SHALL unpack, or on macOS copy out of the image, mounted read-only and detached
  afterwards, into `~/.local/share/cloak/<version>/` and point the link
  `~/.local/bin/cloak` at that version's `bin/cloak`, and say so, and say how to add
  `~/.local/bin` to `PATH` when it is not there.

It SHALL contact no host but GitHub's, and send nothing about the person or a wallet.

#### Scenario: A clean install
- **WHEN** `install.sh` is run on a supported platform with no `cloak` installed
- **THEN** `~/.local/bin/cloak --version` SHALL print the release's version

#### Scenario: A corrupted download
- **WHEN** the downloaded bundle does not match `SHA256SUMS`
- **THEN** `install.sh` SHALL exit non-zero naming the file and both digests, and
  `~/.local/share/cloak/` and `~/.local/bin/cloak` SHALL be as they were before

#### Scenario: An Intel Mac
- **WHEN** `install.sh` is run on macOS on x86_64
- **THEN** it SHALL refuse, naming `macOS x86_64` and the supported platforms, and install
  nothing

### Requirement: Upgrading and removing never touch a wallet

Running `install.sh` for a newer version SHALL install it beside the old one and move the
link; the previous version SHALL stay until removed. `install.sh --uninstall` SHALL remove
`~/.local/share/cloak/` and the link, and SHALL NOT remove, read or open a wallet directory
(`~/.cloak`, or wherever `CLOAK_WALLET` points), saying where the wallet is and that it was
left alone.

#### Scenario: Upgrade
- **WHEN** version A is installed and `install.sh` installs version B
- **THEN** `cloak --version` SHALL print B, and A's directory SHALL still exist

#### Scenario: Uninstall
- **WHEN** a wallet exists in `~/.cloak` and `install.sh --uninstall` is run
- **THEN** the program SHALL be gone, `~/.cloak` SHALL be byte-for-byte as it was, and the
  output SHALL say the wallet in `~/.cloak` was not touched

### Requirement: The README says how to install, check and upgrade

The README SHALL tell a person how to install with `install.sh`, how to install from the
macOS disk image by hand, how to download a Linux bundle by hand and check it against
`SHA256SUMS` and its attestation, how to check the image's notarization, the
platforms supported (macOS 14 or later on Apple silicon; Linux on amd64 or arm64 with
glibc 2.35 or later), how to upgrade and uninstall, and that neither touches the wallet.

#### Scenario: Instructions checked
- **WHEN** the README's install section is followed on a clean machine of each platform,
  as the release checklist does
- **THEN** each step SHALL work as written
