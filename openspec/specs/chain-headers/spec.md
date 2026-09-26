## Purpose

The source of block headers the wallet checks every payment proof against: a validated
header chain the program runs itself, exposed through the three questions libcloak
asks, and through nothing wider than those three.

## Requirements

### Requirement: Three questions and no more

The program SHALL supply libcloak's header source by answering exactly three
questions: where the accepted chain ends, the height of a given block hash or nothing
when it is not on that chain, and the 80-byte header at a given height or nothing.
The adapter SHALL expose no method taking an address, an outpoint, a transaction id or
any value derived from what the wallet holds.

#### Scenario: The adapter's surface is the port's surface
- **WHEN** the adapter type is inspected by a test
- **THEN** its public methods SHALL be exactly the three the port declares

#### Scenario: A hash off the accepted chain
- **WHEN** the height of a block hash the chain does not hold on its active branch is
  asked for
- **THEN** the adapter SHALL answer nothing
- **AND** SHALL NOT fetch it, ask a peer for it, or treat it as provisional

### Requirement: Headers are validated, not fetched on demand

The chain SHALL be built by accepting and validating headers, anchored to the
configured network's genesis. The program SHALL NOT satisfy a question by requesting
the specific block it was asked about, because a request naming a block a payer handed
this wallet would say which payment it is checking.

#### Scenario: Checking a proof makes no request naming its block
- **WHEN** a payment proof is checked against a chain already holding its block
- **THEN** no network request SHALL be made during the check
- **AND** a test recording every outbound request during the check SHALL find none

#### Scenario: A block the chain has not reached
- **WHEN** a payment proof names a block above the chain's tip
- **THEN** the check SHALL be refused naming the height asked for and the tip held
- **AND** the person SHALL be told to run `cloak sync` rather than shown a failure

### Requirement: Confirmations come from the chain the wallet accepts

The number of confirmations of a block SHALL be computed from the tip height and the
block's height on the accepted chain, both from this source. The program SHALL NOT
take a confirmation count from the pool, from a proof, or from any other party.

#### Scenario: A proof claiming its own depth
- **WHEN** a payment proof is checked whose sender claims more confirmations than the
  chain gives
- **THEN** the number reported SHALL be the one computed here

### Requirement: The header store survives a restart and refuses a foreign chain

Headers SHALL be kept in the wallet's data directory and reused on the next run. A
header store anchored to a different network's genesis than the configured one SHALL
be refused naming both, and SHALL NOT be silently cleared.

#### Scenario: Switching networks in the config
- **WHEN** the config names a different network than the one the stored headers were
  built under, and any command needing the chain is run
- **THEN** the command SHALL refuse naming the network configured and the network
  found
- **AND** the stored headers SHALL be unchanged

### Requirement: Untrusted headers cannot make the program allocate

A header offered by a peer SHALL be bounded and validated before it is stored. A run
of headers that does not connect to the chain SHALL be dropped, and SHALL NOT grow
unbounded storage of headers off the accepted chain.

#### Scenario: A flood of unconnected headers
- **WHEN** ten thousand well-formed headers that connect to nothing the chain holds are
  offered
- **THEN** the number retained off the accepted chain SHALL stay inside the bound the
  chain declares, and the process SHALL NOT exhaust memory

### Requirement: The same headers give the same answers

Given the same stored headers, the three questions SHALL return the same values on
every run and in every process. No answer SHALL depend on the order commands were run
in or on a cache built during the process.

#### Scenario: Two processes agree
- **WHEN** two processes open the same header store and ask for the tip, the height of
  a known hash and the header at a known height
- **THEN** all three answers SHALL be identical

### Requirement: Nothing in the header records is secret, and that is the point

The header records hold only public data and SHALL be treated as such: they MAY be
shared, copied between wallets, or seeded from a bulk source. No header record SHALL
hold anything derived from the wallet's keys, notes or payments.

libspiffy keeps its header records in the same database as the transparent wallet's
coins and transactions. That database is therefore not public, and `cloak status`
SHALL say what it holds, so a person does not share it believing it is only headers.

#### Scenario: The header store names no wallet
- **WHEN** the header records of a wallet that has made and received payments are read
  and searched for the wallet's note commitments, addresses and transaction ids
- **THEN** none SHALL be found

#### Scenario: status says what the chain database holds
- **WHEN** `cloak status` is run
- **THEN** it SHALL describe the chain database as holding public block headers and the
  transparent wallet's coins and transactions

### Requirement: The chain is ready inside its bound

Opening a wallet with a header store already at the chain tip SHALL make the source
ready to answer in under 2 seconds, measured on the machine the suite records. A
command needing the chain SHALL report progress while the chain is catching up rather
than appearing to hang.

#### Scenario: A warm chain opens inside the bound
- **WHEN** the header chain is opened over a store already holding the localnet
  harness's chain
- **THEN** the first of the three questions SHALL be answerable in under 2 seconds

### Requirement: A chain that cannot be reached is a named failure

When the header source cannot answer because the chain is unreachable or not yet
synced, the command SHALL refuse carrying the source's own reason, and SHALL NOT fall
back to any other party for the answer.

#### Scenario: The SPV side is down
- **WHEN** a command needing the chain runs with no peers reachable and a store below
  the height the command needs
- **THEN** it SHALL refuse naming the call and the source's reason
- **AND** SHALL NOT ask the pool coordinator, or any third party, for the header
