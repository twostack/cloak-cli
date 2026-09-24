# Tasks

Every task says how it is shown done. Performance tasks record their number, the
machine and the parameter set in `docs/DESIGN.md`, appended in a dated section, never
rewritten; each is measured best-of-N so a loaded machine does not decide it.

Group 0 is work in **other repositories**. It is named here rather than absorbed,
because the deposit and withdraw commands do not compile without it.

## 0. Work owed by sibling repositories

- [x] 0.1 **In `../libspiffy`**: export `BlockHeaderChain` (and the `BlockHeaderAnchor`
  and `HeaderAcceptResult` types its signatures need) from `lib/libspiffy.dart`.
  *Verified by*: a file in this repository naming the type compiles, which is task 3.1.
  No requirement of libspiffy's changes, so no spec delta there.
- [x] 0.2 **In `../libcloak`**: propose and build `DepositBuilder` beside
  `PaymentBuilder` — a transfer with two dummy inputs, BSV in, the depositor's note as
  output 1 — as an addition to libcloak's `payments` capability.
  *Verified by*: libcloak's own suite, and by this repository's task 7.3.
- [x] 0.3 **In `../libcloak`**: propose and build `WithdrawalBuilder` — a real note in,
  money out, carrying a withdrawal record naming exactly the amount taken.
  *Verified by*: libcloak's own suite, and by this repository's task 7.6.
- [x] 0.4 Record in this repository's `docs/DESIGN.md` which sibling changes this one
  waited on and what landed. *Verified by*: the section exists and names the commits.

## 1. The package and the command shell

- [x] 1.1 Lay out the package: `bin/cloak.dart`, `lib/src/`, `test/`, a `docs/DESIGN.md`
  opened with a dated first section, `dart_test.yaml` with tags for the runs that need
  localnet and the run that needs a coordinator.
  *Verified by*: `dart analyze lib bin test` clean and `dart test` green on an empty
  suite.
- [x] 1.2 Build the argument parser and the subcommand table for all seventeen
  subcommands, each a stub that reports "not built yet" and exits 1.
  *Verified by*: tests for `"An unknown subcommand"` and `"Help costs nothing"`.
- [x] 1.3 Build the refusal printer: a `Refusal` from any library below reaches the
  person as its step name and its own sentence, never replaced by a word of this
  program's. Build the exit-code rule: 0 done, 1 refused, 2 malformed command.
  *Verified by*: tests for `"A refusal is not a usage error"`, and a test that asserts
  no user-facing string in this package is the bare word "invalid", "error" or
  "failed".
- [x] 1.4 Build the bounded file reader used by every command taking bytes from another
  person: the file's size is checked against the message kind's maximum before it is
  read. *Verified by*: a test for `"An oversized invoice file"` that also asserts no
  allocation of the declared size.
- [x] 1.5 Build the two output forms: readable lines, and `--json` as one object on
  standard output with nothing else on that stream.
  *Verified by*: tests for `"Both forms carry the same facts"` and `"Balance is stable"`.
- [x] 1.6 Build the passphrase path: terminal prompt with echo off, or a named
  environment variable; a passphrase given as a command-line argument is refused naming
  the risk. *Verified by*: a test for `"A passphrase is never an argument"`.
- [x] 1.7 Build `cloak status` to print the program's version and every state format
  version it understands, and to refuse a state file written by a newer version naming
  both. *Verified by*: a test for `"State from a newer wallet"`.
- [x] 1.8 **Non-functional, secrets**: a test that runs every command at the highest
  verbosity against the fake pool and searches both streams for the seed, the spending
  key, the passphrase and the ricochet seed, raw and hexadecimal.
  *Verified by*: `"Verbose output holds no key material"`.
- [x] 1.9 **Non-functional, untrusted input**: a mutation test that feeds each
  byte-taking command a file of random bytes and a hundred truncations of a valid file.
  *Verified by*: `"Bytes that are not a message at all"` and `"A proof that does not check out"`.
- [x] 1.10 **Non-functional, startup cost**: measure `cloak --help` and assert under
  500 ms, with neither the SPV side nor the transport constructed.
  *Verified by*: `"Balance touches no network"` for the port assertion and a timing
  test for the bound. If the bound is missed, make construction lazy, re-measure, and
  only then move the bound with the number recorded.
- [x] 1.11 **Non-functional, failure behaviour**: a test that kills the process between
  writing a temporary state file and renaming it, for each state file.
  *Verified by*: `"Interrupted in the middle of a write"`.

## 2. The wallet directory and its state

- [x] 2.1 Build config loading and wallet-directory resolution in the stated order,
  with `cloak status` reporting which source named it.
  *Verified by*: a test for `"The directory in use is always visible"`.
- [x] 2.2 Create the directory owner-only, and warn without refusing when it is found
  wider. *Verified by*: a test for `"A world-readable wallet is reported"`.
- [x] 2.3 Build `cloak init`: generate a seed, encrypt under a passphrase, write the
  wallet file, print the seed once on its own stream, and refuse an occupied directory.
  *Verified by*: tests for `"init refuses an occupied directory"` and `"The seed is recorded before anything else exists"`.
- [x] 2.4 Build `cloak unlock` and the passphrase-to-keys path, holding nothing beyond
  the process. *Verified by*: tests for `"Non-interactive use works without a terminal"` and `"A wrong passphrase is a named refusal"`.
- [x] 2.5 Build the exclusive wallet lock for writing commands, with no lock for
  read-only ones and a bounded wait.
  *Verified by*: tests for `"Two payments at once"` and `"A read-only command needs no lock"`.
- [x] 2.6 Build the save-all path over libcloak's `WalletFile`, `PoolViewFile`,
  `NoteStoreFile` and `Journal`, temp-then-rename for each.
  *Verified by*: a test for `"Killed mid-write"`.
- [x] 2.7 **Non-functional, compatibility and untrusted input**: a mutation test
  truncating the note store at a hundred offsets and asserting a named refusal each
  time with the file unchanged. *Verified by*: `"A truncated note store"`.
- [x] 2.8 Make `cloak status` list each state file, its size and whether it is
  encrypted, saying plainly that the note store is not.
  *Verified by*: a test for `"status tells the truth about the files"`.
- [x] 2.9 **Non-functional, performance**: measure saving all state for a wallet of
  1,000 notes and assert under 500 ms.
  *Verified by*: `"A thousand notes save inside the bound"`. If missed, profile the
  save path before moving the bound.

## 3. Headers: libcloak's port over libspiffy's chain

- [x] 3.1 Build the `HeaderSource` adapter over `BlockHeaderChain`: tip from
  `bestHeight` and `chainTip`, height from `getHeightByHash`, the 80 bytes from
  `getHeaderByHeight(...).serialize()`. Depends on task 0.1.
  *Verified by*: tests for `"The adapter's surface is the port's surface"` and `"A hash off the accepted chain"`.
- [x] 3.2 Build starting and stopping the libspiffy actor system, only for commands
  that need the chain, with the data directory under the wallet directory and the
  network from config. *Verified by*: a test for `"Switching networks in the config"`.
- [x] 3.3 Turn a height into confirmations from this source alone, and never from a
  proof or the pool. *Verified by*: a test for `"A proof claiming its own depth"`.
- [x] 3.4 Report a block above the tip as a refusal naming the height and the tip, and
  tell the person to sync. *Verified by*: a test for `"A block the chain has not reached"`.
- [x] 3.5 **Non-functional, privacy**: a test recording every outbound request while a
  payment proof is checked against a chain already holding its block, asserting none.
  *Verified by*: `"Checking a proof makes no request naming its block"`.
- [x] 3.6 **Non-functional, privacy**: a test searching a used wallet's header records for
  its note commitments, addresses and transaction ids, and a test that `cloak status`
  describes the chain database as also holding the transparent wallet.
  *Verified by*: `"The header store names no wallet"` and `"status says what the chain database holds"`.
- [x] 3.7 **Non-functional, untrusted input**: offer ten thousand well-formed headers
  that connect to nothing and assert the off-chain retention stays inside the chain's
  declared bound. *Verified by*: `"A flood of unconnected headers"`.
- [x] 3.8 **Non-functional, determinism**: two processes over one header store agree on
  all three answers. *Verified by*: `"Two processes agree"`.
- [x] 3.9 **Non-functional, failure behaviour**: with no peers and a short store, a
  command needing the chain refuses carrying the source's reason and asks nobody else.
  *Verified by*: `"The SPV side is down"`.
- [x] 3.10 **Non-functional, performance**: measure opening the chain over the localnet
  harness's store and assert the first question answerable in under 2 s.
  *Verified by*: `"A warm chain opens inside the bound"`.

## 4. Transport: libcloak's port over ricochet

- [x] 4.1 Build the wallet's ricochet host and client in this package against
  `package:ricochet` directly, keeping the two details the existing test implementation
  earned: buffering spare replies because the folder marks what it hands over as
  delivered, and the feed's sequence numbering starting at one.
  *Verified by*: a test for `"The transport does not read messages"`.
- [x] 4.2 Assert the layering: the coordinator's package is a development dependency
  only. *Verified by*: a test for `"The runtime dependency graph"` reading the
  package's own manifest.
- [x] 4.3 Generate and store the wallet's ricochet identity in the wallet directory,
  derived from nothing else the wallet holds.
  *Verified by*: a test for `"The identity is unrelated to the wallet"`.
- [x] 4.4 Bound every incoming frame by the protocol's maximum for its kind before
  reading it. *Verified by*: a test for `"A coordinator that declares an enormous reply"`.
- [x] 4.5 Wire reply routing by submission id through libcloak's client, and discard a
  reply naming nothing in flight.
  *Verified by*: tests for `"Two submissions whose replies cross"` and `"A reply for a submission never sent"`.
- [x] 4.6 Enforce the second deadline: a command returns within twice the configured
  timeout even when the transport never does.
  *Verified by*: a test for `"A transport that never returns"`.
- [x] 4.7 Report an unanswered submission as its own outcome, leaving the note reserved
  and writing a journal entry.
  *Verified by*: a test for `"The coordinator goes quiet after taking a submission"`.
- [x] 4.8 **Non-functional, compatibility**: a reply of an unknown protocol version is
  refused naming both versions.
  *Verified by*: `"A coordinator speaking a later protocol"`.
- [x] 4.9 **Non-functional, untrusted input**: a mutation test delivering ten thousand
  one-byte-mutated and truncated replies.
  *Verified by*: `"Mutated frames never crash the wallet"`.
- [x] 4.10 **Non-functional, privacy**: assert that two wallets at different rounds send
  the same catch-up range.
  *Verified by*: `"A catch-up request says nothing about the asker"`.
- [x] 4.11 **Non-functional, performance**: measure reading a hundred feed entries from
  the ricochet server the suite starts, asserting under 5 s.
  *Verified by*: `"A hundred entries inside the bound"`.

## 5. `cloak sync`

- [x] 5.1 Build the first-run path: head proof, check against the wallet's own headers,
  then the frontier accepted only because it computes that head's commitment root.
  *Verified by*: tests for `"A pool that offers someone else's tree"` and `"The round number comes from the chain, not the claim"`.
- [x] 5.2 Build the later-run path: fold block roots in order, skipping none, then one
  check at the end of the run.
  *Verified by*: tests for `"A wrong block root is caught at the end of the run"` and
  `"The view refuses to spend while unchecked"`.
- [x] 5.3 Wire the detached probe that catches an announcement contradicting its own
  header before anything is folded.
  *Verified by*: a test for `"A self-contradicting announcement"`.
- [x] 5.4 Report a round the pool later describes differently, naming both values.
  *Verified by*: a test for `"A round announced twice with different roots"`.
- [x] 5.5 Build catch-up over the pool's published aligned runs, and report plainly when
  the coordinator does not serve it.
  *Verified by*: tests for `"Two wallets at different rounds ask the same question"` and
  `"A pool that does not serve catch-up"`.
- [x] 5.6 Check the descriptor's shape against the stored state's shape and refuse
  naming both. *Verified by*: a test for `"A descriptor with a different block size"`.
- [x] 5.7 Make a held note's path come forward by folding every round since it was
  minted, never from a frontier.
  *Verified by*: a test for `"A held note after a catch-up"`.
- [x] 5.8 **Non-functional, failure behaviour and determinism**: make sync resumable and
  idempotent, writing nothing when already current.
  *Verified by*: tests for `"Interrupted and resumed"` and `"Already current"`.
- [x] 5.9 **Non-functional, privacy**: assert two wallets holding different notes send
  indistinguishable frames syncing the same span.
  *Verified by*: `"Two wallets holding different notes sync identically"`.
- [x] 5.10 **Non-functional, performance**: measure a 1,000-round sync, reporting the
  folding share separately, asserting under 30 s whole and under 2 s folding.
  *Verified by*: `"A thousand rounds inside the bound"`. If the whole command misses,
  batch the feed reads and re-measure before moving the bound.

## 6. Payments

- [x] 6.1 Build `cloak invoice new` and `cloak invoice show` over libcloak's `Invoice`,
  deriving a fresh address each time and bounding the memo in bytes.
  *Verified by*: tests for `"Two invoices, two addresses"` and `"A memo too large"`.
- [x] 6.2 Build `cloak pay`'s pre-proof checks in the order libcloak defines, so a
  refusal costs no proving work.
  *Verified by*: tests for `"An expired invoice costs nothing"` and `"An invoice for another pool"`.
- [x] 6.3 Wire submission so the note is reserved before the frame leaves and moved by
  the answer alone.
  *Verified by*: tests for `"The four answers move the note four ways"` and `"A second payment cannot pick the same note"`.
- [x] 6.4 Make a retried send carry the same bytes and the same id.
  *Verified by*: a test for `"Retried sends carry one id"`.
- [x] 6.5 Build `cloak proof` in both forms, finding the leaf by the wallet's own
  commitment in the mined round.
  *Verified by*: tests for `"The leaf comes from the round"` and `"The round does not hold it"`.
- [x] 6.6 Build `cloak check`, with no path into the note store for an unverified proof.
  *Verified by*: tests for `"A round with a forged lineage"`, using the localnet
  forgery, and `"A proof shorter than it claims"`.
- [x] 6.7 Build `cloak ack` in both directions: signing only what was checked and only
  in time, and checking one against the invoice alone.
  *Verified by*: tests for `"A payment that arrived late"`, `"An acknowledgement for the wrong invoice"` and `"A forged acknowledgement"`.
- [x] 6.8 Build `cloak balance`, `cloak notes` and `cloak journal`, including the
  per-invoice thread and the refused-entry report.
  *Verified by*: tests for `"A thread for one invoice"` and `"An edited journal is refused, not repaired"`.
- [x] 6.9 **Non-functional, secrets and privacy**: search a used wallet's whole directory
  for the nullifiers of the notes it spent, and record every request made during a
  check.
  *Verified by*: `"The wallet directory holds no nullifiers"` and `"Checking a payment makes no request"`.
- [x] 6.10 **Non-functional, compatibility and determinism**: refuse an unknown message
  version naming both, and assert encode-decode-encode is byte-identical.
  *Verified by*: `"An invoice from a later version"` and `"Two encodings agree"`.
- [x] 6.11 **Non-functional, performance**: time `cloak pay`'s phases and assert the
  share outside the spend proof is under 108 ms.
  *Verified by*: `"The host's share of a payment"`.

## 7. Deposits, refunds and withdrawals

- [x] 7.1 Build `cloak receive` over libspiffy's BEEF validation and its pending-receive
  model, parking a receive until its header arrives and never requesting that block.
  *Verified by*: tests for `"A payment whose block the wallet has not reached"` and `"A payment with a bad merkle proof"`.
- [x] 7.2 Build the PP3 outpoint the covenant names, from a checked round's transaction
  id and the PP3 output index, refusing an unchecked view.
  *Verified by*: tests for `"Depositing against an unchecked view"` and `"The covenant names the round the wallet checked"`.
- [x] 7.3 Build `cloak deposit`: fund from libspiffy, build the covenant with
  tstokenlib, build the deposit transfer with libcloak's new builder from task 0.2,
  record and broadcast the covenant, and submit the transfer with the covenant attached
  from a later `cloak sync` or `cloak deposit --submit` once the covenant is mined.
  *Verified by*: tests for `"The transfer's shape is checked before it is sent"` and
  `"Submitted once mined"`.
- [x] 7.4 Choose and print the refund height with margin, require confirmation, and
  refuse a height a coordinator would skip.
  *Verified by*: tests for `"The person is told what they are risking"`, `"A refund height too close to be included"` and `"The warning is shown"`.
- [x] 7.5 Track a deposit to the round that carries its receipt and take the note on
  only from a mined round.
  *Verified by*: tests for `"Pending until mined"` and `"Taken on when the round arrives"`.
- [x] 7.6 Build `cloak withdraw` over libcloak's new builder from task 0.3, with change
  returning to a fresh pool address.
  *Verified by*: tests for `"The withdrawal and the public amount agree"` and
  `"Withdrawing more than the note holds"`.
- [x] 7.7 Build `cloak refund` over `createDepositRefundTxn`, refusing before the refund
  height and refusing a covenant already spent.
  *Verified by*: tests for `"Refunding too early"` and `"Refunding a deposit that was taken in"`.
- [x] 7.8 **Non-functional, failure behaviour**: record a transparent transaction
  durably before broadcasting it, and add the command that broadcasts a recorded one
  without rebuilding it.
  *Verified by*: `"Killed between recording and broadcasting"` and `"Killed after broadcasting"`.
- [x] 7.9 **Non-functional, privacy**: assert the transparent and pool key trees are
  unrelated and that every transparent address used is fresh.
  *Verified by*: `"Fresh addresses each time"` and `"The two key trees are unrelated"`.
- [x] 7.10 **Non-functional, untrusted input**: bound and version-check every
  transaction and BEEF payment read from another party, with a mutation test.
  *Verified by*: `"Mutated BEEF never crashes the wallet"` and `"An over-long deposit transaction"`.
- [x] 7.11 **Non-functional, performance**: time building a deposit outside the spend
  proof and the network, asserting under 500 ms.
  *Verified by*: `"Building a deposit inside the bound"`.

## 8. End to end

- [x] 8.1 Build the fake-pool end-to-end test: init, sync, invoice, pay, proof, check,
  ack, balance, journal, driven through the real binary's argument parser.
  *Verified by*: the test passing in the default suite.
- [x] 8.2 Build the localnet end-to-end test: a real pool, a real coordinator over
  ricochet, a deposit that a round takes in, a payment out of the deposited note, and a
  withdrawal, gated behind its own environment switch so it is asked for rather than
  swept into the default pack.
  *Verified by*: the test passing under that switch.
- [x] 8.3 Build the refund end-to-end test: a deposit no round takes in, refunded at its
  height on localnet. *Verified by*: the test passing under the localnet switch.

## 9. The record and the suite

- [x] 9.1 Write `docs/DESIGN.md`'s dated sections for each group: what was built, what
  was measured, on which machine and at which parameters, and what was decided against.
  *Verified by*: the file holds one section per group with the numbers from tasks 1.10,
  2.9, 3.10, 4.11, 5.10, 6.11 and 7.11.
- [x] 9.2 Write the README: what `cloak` is, the commands, what a person must back up
  and that the seed alone is not yet enough, and the runs the suite has.
  *Verified by*: every command listed exists, checked by a test reading the README
  against the subcommand table.
- [x] 9.3 Run `dart analyze lib bin test` and the three suite forms, and record the
  counts. *Verified by*: zero analyzer errors and the recorded counts in `docs/DESIGN.md`.
- [x] 9.4 Run `python3 ../openspec-practice/snippets/scenario-coverage.py
  openspec/changes/cloak-cli` and drive it to zero, or record under the group why a
  named scenario is covered elsewhere.
  *Verified by*: the script reporting nothing missing.
