## Purpose

How an installed `cloak` finds and loads the two native libraries it cannot run without,
tstokenlib's kernels and Isar's core, from the bundle it was installed from and from
nowhere else, and what it tells a person when one is missing.

## ADDED Requirements

### Requirement: Native libraries come from the bundle

An installed `cloak` SHALL load tstokenlib's kernels library and Isar's core library from
the `lib/` directory of the bundle it was installed from, located from the real path of
the running program and not from the working directory. It SHALL do so whatever the
working directory is, and with no environment variable set by the person. A person MAY
point at another kernels library with `STARK_KERNELS_LIB`; nothing else overrides the
bundle.

#### Scenario: Run from anywhere
- **WHEN** a bundle built by a release build is installed, and `cloak init` then
  `cloak address` are run from a directory unrelated to the install, with an environment
  holding only `HOME`, `PATH` and `CLOAK_PASSPHRASE`
- **THEN** both SHALL exit 0, and `cloak address` SHALL print an address, which needs the
  kernels (key derivation uses ML-KEM)

#### Scenario: Reached through a link
- **WHEN** the program is run through a symbolic link to it placed in another directory,
  as `install.sh` installs it
- **THEN** it SHALL find the libraries in the bundle the link points into

### Requirement: No library is ever loaded from the working directory

`cloak` SHALL NOT load a native library from the working directory or any directory above
it. A library planted there is code a stranger chose; the working directory is wherever
the person happened to be.

#### Scenario: A planted library is not loaded
- **WHEN** the bundle's kernels library is removed, and `cloak address` is run from a
  directory holding `native/stark_kernels/target/release/` with a file of the kernels
  library's name in it
- **THEN** the command SHALL refuse as for a missing library (below), and the planted file
  SHALL NOT have been opened

### Requirement: No library is ever downloaded

`cloak` SHALL NOT make a network request to fetch a native library, and SHALL NOT write a
library anywhere. A download on first use is a request the person did not ask for,
revealing that they run `cloak` and when, and it fails in a read-only install directory.

#### Scenario: Isar's library absent
- **WHEN** the bundle's Isar library is removed, the bundle directory is made read-only,
  and a command that starts the chain (`cloak sync`) is run against localnet
- **THEN** the command SHALL refuse at the step `native library`, naming the Isar library
  file and the directory it was looked for in
- **AND** no file SHALL have been created in the bundle, the working directory or the
  wallet directory by the attempt

### Requirement: A missing or unusable library is a refusal a person can act on

When a command needs a native library that is missing, fails to load, or is not the
version this build was made with, it SHALL refuse at the step `native library`, naming the
file, the directory looked in, and that the installation is incomplete and should be
reinstalled. It SHALL exit 1, SHALL NOT print a stack trace or a build instruction meant
for a developer, and SHALL change nothing in the wallet.

#### Scenario: The kernels library removed
- **WHEN** the bundle's kernels library is removed and `cloak address` is run
- **THEN** it SHALL exit 1 with a refusal at `native library` naming
  `libstark_kernels.dylib` (or `.so`) and the bundle's `lib/` directory
- **AND** the wallet's address counter SHALL be unchanged
- **AND** the output SHALL NOT contain `cargo`

#### Scenario: A library of the wrong version
- **WHEN** the bundle's kernels library is replaced by one reporting another interface
  version
- **THEN** the refusal SHALL say the library is not the version this build expects,
  naming both versions

### Requirement: Commands that need no native library work without them

`cloak --help`, `cloak --version`, `cloak status`, `cloak balance`, `cloak notes` and
`cloak journal` SHALL NOT load either native library, so a person can see what they hold
and what is wrong with an installation that is missing one.

#### Scenario: A bundle with no libraries
- **WHEN** the bundle's `lib/` directory is removed
- **THEN** each of those commands SHALL exit as it would with the libraries present

### Requirement: status reports the native libraries

`cloak status` SHALL report, for each native library, the path it would be loaded from
and whether a file is there, without loading it, starting the chain or touching the
network. `--json` SHALL carry the same facts.

#### Scenario: Both present
- **WHEN** `cloak status --json` is run on an installed bundle
- **THEN** the object SHALL name both libraries, each with its path inside the bundle and
  `present: true`

#### Scenario: One missing
- **WHEN** the kernels library is removed and `cloak status` is run
- **THEN** it SHALL exit 0 and say the kernels library is missing, naming the path
