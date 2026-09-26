## Purpose

Where a person's wallet lives on disk and how it is opened: the config file, the data
directory, creating and unlocking a wallet, and saving the four state files libcloak
defines so that a crash or a second process never leaves a wallet that has spent a
note it still believes it holds.

## ADDED Requirements

### Requirement: One directory holds a wallet

A wallet SHALL be one directory holding a config file, the encrypted wallet file, the
pool view, the note store and the journal directory. The directory SHALL be chosen by
`--wallet <dir>`, else by an environment variable, else by a default under the user's
home; the order SHALL be that, and `cloak status` SHALL print which one was used.

#### Scenario: The directory in use is always visible
- **WHEN** `cloak status` is run with `--wallet` given, with only the environment
  variable set, and with neither
- **THEN** each run SHALL print the directory it resolved and which of the three
  sources named it

### Requirement: A wallet directory is owner-only

On creation the wallet directory and every file in it SHALL be given
owner-only permissions. A command that finds the directory readable by anyone else
SHALL warn on standard error naming the path, and SHALL continue, because refusing
would leave a person unable to reach their own money.

#### Scenario: A world-readable wallet is reported
- **WHEN** the wallet directory's mode is widened and any command is run
- **THEN** standard error SHALL carry a warning naming the path and the mode found
- **AND** the command SHALL still do its work

### Requirement: Creating a wallet writes a seed once

`cloak init` SHALL generate a wallet seed, encrypt it under a passphrase the person
supplies, write it, and print the seed for the person to record. It SHALL refuse to
run in a directory that already holds a wallet file, naming the path, so a second
`init` can never overwrite a wallet holding notes.

#### Scenario: init refuses an occupied directory
- **WHEN** `cloak init` is run twice in the same directory
- **THEN** the second run SHALL refuse naming the existing wallet file
- **AND** the existing file SHALL be byte-identical afterwards

#### Scenario: The seed is recorded before anything else exists
- **WHEN** `cloak init` completes
- **THEN** the seed SHALL have been printed
- **AND** no pool view, note store or journal entry SHALL exist yet, so a person who
  loses the seed at this moment has lost nothing

### Requirement: The passphrase is asked for, not stored

A command needing the spending key SHALL obtain the passphrase from a terminal prompt
with echo off, or from a named environment variable for non-interactive use. The
passphrase and the decrypted seed SHALL exist only for the life of the process, and
SHALL NOT be written to any file, cache or log.

#### Scenario: Non-interactive use works without a terminal
- **WHEN** `cloak pay` is run with no terminal attached and the passphrase in the named
  environment variable
- **THEN** the command SHALL proceed without prompting

#### Scenario: A wrong passphrase is a named refusal
- **WHEN** the passphrase given does not open the wallet file
- **THEN** the program SHALL refuse naming the wallet file and that the passphrase did
  not open it, and SHALL NOT say whether the file is corrupt, because it cannot tell
- **AND** SHALL exit 1

### Requirement: Only one process writes a wallet

Before changing any state file, a command SHALL take an exclusive lock on the wallet
directory. A command that cannot take it SHALL refuse naming the directory and the
process holding it where the system reports one, and SHALL NOT wait indefinitely.

#### Scenario: Two payments at once
- **WHEN** two `cloak pay` processes are started against one wallet directory
- **THEN** exactly one SHALL proceed and the other SHALL refuse naming the lock
- **AND** the note store afterwards SHALL show exactly one note reserved

#### Scenario: A read-only command needs no lock
- **WHEN** `cloak balance` is run while another command holds the lock
- **THEN** it SHALL succeed, because it changes nothing

### Requirement: A state file is replaced whole or not at all

Every state file SHALL be written to a temporary name in the same directory and
renamed over the live file. A command SHALL NOT leave a partially written state file
in place of a whole one.

#### Scenario: Killed mid-write
- **WHEN** the process is killed after the temporary file is written and before the
  rename, for each of the pool view, the note store and the wallet file
- **THEN** the next command SHALL open the previous contents of that file without
  complaint
- **AND** the temporary file SHALL be removed or ignored, never read as state

### Requirement: State files are refused, not guessed at

Each state file carries a format version. A file whose version this build does not
write SHALL be refused naming the file and both versions. A file that does not decode
SHALL be refused naming the field that stopped it, and SHALL NOT be rewritten,
truncated or repaired.

#### Scenario: A truncated note store
- **WHEN** a note store file is truncated at each of a hundred byte offsets and opened
- **THEN** every open SHALL return a refusal naming a field, and none SHALL throw
- **AND** the file SHALL be unchanged after each attempt

### Requirement: The note store is not encrypted, and that is stated

The note store holds note openings, which include a note's randomness. It SHALL be
written unencrypted, as libcloak defines it, so that two stores that took the same
notes hold byte-identical bytes. `cloak status` SHALL say so, naming the file, so a
person knows which file is worth protecting beyond its permissions.

#### Scenario: status tells the truth about the files
- **WHEN** `cloak status` is run
- **THEN** it SHALL list each state file, its size, and whether it is encrypted

### Requirement: Writing state stays inside its bound

Saving all state after a payment SHALL take under 500 ms for a wallet holding 1,000
notes, measured on the machine the suite records. The sizes libcloak measured hold
here: 1,069 bytes a note in the pool view, 73 bytes a note in the note store, 142
bytes a journal entry.

#### Scenario: A thousand notes save inside the bound
- **WHEN** a wallet holding 1,000 notes saves its pool view, note store and one
  journal entry
- **THEN** the elapsed time SHALL be under 500 ms, as a best-of-N measurement so a
  loaded machine does not decide it
