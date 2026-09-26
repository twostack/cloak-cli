## Purpose

The binary a person types: which commands exist, how their arguments are read, what
they print and on which stream, what their exit codes mean, and how a refusal from a
library below reaches the person as the rule that failed rather than as a stack trace.

## Requirements

### Requirement: One binary, one command per line of work

The program SHALL be a single executable named `cloak` taking a subcommand as its
first argument. Each subcommand SHALL do one unit of a person's work and return; no
subcommand runs a daemon, a watcher or a background loop.

The subcommands SHALL be: `init`, `unlock`, `address`, `status`, `sync`, `invoice`,
`pay`, `proof`, `check`, `ack`, `balance`, `notes`, `journal`, `receive`, `deposit`,
`refund`, `withdraw`.

#### Scenario: An unknown subcommand
- **WHEN** `cloak frobnicate` is run
- **THEN** the program SHALL print to standard error that `frobnicate` is not a
  command, list the commands that exist, and exit with code 2
- **AND** SHALL NOT read the wallet, open the transport or start the header chain

#### Scenario: Help costs nothing
- **WHEN** `cloak` is run with no subcommand, or with `--help`
- **THEN** the program SHALL print usage to standard output and exit 0
- **AND** SHALL NOT open the wallet file, start the SPV side or contact the pool

### Requirement: A refusal names the rule that failed

Every library below this one answers a bad input with a refusal naming a step. The
program SHALL print that step and its sentence, and SHALL NOT replace either with a
word of its own. A message reading only "invalid", "error" or "failed" is a defect.

#### Scenario: A proof that does not check out
- **WHEN** `cloak check` is given a payment proof whose round transaction carries a
  forged PP1, as `test/forged_round` supplies
- **THEN** standard error SHALL carry the step name the checker returned, for example
  `PP1 is this pool's script`, and the checker's own sentence
- **AND** the exit code SHALL be 1

#### Scenario: Bytes that are not a message at all
- **WHEN** `cloak check` is given a file of random bytes
- **THEN** the program SHALL print the refusal the decoder returned, naming the field
  that stopped it and the size it expected
- **AND** SHALL NOT throw, print a Dart stack trace, or exit with a code above 2

### Requirement: Exit codes distinguish the three outcomes

The program SHALL exit 0 when the work asked for was done, 1 when a rule refused it,
and 2 when the command itself was malformed. No other code SHALL be returned from a
handled path.

#### Scenario: A refusal is not a usage error
- **WHEN** `cloak pay` is given a well-formed invoice that has expired
- **THEN** the exit code SHALL be 1, not 2, because the command was correct and the
  invoice was refused

### Requirement: Untrusted input is bounded before it is read

Every argument that names a file of bytes from another person, which is at least
`invoice show`, `pay`, `check` and `ack`, SHALL have its size checked against the
maximum the corresponding message declares before the file is read into memory. A
file larger than that SHALL be refused naming the message kind and both sizes.

#### Scenario: An oversized invoice file
- **WHEN** `cloak invoice show` is given a file one byte larger than an invoice's
  maximum encoding
- **THEN** the program SHALL refuse naming the kind and both sizes
- **AND** SHALL NOT allocate a buffer of the file's size

### Requirement: No command prints a secret

The program SHALL NOT write a seed, a spending key, a wallet passphrase, an RPC
password or a ricochet identity seed to standard output, to standard error, or to any
log, at any verbosity. Where such a value must be shown to be useful, which is only
the seed phrase at `init`, it SHALL be written once to standard output with nothing
else on the stream, so it can be redirected to a file without carrying anything beside
it.

#### Scenario: Verbose output holds no key material
- **WHEN** every command is run at the highest verbosity the program accepts, against
  the fake pool the suite already stands up
- **THEN** a test SHALL search the whole of both streams for the wallet's seed bytes,
  its spending key, its passphrase and its ricochet seed, in raw and hexadecimal form,
  and find none

#### Scenario: A passphrase is never an argument
- **WHEN** any command needing the wallet passphrase is run
- **THEN** the passphrase SHALL be read from a terminal prompt or from a named
  environment variable, never from a command-line argument
- **AND** a passphrase given as an argument SHALL be refused naming the risk, because
  arguments are visible to every process on the machine

### Requirement: Output is readable by a person and by a program

Every command that reports a result SHALL print it in lines a person can read. Every
such command SHALL also accept `--json` and print the same result as one JSON object
on standard output with nothing else on that stream.

#### Scenario: Both forms carry the same facts
- **WHEN** `cloak balance` is run with and without `--json` against the same state
- **THEN** every number in the readable form SHALL appear in the JSON form, and the
  JSON form SHALL parse

### Requirement: The same state gives the same output

A command that reads state and does not change it SHALL be deterministic: run twice
against byte-identical state with no network, it SHALL print byte-identical output,
except for fields that are explicitly a clock reading and are labelled as such.

#### Scenario: Balance is stable
- **WHEN** `cloak balance --json` is run twice over an unchanged note store and pool
  view
- **THEN** the two outputs SHALL be byte-identical

### Requirement: The command surface is versioned

The program SHALL print its own version and the versions of the wallet file, note
store, pool view and journal formats it understands, under `cloak status`. A state
file written by a newer format version SHALL be refused naming both versions, never
read on a guess.

#### Scenario: State from a newer wallet
- **WHEN** a note store whose version byte is one higher than this build understands is
  opened
- **THEN** the program SHALL refuse naming the file, the version it found and the
  version it writes, and SHALL NOT modify the file

### Requirement: A command leaves whole state behind

When a command fails part way, the wallet's files SHALL be left either as they were
before the command or as they would be after it completed, never between. A command
that has already changed durable state and then fails SHALL say which step completed.

#### Scenario: Interrupted in the middle of a write
- **WHEN** a command is killed between writing a temporary state file and renaming it
  over the live one
- **THEN** the next command SHALL open the previous state and succeed
- **AND** SHALL NOT report the state as corrupt

### Requirement: Starting costs nothing a command does not need

A command that needs no chain SHALL NOT start the SPV side, and a command that needs
no pool SHALL NOT open the transport. `cloak --help` SHALL return in under 500 ms and
`cloak balance` on an unlocked wallet SHALL return in under 3 seconds cold, both
measured on the machine the suite records, and `cloak balance` SHALL make no network
call at all.

#### Scenario: Balance touches no network
- **WHEN** `cloak balance` is run with the transport and header source replaced by
  doubles that fail on any call
- **THEN** the command SHALL succeed, and neither double SHALL have been called
