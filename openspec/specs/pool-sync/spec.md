## Purpose

`cloak sync`: bringing the wallet's view of the pool up to the pool's tip, and
checking the arithmetic against a round the wallet proved off the chain itself, so
that the coordinator is a convenient server and never an authority.

## Requirements

### Requirement: A first sync stands the wallet up on evidence

With no stored pool view, `cloak sync` SHALL take the pool's head proof, check it
against block headers from the wallet's own source, then take the pool's frontier and
accept it only because it computes the commitment root that head proof carried. A
frontier that computes any other root SHALL be refused naming the check.

#### Scenario: A pool that offers someone else's tree
- **WHEN** the coordinator answers with a frontier belonging to a different tree than
  the head proof it just gave
- **THEN** `cloak sync` SHALL refuse naming the checkpoint check
- **AND** no pool view file SHALL be written

#### Scenario: The round number comes from the chain, not the claim
- **WHEN** the coordinator's head reply claims a round number higher than the pool
  header's leaf count implies
- **THEN** the round used SHALL be the one the header's leaf count gives

### Requirement: A later sync folds forward and checks once

With a stored pool view, `cloak sync` SHALL fold one block root per round from the
pool's feed, in order and skipping none, and SHALL then check the folded result
against the commitment root of a round it proved off the chain. The view SHALL NOT
report itself checked on the strength of anything the pool said.

#### Scenario: The view refuses to spend while unchecked
- **WHEN** rounds have been folded and the check has not been run
- **THEN** `cloak pay` SHALL refuse naming the round folded to and the round checked to
- **AND** SHALL NOT compute a spend proof

#### Scenario: A wrong block root is caught at the end of the run
- **WHEN** one block root in a run of rounds is altered and the whole run is folded
- **THEN** the single check at the end of the run SHALL fail, naming the check
- **AND** the stored pool view SHALL be left at the round it was checked to before

### Requirement: An announcement's two claims are checked against each other

Before anything is folded, `cloak sync` SHALL check that an announcement's block root
folds to the commitment root the same announcement's pool header carries, on a
detached probe. A contradiction SHALL stop the sync with nothing folded.

#### Scenario: A self-contradicting announcement
- **WHEN** an announcement carries a block root that cannot fold to its own header's
  commitment root
- **THEN** the sync SHALL stop naming the round and the contradiction
- **AND** the stored pool view SHALL be unchanged

### Requirement: The pool telling two stories is reported

`cloak sync` SHALL remember what the pool said about recent rounds and SHALL report a
round the pool later describes differently, naming the round and what differs.

#### Scenario: A round announced twice with different roots
- **WHEN** the feed carries two announcements for one round with different block roots
- **THEN** the sync SHALL stop naming the round and both values

### Requirement: Catching up asks for a published run, not for what the wallet lacks

When the wallet is too far behind to fold from the feed, `cloak sync` SHALL ask for
the pool's published aligned run of rounds containing the round it needs. It SHALL NOT
ask for "everything since round N", because over a few catch-ups that names the wallet.

#### Scenario: Two wallets at different rounds ask the same question
- **WHEN** a wallet at round 5 and a wallet at round 900 each catch up within the same
  published run
- **THEN** both SHALL send the same range

#### Scenario: A pool that does not serve catch-up
- **WHEN** the coordinator refuses the catch-up request because it does not implement
  it
- **THEN** `cloak sync` SHALL report that the pool does not serve catch-up, name the
  round the wallet stands at, and exit 1
- **AND** SHALL NOT fall back to reading the whole feed silently

### Requirement: A note's path comes forward only by folding every round

Bringing a wallet that holds notes up to date SHALL fold every round since each note
was minted. A frontier or a checkpoint SHALL NOT be used to advance a note's path,
because it says where the tree stands and nothing about the rounds that note's
siblings missed.

#### Scenario: A held note after a catch-up
- **WHEN** a wallet holding a note catches up over many rounds and then pays
- **THEN** the spend path offered SHALL reach the commitment root the view holds
- **AND** the payment SHALL be built without refusal at the anchor step

### Requirement: Syncing says nothing about the wallet

Everything `cloak sync` reads SHALL be the same bytes every follower of the pool
reads. No request it makes SHALL name a note, an address, a position or a round
derived from what this wallet holds, beyond the published run described above.

#### Scenario: Two wallets holding different notes sync identically
- **WHEN** a wallet holding no notes and a wallet holding eight notes each sync from
  the same round to the same tip
- **THEN** the frames they send SHALL be indistinguishable apart from their identities
  and timing

### Requirement: The pool's shape is checked, not discovered

`cloak sync` SHALL check that the pool's descriptor still declares the shape the
stored state was built under, and SHALL refuse naming both shapes when it does not,
rather than discovering the difference at the round where a path stops reaching the
root.

#### Scenario: A descriptor with a different block size
- **WHEN** the descriptor's leaves-per-round differs from the note store's
- **THEN** the sync SHALL refuse naming both values, and no state SHALL be written

### Requirement: A sync is resumable and idempotent

`cloak sync` interrupted at any point SHALL leave the pool view either where it was or
at a round it has fully folded and checked. Running it again SHALL continue from there,
and running it when already at the tip SHALL change nothing and report so.

#### Scenario: Interrupted and resumed
- **WHEN** a sync over many rounds is killed part way and rerun
- **THEN** the second run SHALL reach the same final view as an uninterrupted run,
  byte for byte

#### Scenario: Already current
- **WHEN** `cloak sync` is run twice with no new rounds between
- **THEN** the second run SHALL report no rounds folded and SHALL NOT rewrite the pool
  view file

### Requirement: Syncing stays inside its bound

`cloak sync` over a feed of 1,000 rounds against a ricochet server on the same machine
SHALL complete in under 30 seconds, of which the folding itself SHALL stay inside the
2-second bound libcloak requires, both measured on the machine the suite records as a
best-of-N measurement.

#### Scenario: A thousand rounds inside the bound
- **WHEN** a wallet holding eight notes syncs over 1,000 announced rounds
- **THEN** the whole command SHALL take under 30 seconds
- **AND** the time spent folding SHALL be reported separately and SHALL be under 2
  seconds
