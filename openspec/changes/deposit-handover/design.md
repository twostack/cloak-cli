## Context

- `runDeposit` (`lib/src/commands/deposit_commands.dart`) proves the deposit and has the transparent side build the covenant with `payTo`. That is a libspiffy deferred payment: signed, its coins held, not broadcast. It then records the covenant and the deposit (`status: 'recorded'`) and broadcasts through `TransparentSide.broadcast`, which sends libspiffy's `BroadcastDeferredPaymentCommand`. It returns, and `submitWaitingDeposits` submits `broadcast` deposits once `mined()` says so.
- libspiffy's deferred payments are meant for a recipient who broadcasts:
  - `CheckDeferredPaymentStatusCommand` asks ARC about the transaction, and on SEEN_ON_NETWORK or MINED marks its inputs spent. `mined()` already uses it.
  - `CancelDeferredPaymentCommand` releases the inputs, but refuses when the network knows the transaction.
- The coordinator from 0.1.8 on admits a deposit when ARC reports its covenant seen. Before 0.1.8 it refused an unmined covenant with `depositCovenant` and the sentence "the deposit covenant <txid> is not mined".

## Goals / Non-Goals

**Goals:**
- One command from `cloak deposit` to an answer.
- No coin released while the covenant might be on the network.
- Works against coordinators before and after 0.1.8.

**Non-Goals:**
- Waiting in the command for the round to be mined; `cloak sync` settles that as now.
- Changing libspiffy.

## Decisions

1. **Submit in place of broadcasting.** After the record is saved, `runDeposit` calls the same submission path `submitWaitingDeposits` uses, with the covenant attached, for this one deposit. Every outcome is recorded before the command returns.

2. **Accepted → `settle`.** A new `TransparentSide.settle(txid)` sends `CheckDeferredPaymentStatusCommand` and returns whether the network has the transaction. On acceptance the record is marked broadcast and `settle` is called. If it says the network does not have it yet (ARC's own record can trail the coordinator's broadcast by moments), the deposit is still accepted. The next `cloak sync` settles it: `mined()` sends the same command.

3. **Refused → `release`, which may refuse.** `release` returns whether libspiffy released the coins. When it did, the deposit is recorded `refused`, and the person is told nothing was spent. When libspiffy refused because the network knows the covenant, the deposit is recorded `broadcast` with its refund height.

4. **The older coordinator is recognised by its sentence.** A `depositCovenant` refusal containing "is not mined" means a coordinator from before 0.1.8. cloak then broadcasts the covenant itself, records `broadcast`, and says `cloak sync` submits it once mined, which is the old flow. Matching text is fragile, but it's temporary: it goes once no coordinator older than 0.1.8 runs. Decided with the user on 2026-09-26.

5. **Unanswered → `submitting`.** `unanswered` or `unsent` records `submitting`. `submitWaitingDeposits` takes `submitting` deposits, submitting them again with no mined check, as well as `broadcast` ones once mined. A `depositPending` refusal to a resubmission means the first submission is pending, so it is recorded `accepted`.

**Where the command acts before it can check.** The coordinator broadcasts on the wallet's behalf, and the wallet learns the result only from the reply.
- *The loss is bounded to time.* The covenant pays back to this wallet's key at the refund height, as today.
- *It lasts* until the round takes it (seconds, with 0.1.8), or until the refund height (`refundMargin` blocks, 144 by default).
- *It is recovered by* the refund when the network has the covenant, and by `release` when it does not. `release` is safe to call whatever the reply said, because libspiffy asks the network first.

**Bound set before measuring.** The deposit's reply is expected within the coordinator's 20 s bound, inside cloak's 30 s reply timeout. If the live measurement (task 5.1) shows replies over 30 s, deposits land in `submitting` and `cloak sync` finishes them. That is the same outcome as an unanswered one, so nothing is lost. The fix would then be the coordinator's bound, not cloak's timeout.

## Risks / Trade-offs

- **ARC's status trails the coordinator's broadcast.** → `settle` is advisory; `cloak sync` settles later.
- **Text matching for the fallback.** → Tested against a stub answering the old sentence; removal is a later task.
