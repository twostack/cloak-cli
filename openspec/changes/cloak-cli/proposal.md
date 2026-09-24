## Why

libcloak is finished and has never been used by a person. It is a headless library
with two ports and no way to run it: every flow it supports is exercised only by its
own suite, and the one end-to-end run against a real coordinator lives in a test file.
On the other side, libspiffy already receives BSV over BEEF, holds UTXOs, signs,
broadcasts and validates a header chain. Nothing joins them.

This change builds `cloak`, the binary that joins them, so that one person can receive
BSV from another, put it into the pool, pay someone out of it, prove the payment, and
take money back out. That is the first time the shielded pool is a thing somebody can
use rather than a thing that passes tests.

## What Changes

A new application package, `cloak_cli`, whose binary is `cloak`. Almost all of it is
wiring: the commands below are marked **wiring** when they only sequence calls a
library already makes, and **new** when behaviour is being written for the first time.

**The two ports libcloak asks a host for**

- `HeaderSource` over libspiffy's `BlockHeaderChain` — **wiring**. All three questions
  are answered by its existing public API (`bestHeight`/`chainTip`,
  `getHeightByHash`, `getHeaderByHeight` whose `BlockHeader.serialize()` is the 80
  bytes wanted). This needs one export line in libspiffy, named as a task there.
- `Transport` over ricochet — **wiring**, but moved: the working implementation is
  `libcloak/test/support/wallet_transport.dart`, which depends on `pool_coordinator`.
  A wallet must not depend on the server it talks to, so the wallet's half of the
  host-and-client setup is rebuilt here on `package:ricochet` directly.

**Commands**

- `init`, `unlock`, `address`, `status` — **wiring** of `WalletFile`, `WalletKeys`.
- `sync` — **wiring** of `CoordinatorClient.open`/`current`/`bringForward`/`follow`.
- `invoice new`, `invoice show` — **wiring** of `Invoice`.
- `pay`, `proof`, `check`, `ack` — **wiring** of `PaymentBuilder`, `CoordinatorClient.submit`,
  `PaymentProofs`, `PaymentChecker`, `Acknowledgement`.
- `balance`, `notes`, `journal` — **wiring** of `NoteStore`, `Balance`, `Journal`.
- `receive` — **wiring** of libspiffy's `ValidateBEEFCommand`/`ImportTransactionCommand`
  and its `PendingReceive`, which already parks a receive until its header arrives.
- `deposit` — **new**, and the substantial part. tstokenlib builds the covenant
  (`createDepositTxn`) and the coordinator already accepts a submission carrying one,
  but no wallet-side code exists that makes the transfer backing it: two dummy inputs,
  money in, the depositor's note as output 1. That builder belongs beside
  `PaymentBuilder`, so it is written in **libcloak** and named as a task there.
- `withdraw` — **new**, for the same reason: a real note in, `publicOut > 0` and a
  `PoolWithdrawal` naming the payee. Also a libcloak builder.
- `refund` — **wiring** of `createDepositRefundTxn`, for a deposit no round took in.

**BREAKING**: none. This is a new package; libcloak and libspiffy gain exports and
builders and lose nothing.

## Capabilities

### New Capabilities

- `command-shell`: the binary itself. What commands exist, how arguments are parsed,
  what is printed and on which stream, exit codes, how a `Refusal` reaches a person as
  the rule that failed rather than "invalid", and the rule that no command ever prints
  a seed, a spending key, a passphrase or an RPC password.
- `wallet-state`: the config file and the data directory. Creating and unlocking a
  wallet, the four state files libcloak defines, saving them so a crash leaves either
  the old state or the new one, and the lock that stops two `cloak` processes writing
  the same wallet.
- `chain-headers`: the `HeaderSource` over libspiffy. Starting and stopping the SPV
  side, what "not on the chain I accept" means to a command, how confirmations are
  counted, and the rule that this adapter exposes no method taking an address, an
  outpoint or a txid.
- `pool-transport`: the `Transport` over ricochet. The wallet's ricochet identity and
  where it is kept, frame bounds, reply routing by id, timeouts, and what a coordinator
  that has gone quiet looks like to a command.
- `pool-sync`: `cloak sync`. A first run with no state, which takes a head proof and a
  checkpoint and checks the second against the first; a later run, which folds block
  roots forward and checks once; catching up by the pool's published runs; and what
  happens when the pool contradicts itself.
- `payments`: issuing and reading invoices, building and submitting a payment, turning
  a mined round into a payment proof, checking one, acknowledging it, and reading the
  balance, the notes and the journal.
- `deposits`: receiving BSV over BEEF, putting it into the pool behind the covenant,
  learning the note's leaf from the round that took the receipt, refunding a deposit no
  round took, and withdrawing to a transparent address.

### Modified Capabilities

None in this repository. Two sibling repositories change, and the tasks say so:

- `../libcloak` gains a deposit-transfer builder and a withdrawal-transfer builder
  beside `PaymentBuilder`. Those are spec-level additions to libcloak's `payments`
  capability and will be proposed there.
- `../libspiffy` gains one export line for `BlockHeaderChain`. No requirement changes.

## Impact

**Numbers this change must keep inside.** libcloak measured these on an Apple M3 Pro at
test parameters and they are the floor the CLI cannot improve on; what this change adds
is the host's own tax on top, which is what its bounds are about:

| already measured, in libcloak | value |
|---|---|
| catching up 1,000 rounds holding 8 notes | 189 ms, bound 2 s |
| checking a standing payment proof | 64 ms |
| the payer's own work in building a payment | 8 ms, plus one spend proof |
| a whole payment end to end against a fake pool | 915 ms |
| state on disk | 1,069 B a note in the view, 73 B a note in the store, 142 B a journal entry |

| this change sets, and a task checks | bound |
|---|---|
| `cloak` with no command, or `--help` | under 500 ms, and starts neither the SPV side nor the transport |
| `cloak balance` cold, from an unlocked wallet | under 3 s, and makes no network call at all |
| the host's share of `cloak pay`, excluding the spend proof | under 100 ms over libcloak's 8 ms |
| `cloak sync` over a 1,000-round feed, against a ricochet on the same machine | under 30 s, of which the folding stays inside libcloak's 2 s |

The specs make requirements of the second table and of the "no network call" and "no
seed printed" claims; the first table is context and is not restated as requirements
here, because the components that own those numbers already require them.

**Depends on**: `../libcloak`, `../tstokenlib` (branch `feature/shielded-pool`),
`../libspiffy`, `../ricochet-dart-client`. `../pool-coordinator` is a dev dependency
only, for the end-to-end run. The whole graph resolves and imports together: 114
packages, verified in this repository.

**Runtime cost of depending on libspiffy**: Isar 3 over FFI, which downloads its native
library on first use, plus eventador, dactor, duraq and spiffynode. Acceptable for a
command-line program and stated here because it is the price of not writing SPV twice.

**Not in this change**: restoring a wallet from its seed, which is the one place the
no-scanning rule does not apply and needs its own thinking; and the coordinator's three
catch-up messages, which `../pool-coordinator` still owes. The wallet side of catch-up
is built and tested against a fake pool, so `cloak sync` works against a pool it has
followed from the start and is limited against a long-running one until the coordinator
answers.
