## Why

A deposit today takes two commands and a block. `cloak deposit` broadcasts the covenant, and a later `cloak sync` submits it once mined. On testnet on 2026-09-25 that was about 11 minutes: two deposits were broadcast just after block 1759899 at 15:00:09 and mined in 1759900 at 15:10:59. The wait also cost one of the two deposits outright. The first was submitted at 15:20:57 and taken into round 5. The second was submitted at 16:03, after round 5 had closed. It named round 4's PP3, which round 5 had spent, so it was refused, and its 15,000 satoshis stay locked until refund height 1760043. The pool coordinator 0.1.8 (change `deposit-on-seen` in ../pool-coordinator) takes a covenant handed to it unbroadcast. It broadcasts it after checking the submission, and admits the deposit once the network has seen it.

## What Changes

- **`cloak deposit` becomes one command.** It builds and records, as now. Then, in place of broadcasting, it submits the deposit's transfer with the covenant attached and reports the coordinator's answer. It does not broadcast the covenant itself.
- **Accepted:** the covenant is marked broadcast, since the coordinator sent it. The wallet asks libspiffy for the payment's status, so its coins count as spent and its change comes back.
- **Refused:** the wallet gives the coins back through libspiffy's cancel, which refuses when the network knows the transaction. So a covenant the network never saw costs nothing, and one it did see keeps the refund path.
- **Refused by a coordinator older than 0.1.8** ("…is not mined"): the old two-step flow. cloak broadcasts the covenant itself, and `cloak sync` submits it once mined.
- **Unanswered:** the deposit stays `submitting`, and `cloak sync` or `cloak deposit --submit` submits it again. A resubmission answered "a pending transfer already backs this covenant" (`depositPending`) counts as accepted.
- `cloak deposit --broadcast <txid>` stays, for a covenant the person wants on the chain whatever the coordinator says.

Every command here is wiring of behaviour its libraries already have: libspiffy's deferred payments are built to be broadcast by their recipient, checked, and cancelled only when unseen, and tstokenlib's submission already carries the covenant. The one piece of new behaviour is the fallback for an older coordinator. It exists because the live pool and cloak releases do not move together.

## Capabilities

### Modified Capabilities

- `deposits`:
  - "A deposit is submitted once its covenant is mined" becomes "A deposit is handed to the coordinator, which broadcasts it".
  - "A deposit's worst case is a delay" now tells the person before the covenant is handed over, not before it is broadcast.
  - Added: "A deposit the coordinator refused costs nothing".

## Measured numbers and bounds

- **From built to answered:** from one block plus a manual `cloak sync` (about 11 minutes, above) to one coordinator round trip. The coordinator bounds a deposit's reply at 20 s (its server-process spec), inside cloak's 30 s reply timeout (`wallet/config.dart`). The spec makes "answered within cloak's reply timeout, else left `submitting`" a requirement. Task 5.1 measures the live figure.

## Non-functional contract

- **Untrusted input:** the coordinator's reply is decoded as tstokenlib decodes one. A refusal is shown with its reason, and nothing it says spends or releases a coin without libspiffy checking the network first. Requirement.
- **Secrets and privacy:** the covenant was already public once broadcast, and is now sent to the coordinator a few seconds earlier. The wallet no longer broadcasts it from its own network address. Nothing new names an address, txid or outpoint in a request. Requirement.
- **Trust:** the coordinator's acceptance is not taken as proof of broadcast. The wallet asks libspiffy, which asks ARC.
- **Determinism:** not applicable.
- **Compatibility:** works against coordinators before and after 0.1.8. Requirement.
- **Performance and resources:** the bound above.
- **Failure behaviour:** unanswered leaves the deposit resubmittable, and the coins are released only when the network does not know the covenant. Requirement.

## Impact

- `lib/src/commands/deposit_commands.dart` (`runDeposit`, `submitWaitingDeposits`), `lib/src/shell/world.dart` and `lib/src/chain/spiffy_transparent.dart` (a `settle` over libspiffy's status check; `release` reporting whether it released), the README's deposit section, `test/deposit_test.dart` or its equivalent, and the localnet end-to-end test.
- No sibling repository needs to change. libspiffy's `CheckDeferredPaymentStatusCommand` and `CancelDeferredPaymentCommand` already do what this needs. The coordinator side is ../pool-coordinator's `deposit-on-seen`, released as 0.1.8.
