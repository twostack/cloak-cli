## Purpose

The commands that make a payment happen between two people: issuing and reading an
invoice, paying it, producing the proof that it was paid, checking that proof,
acknowledging it, and reading back what the wallet holds and what it did.

## Requirements

### Requirement: A payee issues an invoice naming a fresh address

`cloak invoice new` SHALL produce an invoice naming the pool, an amount, an expiry, an
optional memo and a freshly derived address of the payee's, signed under a key the
invoice carries the public half of. Every invoice SHALL name a different address.

#### Scenario: Two invoices, two addresses
- **WHEN** `cloak invoice new` is run twice
- **THEN** the two invoices SHALL name different addresses

#### Scenario: A memo too large
- **WHEN** a memo longer than an invoice permits is given
- **THEN** the command SHALL refuse naming the limit in bytes and the size given,
  counted in bytes and not in characters

### Requirement: A payer checks an invoice before spending anything

`cloak invoice show` and `cloak pay` SHALL check an invoice's pool, its expiry and its
signature before any note is chosen and before any proof is computed. A refusal at any
of these SHALL cost no proving work.

#### Scenario: An expired invoice costs nothing
- **WHEN** `cloak pay` is given an invoice whose expiry has passed
- **THEN** it SHALL refuse naming the expiry, exit 1, and SHALL NOT have computed a
  spend proof

#### Scenario: An invoice for another pool
- **WHEN** an invoice naming a different pool is given
- **THEN** the command SHALL refuse naming the pool the invoice carries and the pool
  the wallet follows

### Requirement: Paying reserves the note before the frame leaves

`cloak pay` SHALL reserve the note it spends before the submission is sent, and SHALL
release it only where the answer establishes the transfer is not in a round. An
accepted submission SHALL leave the note reserved; a refused, expired or unsent one
SHALL release it; one that was not answered SHALL leave it reserved.

#### Scenario: The four answers move the note four ways
- **WHEN** a submission is accepted, refused, expired, and left unanswered in turn
- **THEN** the note SHALL be reserved, released, released, and reserved respectively

#### Scenario: A second payment cannot pick the same note
- **WHEN** a payment is built against a note already reserved
- **THEN** the command SHALL refuse naming the leaf and the note's state
- **AND** SHALL NOT compute a spend proof

### Requirement: A resend is the same submission

Where `cloak pay` retries a send, it SHALL send the same bytes under the same
submission id, so a coordinator that took the first copy recognises the second as the
same submission rather than as a second spend.

#### Scenario: Retried sends carry one id
- **WHEN** the transport fails on the first two attempts and succeeds on the third
- **THEN** all three frames SHALL be byte-identical

### Requirement: The payer turns a mined round into a proof

`cloak proof` SHALL produce the payment proof for an invoice this wallet paid, finding
the leaf by looking for the wallet's own commitment in the round the coordinator built
and mined. It SHALL produce the standing form, which carries everything a payee needs,
and SHALL also produce the short form on request for a payee that follows the pool.

#### Scenario: The leaf comes from the round
- **WHEN** a round holding this wallet's payment has been mined
- **THEN** `cloak proof` SHALL find the commitment in that round and report the leaf it
  landed at

#### Scenario: The round does not hold it
- **WHEN** the round named does not carry the payer's commitment
- **THEN** the command SHALL refuse naming the round and the commitment, and SHALL NOT
  emit a proof

### Requirement: The payee checks a proof against its own headers

`cloak check` SHALL verify a payment proof against block headers from the wallet's own
source and the pool identity the wallet holds, and SHALL take the note on only where
the proof verified. There SHALL be no command or flag that adds a note to the store
from an unverified proof.

#### Scenario: A round with a forged lineage
- **WHEN** `cloak check` is given a proof whose round transaction carries a
  lookalike PP1, as the localnet forgery in the suite produces
- **THEN** the check SHALL refuse at the step naming the pool's script
- **AND** no note SHALL be added to the store

#### Scenario: A proof shorter than it claims
- **WHEN** a proof file is truncated at each of a hundred offsets and checked
- **THEN** every check SHALL return a named refusal, and none SHALL throw

### Requirement: The payee acknowledges only what it checked and only in time

`cloak ack` SHALL sign an acknowledgement for a payment this wallet checked, under the
key the invoice was issued from, and SHALL refuse to sign one for an invoice that had
already expired when the round holding the payment was mined, naming both times.

#### Scenario: A payment that arrived late
- **WHEN** the round holding the payment was mined after the invoice expired
- **THEN** `cloak ack` SHALL refuse naming the expiry and the time the round was mined
- **AND** the note SHALL still be held, because refusing to sign is not refusing the
  money

### Requirement: The payer checks an acknowledgement against the invoice alone

`cloak ack --check` SHALL verify an acknowledgement against the invoice it names and
nothing else, distinguishing an acknowledgement for a different invoice from one whose
signature does not verify.

#### Scenario: An acknowledgement for the wrong invoice
- **WHEN** an acknowledgement naming another invoice is checked
- **THEN** the refusal SHALL name both invoice ids

#### Scenario: A forged acknowledgement
- **WHEN** the signature bytes are altered
- **THEN** the refusal SHALL say it does not verify under the key the invoice carries

### Requirement: Every step of a payment is recorded

Each of issuing an invoice, paying one, submitting, receiving an outcome, producing a
proof, checking a proof and acknowledging SHALL append a journal entry. A person SHALL
be able to read the whole thread for one invoice with `cloak journal`.

#### Scenario: A thread for one invoice
- **WHEN** an invoice is issued, paid, proved and acknowledged
- **THEN** `cloak journal --invoice <id>` SHALL show those entries in order

#### Scenario: An edited journal is refused, not repaired
- **WHEN** one journal entry file is altered so it does not parse
- **THEN** `cloak journal` SHALL report that entry as refused, naming the file, and
  SHALL still show the rest
- **AND** SHALL NOT rewrite or delete the file

### Requirement: No nullifier is ever written down

The wallet SHALL compute a nullifier to recognise its own spend and discard it. No
file this program writes SHALL hold a nullifier.

#### Scenario: The wallet directory holds no nullifiers
- **WHEN** a wallet that has spent several notes has its whole directory searched for
  the nullifiers of those notes
- **THEN** none SHALL be found

### Requirement: Payment commands reveal nothing beyond the payment

No payment command SHALL make a request naming an address, an outpoint or a
transaction id derived from what the wallet holds. Everything a payee needs SHALL
arrive from the payer over the channel they already have.

#### Scenario: Checking a payment makes no request
- **WHEN** `cloak check` runs against a chain already holding the proof's block
- **THEN** no network request SHALL be made

### Requirement: Messages are versioned and an unknown version is refused

Every message this capability reads carries a format version. A version this build
does not read SHALL be refused naming both versions rather than parsed on a guess.

#### Scenario: An invoice from a later version
- **WHEN** an invoice whose version byte is one higher is read
- **THEN** the refusal SHALL name the version written and the version read

### Requirement: The same inputs give the same message bytes

Given the same inputs and the same randomness, the encoding of an invoice, a payment
proof and an acknowledgement SHALL be byte-identical between runs, so two parties can
compare bytes rather than compare interpretations.

#### Scenario: Two encodings agree
- **WHEN** an acknowledgement is encoded, decoded and encoded again
- **THEN** the two encodings SHALL be byte-identical

### Requirement: Payment commands stay inside their bounds

The program's own share of `cloak pay`, excluding the spend proof, SHALL be under 100
ms above libcloak's measured 8 ms of wallet work. `cloak check` on a standing proof
SHALL complete in under 1 second above libcloak's measured 64 ms of proof checking.
Both are measured on the machine the suite records as best-of-N.

#### Scenario: The host's share of a payment
- **WHEN** `cloak pay` is run against the fake pool and its phases are timed
- **THEN** the time outside the spend proof SHALL be under 108 ms
