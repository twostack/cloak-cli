## Context

See proposal.md for motivation. What shapes the approach is that almost nothing here
is new logic: libcloak owns the shielded side and libspiffy owns the transparent side,
and both already work. The design problem is the seams, and there are exactly five:
where the header chain comes from, where the transport comes from, who owns the two
transfer builders that do not exist yet, how one process holds state that two
libraries both want to persist, and what a person is told when a command cannot check
the answer it was given before acting on it.

Three facts were established in this repository before this design was written, and
the approach rests on them:

- The dependency graph resolves and imports: libcloak, tstokenlib, libspiffy and
  ricochet in one `dart pub get`, 114 packages, all four libraries importable in one
  file.
- libspiffy's `BlockHeaderChain` answers all three of libcloak's header questions with
  its existing public API, and is reachable from the actor system. Only its export is
  missing.
- A deposit needs the live pool's PP3 outpoint, which is an announced round's
  transaction id with the PP3 output index. It comes off a message the wallet already
  reads, so a deposit costs no lookup.

## Goals / Non-Goals

**Goals:**

- One process, one wallet directory, no daemon. Every command starts, does one unit of
  work, writes state whole, and exits.
- The two ports stay exactly as narrow as libcloak declares them. Widening a port to
  make a command easier is the one change this design will not make.
- Every rule that belongs to a library is raised in that library. The CLI holds
  sequencing, argument parsing, printing and files, and no cryptography or protocol.
- A person can tell, from what a command prints, which rule refused them.

**Non-Goals:**

- Restoring from a seed. It is the only place the no-scanning rule does not apply, and
  deciding how it works is its own piece of thinking.
- Any interactive or long-running mode: no watch, no shell, no TUI.
- Making deposits or withdrawals private. They are public by construction; the design
  makes sure the person knows it.
- Mainnet, and production parameters end to end. ARC caps a scriptSig at 1,636,802
  bytes and a production witness is larger, so runs are at test parameters.

## Decisions

### The header chain is libspiffy's, reached through its actor system

**Decision.** Start `LibSpiffyActorSystem`, take its `headerChain`, and wrap it in a
thirty-line adapter implementing libcloak's `HeaderSource`. Ask libspiffy for one
export line so the type can be named.

**Why, and what was rejected.** Three alternatives were weighed. Extracting libspiffy's
SPV core into a shared package is the clean layering, but it is a change in somebody
else's repository, it buys nothing this CLI needs, and it is only worth doing when
something wants SPV without libspiffy. Writing a header chain here would be
reimplementing 2,324 lines of validated, reorg-handling code for no gain. Trusting a
third party for headers would break the rule the whole wallet is built on. Wrapping
what exists costs one export line.

**The cost, stated.** The CLI takes on Isar over FFI, which downloads its native
library on first use, plus eventador, dactor, duraq and spiffynode. That is the price
of not writing SPV twice, and it is paid at process start, which is why
`cloak --help` and `cloak balance` are specified not to start it.

### The transport is rebuilt here on the ricochet client, not lifted from the coordinator

**Decision.** Write the wallet's half of the ricochet setup in this package against
`package:ricochet` directly: build the libp2p host, connect to the configured server,
submit to the coordinator's folder, read this identity's replies, read the
coordinator's feed by sequence.

**Why, and what was rejected.** A working implementation exists in
`libcloak/test/support/wallet_transport.dart`, but it is written against the
coordinator's own `RicochetTransport`, which serves both sides and drags the server
package in. A wallet that depends on the server it talks to is a wallet that cannot be
written by anyone but the server's author. Moving the shared host-building code into a
fourth package was considered and rejected as premature: there are two callers, the
wallet's half is small, and a shared package would need its own repository, its own
versioning and its own specs before it had earned any of them. If a third caller
appears, that is the moment.

**What is kept from the existing implementation.** Two hard-won details. Replies are
buffered, because the reply folder marks what it hands over as delivered and a reply
not kept is a reply nobody sees again. And feed sequence numbers start at one on the
ricochet side while libcloak asks from zero before it has read anything.

### The two missing transfer builders go in libcloak, not here

**Decision.** `DepositBuilder` and `WithdrawalBuilder` are written in libcloak beside
`PaymentBuilder`, proposed there as additions to its `payments` capability. This
change's task list names them as sibling-repository work.

**Why.** They are the same kind of thing `PaymentBuilder` is: choose inputs, make
outputs, seal a bundle, prove a STARK, check the transfer's own shape. Putting them in
the CLI would mean a second host could not deposit without copying them, and would put
spend-circuit knowledge in a package whose job is argument parsing. The rule this
repository is configured under is that a rule belonging to a library is raised there.

**What this costs.** Two repositories move in one change, which OpenSpec handles by
naming the foreign tasks rather than by pretending they are local. The alternative,
building them here and moving them later, trades a small amount of coordination now
for a migration and a duplicated API later.

### One process owns all state, and takes a lock to prove it

**Decision.** A lock file in the wallet directory, taken exclusively by any command
that writes, released on exit. Read-only commands take nothing.

**Why.** libcloak's note store is the thing that stops a note being spent twice, and it
enforces that within one process by object identity: a payment built against a note is
refused unless the store handed out that exact note. Two processes defeat that
completely, and the failure is the worst kind, because the coordinator would refuse the
second transfer at the nullifier and the wallet would have computed an expensive proof
for nothing while believing both notes were fine.

**Alternative rejected.** Letting libcloak's own file formats arbitrate, on the theory
that the last writer wins. It does not work: two processes each read the store, each
reserve a different note, and each write back a file that has forgotten the other's
reservation.

### A deposit is the one place the wallet must act before it can check

**Decision.** Build the covenant against a round the wallet has both folded and
checked, choose a refund height far enough ahead for the next round, tell the person
the amount, the round, the refund height and what it means, and require confirmation
before broadcasting.

**Where the trust sits, and what the loss is bounded to.** Everywhere else, an answer
from the pool is checked against something the wallet proved off the chain, so a lying
coordinator is refused rather than followed. A deposit cannot work that way: the wallet
has to spend a transparent coin into a covenant naming a round's PP3 before it can
know whether any round will take it in. If the coordinator lies about which round is
live, or simply never builds the round, the covenant is unspendable by the pool and
the deposit sits.

**The loss is bounded to time, and to nothing else.** The covenant's refund clause
pays the money back to a key the depositor holds, at a block height the depositor
chose. So the exposure is: the deposited amount, illiquid, from broadcast until the
refund height, recovered in full by `cloak refund`. Nothing can take the money. The
design's job is to make sure the person chose that height knowingly, which is why the
confirmation is not a formality and why the refund height is printed before the
broadcast rather than after it.

**The tension in choosing the height.** Too close and a coordinator skips the deposit,
because a refund mined before its round would invalidate the round. Too far and the
money is illiquid for longer if the deposit is never taken. The default is derived
from the pool's round cadence with margin, it is printed, and it is overridable.

### The header store and the transparent wallet share libspiffy's database (2026-09-24)

**Decision.** libspiffy's actor system keeps its header chain, its event store and the
transparent wallet's coins and transactions in one Isar database, and cloak uses it as
built, in the wallet directory. The rule that the header store names no wallet applies
to the header records; the database as a whole is private and `cloak status` says so.

**Why, and what was rejected.** Keeping headers in a database of their own would mean a
second actor system fed headers from the first, or a change in libspiffy to split its
stores. Both cost more than the property is worth here: what makes headers shareable is
that the header records carry nothing of the wallet, and that still holds.

### A deposit is two commands, because its covenant must be mined first (2026-09-24)

**Decision.** `cloak deposit` builds, records and broadcasts the covenant and returns.
The deposit's transfer is submitted by a later `cloak sync`, or `cloak deposit --submit`,
once the wallet's own chain holds the covenant mined.

**Why.** The coordinator refuses a deposit until its covenant is mined and unspent, and
on testnet that is ten minutes or more. A command that waited that long would be the
daemon this design does not have.

### State is written whole by temp-then-rename, and recorded before it is broadcast

**Decision.** Every state file is written to a temporary name beside it and renamed
over the live one. A deposit or withdrawal transaction is recorded durably *before* it
is broadcast, never after.

**Why the ordering.** The two failures are not symmetrical. Recording a broadcast that
did not happen costs a re-broadcast of bytes already built, and `cloak status` shows
it. Broadcasting without a record means a funding outpoint is spent by a transaction
the wallet has forgotten, and the next run builds a second deposit against the same
outpoint, which the chain rejects and the person cannot explain. So the cheap failure
is chosen deliberately.

### The two key trees never meet

**Decision.** Transparent keys come from libspiffy's own derivation; pool keys come
from libcloak's. Neither is derived from the other, and the ricochet identity is
derived from neither.

**Why.** Deriving them from one seed is convenient and would mean a person who learned
a transparent address could test candidate pool addresses against it. The cost of
keeping them separate is that a wallet has more than one thing to back up, which is a
documentation problem rather than a security one.

### Every bound in the specs is a bound set before measuring

None of this program's own costs have been measured; only the libraries under it have.
So each bound in the specs is a target with a verification task, and the rule for
missing one is the same in every case: **measure, record the number in the design
record with the machine it was taken on, and then either fix it or move the bound with
the reason.** A bound is never quietly deleted.

Concretely, and these are the ones most likely to be missed:

- **`cloak --help` under 500 ms.** If missed, the cause is almost certainly work at
  import time; the fix is to make the SPV and transport construction lazy. If it is
  still missed after that, it is the Dart VM's own start cost, the bound moves, and the
  number is recorded.
- **`cloak balance` under 3 s cold.** If missed, the cause is Isar's first-use native
  library download or its open cost. The fix is to not open Isar for commands that
  need no chain, which is a design change, not a bound change.
- **`cloak sync` over 1,000 rounds under 30 s.** The folding share is libcloak's, which
  measured 189 ms against a 2 s bound. If the whole command misses 30 s, the transport
  is the cause and the fix is batching feed reads; the bound moves only if a measured
  batch size cannot reach it.
- **The host's share of `cloak pay` under 100 ms above libcloak's 8 ms.** If missed,
  something in the CLI is doing per-note work it should not; the fix is in the CLI.

### Measurements go in a running design record, appended and dated

This repository keeps `docs/DESIGN.md` as a record appended in dated sections, as its
siblings do: what was built, what was measured, on which machine, and what was decided
against. It is not rewritten.

## Risks / Trade-offs

- **A person deposits into a pool whose coordinator then disappears.** → The money is
  recoverable in full at the refund height, by `cloak refund`, with no cooperation from
  anyone. The design's obligation is to make sure the person knew the height before
  they broadcast, which is the confirmation step.

- **The coordinator does not implement the three catch-up messages yet.** → A wallet
  that has followed the pool from the start works today, because it folds the feed. A
  wallet joining a long-running pool cannot catch up until `../pool-coordinator` answers
  those messages. `cloak sync` reports that plainly rather than appearing to hang or
  silently reading an enormous feed.

- **Isar's native library downloads on first use.** → A first run on a machine with no
  network for that download fails in a way that has nothing to do with the wallet. The
  mitigation is to make that failure legible: name what was being downloaded and why,
  and do not start it for commands that need no chain.

- **Two repositories move in one change.** → The foreign tasks are named with their
  repository and cannot be silently absorbed. If libcloak's builders are not accepted
  as proposed, the CLI's deposit and withdraw commands block while everything else
  lands, which is visible in the task list rather than discovered late.

- **The suite's performance bounds are bounds on one core.** → libcloak learned this
  the expensive way: three bounds passed alone and failed in a parallel pack. Every
  bound here is specified as best-of-N, and the end-to-end run against a real
  coordinator is asked for separately rather than swept into the default suite.

- **A person backs up the seed and loses the note store.** → Until restore-from-seed
  exists, that is lost money. The design's only honest mitigation is to say so: the
  note store is called out in `cloak status`, and the documentation says which files
  must be backed up and that the seed alone is not enough yet.

## Migration Plan

Nothing to migrate: this is a new package with no users and no stored state in the
world. The two sibling changes land first because the CLI's deposit and withdraw
commands do not compile without libcloak's builders; everything else can be built
against what exists today.

## Open Questions

- **Where the ricochet identity should be stored once a person has more than one
  wallet.** Today it is one file per wallet directory, which is correct and possibly
  wasteful. Deciding otherwise changes no spec and no task.
- **Whether `cloak` should offer to run the refund automatically at the refund
  height.** It would need something that runs at a time, which this design has none
  of. It changes no spec here, and it is the kind of thing a person may prefer to do
  themselves.
