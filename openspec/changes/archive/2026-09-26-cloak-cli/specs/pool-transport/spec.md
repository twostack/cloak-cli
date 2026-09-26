## Purpose

The pipe to the pool's coordinator: how the wallet reaches it, under what identity,
what it will accept back, and what a coordinator that lies, floods or goes quiet looks
like to the command that is waiting.

## ADDED Requirements

### Requirement: Send a frame, read the feed

The program SHALL supply libcloak's transport by answering exactly two calls: send a
frame and wait for its reply within a deadline, and read the pool's feed from a
sequence number. The transport SHALL treat every frame as opaque bytes and SHALL NOT
decode, inspect or route on the contents of one.

#### Scenario: The transport does not read messages
- **WHEN** a frame that is not a valid pool message is sent through the transport
- **THEN** the transport SHALL deliver it and return whatever comes back
- **AND** the refusal SHALL come from the client above it, naming the message field

### Requirement: The wallet does not depend on the coordinator's code

The transport SHALL be built on the ricochet client alone. No package this program
depends on at runtime SHALL be the coordinator server's package.

#### Scenario: The runtime dependency graph
- **WHEN** the package's runtime dependencies are listed
- **THEN** the coordinator's package SHALL appear only among development dependencies

### Requirement: A reply is matched to its own submission

Replies SHALL be routed by the submission id they carry. A reply that arrives while
another call is waiting SHALL be held for the call whose id it names, and SHALL NOT be
handed to whichever call happened to be waiting. A reply naming no submission in
flight SHALL be discarded.

#### Scenario: Two submissions whose replies cross
- **WHEN** two submissions are in flight and their replies arrive in the opposite
  order
- **THEN** each call SHALL return the reply naming its own id

#### Scenario: A reply for a submission never sent
- **WHEN** a reply arrives naming an id this wallet has not used
- **THEN** it SHALL be discarded and no call SHALL return because of it

### Requirement: Every frame is bounded before it is read

A frame read from the transport SHALL have its length checked against the maximum the
pool protocol declares for a message of that kind before its bytes are read into
memory. An over-long frame SHALL be discarded naming the size declared and the maximum.

#### Scenario: A coordinator that declares an enormous reply
- **WHEN** a frame declaring a length above the protocol's maximum arrives
- **THEN** it SHALL be discarded naming both sizes
- **AND** the wallet SHALL NOT allocate the declared size

#### Scenario: Mutated frames never crash the wallet
- **WHEN** ten thousand frames, each a valid reply with one byte mutated or truncated,
  are delivered
- **THEN** every one SHALL produce a named refusal or be discarded, and none SHALL
  throw out of the transport

### Requirement: A deadline the transport does not honour is not the wallet's problem

The transport SHALL stop waiting at the deadline it is given. Independently, the
program SHALL NOT let a call block past twice that deadline even if the transport
never returns, because a transport is somebody else's code.

#### Scenario: A transport that never returns
- **WHEN** a transport that ignores its deadline and never completes is used for a
  submission
- **THEN** the command SHALL return within twice the configured timeout
- **AND** the outcome SHALL be the one meaning no answer arrived, not a refusal

### Requirement: The wallet's identity is its own and is not the wallet's keys

The wallet's identity on the transport SHALL be a key generated for that purpose and
kept in the wallet directory. It SHALL NOT be derived from the wallet seed, the
spending key, any viewing key or any note. Losing it SHALL cost a person nothing but
the ability to read replies already sent to it.

#### Scenario: The identity is unrelated to the wallet
- **WHEN** a wallet is created twice from the same seed with different transport
  identities, and once from two different seeds with the same identity
- **THEN** neither the identity nor the seed SHALL be computable from the other

### Requirement: What the wallet sends names nothing it holds

No frame the transport sends SHALL contain an address, an outpoint, a transaction id
derived from what the wallet holds, or a request whose shape depends on what the
wallet holds. A catch-up request SHALL name only one of the pool's published aligned
runs.

#### Scenario: A catch-up request says nothing about the asker
- **WHEN** two wallets at very different rounds each catch up
- **THEN** the ranges they ask for SHALL both be aligned runs of the size the pool's
  descriptor publishes
- **AND** a recorded transcript SHALL not distinguish which wallet was further behind
  by the range asked for

### Requirement: The transport is versioned by the protocol it carries

The transport SHALL carry the pool protocol's own versioned bytes and add no framing
version of its own beyond what the underlying network requires. A message of an
unknown protocol version SHALL be refused by the client above, naming both versions.

#### Scenario: A coordinator speaking a later protocol
- **WHEN** a reply of an unrecognised protocol version arrives
- **THEN** the command SHALL refuse naming the version written and the version read

### Requirement: A quiet coordinator is a distinct outcome

When no reply arrives before the deadline, the command SHALL report that no answer
arrived, which is not a refusal, and SHALL leave any note the submission spent
reserved. The person SHALL be told the transfer may still be in a round and what to
run next.

#### Scenario: The coordinator goes quiet after taking a submission
- **WHEN** a submission is sent and no reply arrives
- **THEN** `cloak pay` SHALL report that no answer arrived, exit 1, and leave the note
  reserved
- **AND** the journal SHALL carry an entry saying so

### Requirement: The transport stays inside its bound

Reading a hundred feed entries from a ricochet server on the same machine SHALL take
under 5 seconds, measured on the machine the suite records, as a best-of-N measurement.

#### Scenario: A hundred entries inside the bound
- **WHEN** a hundred feed entries are read from the ricochet server the suite starts
- **THEN** the elapsed time SHALL be under 5 seconds
