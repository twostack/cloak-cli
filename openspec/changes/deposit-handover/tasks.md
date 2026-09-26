## 1. The transparent side

- [x] 1.1 Add `settle(txid)` to `TransparentSide` (libspiffy `CheckDeferredPaymentStatusCommand`; true when the network has the transaction), and make `release` return whether the coins were released. Update the fakes the tests use. Verify in the transparent-side tests that `release` of a transaction the fake network knows returns false and keeps the coins held, and that one it does not know returns true and frees them.

## 2. One-command deposit

- [x] 2.1 In `runDeposit`, submit in place of broadcasting (design 1–4), recording every outcome before returning. Verify "One command against a coordinator that broadcasts" with the in-process coordinator stub (`test/support/coordinator_end.dart`): accepted, and the transparent side's broadcast never called.
- [x] 2.2 Verify "A coordinator that wants the covenant mined": a stub answering `depositCovenant` "…is not mined" makes the command broadcast the covenant and record `broadcast`. A later `cloak sync` with the covenant mined submits it. Mutation test: drop the fallback and confirm the test fails.
- [x] 2.3 Verify "Refused and never broadcast" and "Refused after the network saw it" with a stub that refuses by `receiptSlots`, the fake network not knowing and knowing the covenant: the coins are back in `cloak balance` in the first case, and the record is `broadcast` with its refund height in the second. Mutation test: release without libspiffy's network check (force) and confirm the second case fails.

## 3. Resubmission

- [x] 3.1 `submitWaitingDeposits` takes `submitting` deposits as well as mined `broadcast` ones, and records `depositPending` as accepted. Verify "No answer": a stub that answers nothing leaves `submitting` in `cloak status`, and the next `cloak sync` against an answering stub records `accepted`.

## 4. Documentation

- [x] 4.1 Update the README's deposit section and the `cloak deposit` help: one command, what a refusal leaves, `--submit` for a deposit left submitting, and `--broadcast` as the way to put a covenant on the chain regardless. Verify the README's commands against `cloak deposit --help`.

## 5. End to end and measurement

- [ ] 5.1 The localnet end-to-end run against pool-coordinator 0.1.8 or later (built from ../pool-coordinator, as the harness does): `cloak deposit` then `cloak sync`, with no block mined between the deposit and its answer, gives the depositor's note once the round is mined. Record the answer time in docs/DESIGN.md. Then run one deposit against the live testnet pool and record its time there too.
