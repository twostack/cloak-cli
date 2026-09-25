# cloak: the design record

A running record, appended in dated sections and never rewritten: what was
built, what was measured, on which machine and at which parameters, and what
was decided against. The plan it follows is the OpenSpec change `cloak-cli`
under `openspec/changes/`.

## 1. The package, and what it waited on (2026-09-24)

### The shape

`cloak` is a host. `bin/cloak.dart` builds a `World` from the process (the two
streams, the environment, a prompt with echo off, and `ProcessPorts`, which
start the chain and open the transport on first use) and hands it to
`runCloak`. The suite builds a `World` from doubles and calls the same
function, so every command runs in-process against a fake pool and a test can
count what a command started.

```
lib/src/shell/     the argument parser, the seventeen subcommands, the report
                   printed as lines or one JSON object, the refusal printer,
                   the bounded file reader, the passphrase rule
lib/src/wallet/    the wallet directory, config.yaml, the lock, this program's
                   own state file, and the Session every command opens
lib/src/chain/     libcloak's HeaderSource over libspiffy's BlockHeaderChain
lib/src/net/       libcloak's Transport over ricochet, the transport identity
lib/src/commands/  one file per group of commands
```

A command never prints. It adds facts to a `Report`, each with the line a
person reads it as, and the shell prints the lines or the JSON. Both forms
come from the same calls, which is what "both forms carry the same facts"
rests on.

Exit codes are 0 done, 1 refused, 2 malformed. A `Refusal` from a library is
printed as `cloak <command>: refused at "<step>": <the library's sentence>`,
unchanged; anything a library throws that is not a refusal is still a
sentence and exit 1, never a stack trace.

### Sibling work this change waited on

| task | repository | what | state |
|---|---|---|---|
| 0.1 | `../libspiffy` | exports `BlockHeaderChain`, `BlockHeaderAnchor`, `HeaderAcceptResult`, `HeaderRejectReason` and `NetworkParams` from `lib/libspiffy.dart` | uncommitted on top of `cb3c03f`; that file also carries someone else's uncommitted `type42` export, left alone |
| 0.2, 0.3 | `../libcloak` | `DepositBuilder`, `WithdrawalBuilder`, `CoordinatorClient.submitDeposit` and `submitWithdrawal`, four journal kinds; OpenSpec change `onramp-builders` in libcloak, validated strict | uncommitted on top of `149a36a`; libcloak's suite 231 pass, 3 skipped; `test/onramp_test.dart` 17 pass |
| R1 to R5 | `../pool-coordinator`, `../tstokenlib` | the coordinator answers catch-up, serves a mined round by number with its leaves and nullifiers, refuses quickly, and optionally pushes proven rounds | asked for on 2026-09-24 and in progress in those repositories; see below |

The commits are not made: this change commits nothing in any repository until
asked, and the sibling repositories are the same.

### A gap the design did not see: where a mined round comes from

`cloak proof` needs the mined round's transactions, the witness's merkle
branch and the paid note's full path. So does taking on the payer's change,
marking its spent note spent, and taking on a deposit's note. Neither port
supplies them: the feed's announcement carries three txids, the coordinator
answered only submissions, and libcloak's own localnet run fetched the round
from a node by txid and replayed a ledger from the pool's genesis. A wallet
that looked the round up somewhere would be making exactly the request the
design rules out.

The decision, taken with the person on 2026-09-24: the coordinator delivers
them. The asks were written down as R1 to R5 (answer the three catch-up
requests; serve any mined round by number; carry the round's leaves, frontier
and nullifiers, all of which the wallet checks against the proven header;
refuse quickly rather than stay silent; optionally push proven rounds to
submitters). Until they land, `cloak proof` refuses at the step `round source`
naming what it lacks, and does not look anywhere else.

### Decided against

- **A shared host-building package for ricochet.** Two callers, a small
  wallet half; see the change's design.
- **Parsing libcloak's prose.** One place does: `cloak sync` recognises a feed
  that no longer reaches its next round by the round the refusal names. It is
  recorded here because it will break if that sentence changes; libcloak
  exposing the gap as a value would remove it.
- **Following the feed from a stored sequence.** `CoordinatorClient` starts
  each process at the descriptor and passes over rounds it has folded, so a
  sync re-reads the feed from its start. The rounds it passes over cost a
  decode each; a `from` on `CoordinatorClient.open` would remove it.

## 2. The shell and the wallet directory (2026-09-24)

Measured on an Apple M3 Pro, Dart 3.11.5, test parameters throughout.

| | measured | bound |
|---|---|---|
| `cloak --help`, compiled binary, first run of a fresh binary | 303 ms (warm 14 ms) | **500 ms** |
| `cloak balance` cold, compiled binary, a wallet holding a note | 24 ms, no chain started, no transport opened | **3 s** |
| saving a wallet of 1,000 notes: the view, the store, the state and one journal entry | best 52 ms, worst 65 ms, of 7 | **500 ms** |
| the pool view at 1,000 notes / the note store | 1,069,344 B (1,069 a note) / 73,010 B (73 a note) | as libcloak measured |

**The lock** is the operating system's record lock on `cloak.lock`, plus a set of paths
this process holds, because POSIX record locks never conflict within one process and the
suite runs two commands in one. The set is claimed before the first await; the first
version checked and then awaited, and two payments in one process both got in. A second
writer waits two seconds and is refused naming the directory and the holder's process id.

**Interrupted writes.** This program's own state file is killed for real between its
temporary file and its rename (`test/support/die_mid_write.dart`). libcloak saves the
wallet file, the pool view and the note store with its own temp-then-rename and offers no
seam between the two, so for those the test puts the wreckage where a kill leaves it and
checks the next command opens the previous contents and the next save replaces the
wreckage.

**Decided against:** a `--passphrase` flag in any form, and a report printed as the
command goes. A command adds facts to a `Report` and the shell prints lines or JSON from
it, so the two forms cannot drift.

## 3. Headers (2026-09-24)

| | measured | bound |
|---|---|---|
| a warm header store over localnet (31,261 headers), started as a command starts it, to its first answer | best 950 ms, worst 960 ms, of 3 | **2 s** |
| the same store filled cold from localnet's node | 13.5 s | none set |
| 10,000 well-formed headers connecting to nothing | 10,000 refused, 0 retained | the chain's own bound of 200,000 |

The chain start waits while headers arrive, printing the height, and answers at once from
a store that has not moved in 750 ms. The first version waited three quiet seconds every
time, which by itself missed the 2 s bound.

A network switch is caught by a file in the header store naming the network it was built
for, before anything is started; the store is left untouched.

**Read closely:** "A block the chain has not reached" asks the refusal to name the height
asked for. A standing proof names a block hash and no height, and a hash above the tip is
one the chain has never seen, so its height is unknowable. The refusal names the tip and
says to sync.

## 4. The transport (2026-09-24)

| | measured | bound |
|---|---|---|
| a hundred feed entries from a ricochet server on this machine | best 12 ms, worst 18 ms, of 3 | **5 s** |
| 10,000 mutated replies to a submission and 500 mutated head proofs, through this program's wrappers | 9,652 refused at 17 steps, 848 taken, none threw | none may throw |

The wallet opens its own streams to the server for the mailbox and the feed, and reads
every frame through `BoundedFrames`: four bytes of length, compared with the bound for the
kind, then the body. Ricochet's own reader takes the length and reads whatever it says.

**A semantic trap, avoided.** libcloak's `send` counts a `TransportFailure` as "never
sent", and after three releases the note. So once a frame is stored, a missing reply is
never reported as a failure: the transport keeps polling, and libcloak's own deadline of
twice the timeout reports the submission unanswered, with the note still reserved. A
transport that threw on a reply timeout would release a note that may be in a round.

**Frames are compared by what they ask.** The coordinator team is giving catch-up requests
an id; each is fresh and names nothing, so the privacy tests compare what a request asks
(kind, first round, count) rather than its bytes.

## 5. `cloak sync` (2026-09-24)

| | measured | bound |
|---|---|---|
| 1,000 rounds over a ricochet server on this machine, holding 8 notes | 5,072 ms whole, of which about 4,000 ms is waiting on a head proof the coordinator does not serve yet | **30 s** |
| the folding and checking inside it | 890 ms | **2 s** |

The folding share is the whole command less the time spent inside the transport, measured
by a stopwatch wrapped around it. A check that cannot be made because the pool will not
prove its head saves the fold as folded and unchecked, prints what completed, and exits 1.

**Read closely:** "The round number comes from the chain, not the claim". libcloak refuses
a head proof whose stated round disagrees with its own leaf count, which is stricter than
using the leaf count's round: the claim is never used, and neither is anything that came
with it.

**The live round.** A deposit names the live round's PP3, the round's transaction output 3,
and the client does not hand announcements back. `cloak sync` keeps the feed entries it
read (`FeedTap`, above the transport, which still decodes nothing) and records the
announced transaction of the round the view stands at.

## 6. Payments (2026-09-24)

| | measured | bound |
|---|---|---|
| the host's share of `cloak pay`, outside the spend proof, the network and the passphrase | best 50 ms, worst 52 ms, of 3 | **108 ms** |
| libcloak's own work inside it | 5 ms | libcloak's 8 ms |
| the spend proof | 39 to 43 ms | none here |
| the passphrase KDF at the suite's fast setting, twice (open, and rewriting the counter for the change address) | 45 to 51 ms | excluded |

**The bound, read.** The spec bounds the host's share "excluding the spend proof". A spending
command also unlocks the wallet file, which is Argon2id by design: about 0.4 s at the strong
setting a person gets. That is the wallet file's deliberate cost, not work this program
does per payment, so it is reported beside the others and left out of the share. The first
measurement, 117 ms, included it; it also rewrote the wallet file twice, which is fixed.

`cloak pay` reserves the note **and saves the reservation** before the frame leaves, so
neither a second process nor a crash between the send and the answer can pick the same note.
The same path serves `cloak withdraw`.

**The fixture's keys.** The fake pool's notes are minted to a fixture wallet whose keys no
seed derives. The suite stands those pool keys in for a wallet's own through
`World.poolKeysForSuite`; the binary never sets it. libcloak's own end-to-end run has the
same seam.

**The forgery** used for "A round with a forged lineage" is libcloak's lineage attack built
in memory, mined into a fake chain the payee's header source vouches for. It is refused at
`PP1 is this pool's script`, with the checker's own sentence.

## 7. Deposits, refunds and withdrawals (2026-09-24)

| | measured | bound |
|---|---|---|
| building a deposit outside the spend proof and the funding | 100 ms, best of 3 (including the passphrase KDF) | **500 ms** |
| the deposit's spend proof | 38 to 46 ms | none here |
| 1,000 mutated BEEF payments | 500 read, 500 refused at `BEEF`, none threw | none may throw |

**The covenant script.** tstokenlib writes the covenant inside `createDepositTxn` and does not
export its generator, so the script is read off a transaction built over a throwaway coin;
the lock depends only on the terms. An export in tstokenlib would remove the detour.

**The transparent side's secrets** (libspiffy's mnemonic, and each deposit's refund key) are
sealed in `keys.enc` with XChaCha20-Poly1305 under a key expanded from the wallet seed.
Nothing in there is derived from the seed; the seed only seals it.

**Verified since:** the libspiffy-backed transparent side ran against the regtest node and
ARC in the localnet end-to-end run (section 10), which found four faults in it that no fake
could have shown.

## 8. The suite, and why the timing bounds run on their own (2026-09-24)

The host's share of `cloak pay` measured 50 ms alone and 153 ms in the default pack, where
every test file runs at once on twelve cores. The code was the same; the load was not. The
bound was not moved. The timing tests are tagged `perf`, skipped in the default pack, and
run by `dart test -P perf` one file at a time, which is libcloak's own finding carried over:
a bound on one core read inside a loaded pack measures the pack.

## 9. Mined rounds, read (2026-09-24)

The coordinator now serves catch-up, a mined round by number, and a mined-round notice
(tstokenlib change `wallet-rounds`, protocol version 3; pool-coordinator change
`wallet-catch-up`), and libcloak names a refused catch-up (`7c780c7`). What cloak-cli built
on it:

- **Notices from their own folder.** `readNotices()` drains `pool/notices`; the replies
  folder holds only answers. `drainReplies()` takes answers an earlier run gave up on, and
  every command that sends drains it first, matching a late answer to its submission by
  id, so an unanswered payment gets its real answer and no stale answer is taken as a new
  request's. Both are on `PoolMailbox`, the concrete transport's; libcloak's port is
  unchanged.
- **A round by number** is asked for by cloak-cli itself, over the same opaque transport,
  from the identity that submitted, and matched by the id the request went out under;
  libcloak's client does not ask it yet.
- **Every round is checked** as a head proof is, off this wallet's own headers, and its
  leaves and nullifiers are read by tstokenlib's `ShieldedLedger.readLeaves`.
- **A leaf's path, the gap nobody owned.** Above its block a path is made from the pool's
  frontier at the leaf's own round, which a fold that has moved on cannot give back. `cloak
  sync` therefore folds to each round something of the wallet's waits on (`FeedLimit`, which
  stops the feed at that round's announcement), keeps the frontier there, and folds on. The
  frontier, a few hundred bytes, is dropped once the round is read. A wallet that caught up
  past such a round by the published runs has no frontier for it; the pool would have to
  serve the frontier as of a round, which it offered to add.
- **Settling a round:** its nullifiers mark this wallet's spent notes spent; a payment's
  payee leaf becomes a standing proof kept in `proofs/`, which `cloak proof` hands over or
  shortens; the payer's change, a withdrawal's change and a deposit's note are taken on and
  followed.

**The seam** is libcloak's own: a transfer built here is not in the fixture's round 2, so a
test that needs it there points the payment's record at the note round 2 pays. Everything
after (the round read, the leaf found, the path made, the payee's check) runs on real
bytes; the payee's check of a proof made this way passes.

**Asked of the coordinator, and done.** The late `expired` (sent after an `accepted`, when
the coordinator drops a transfer at close) now goes to the notices folder, so the replies
folder holds only answers. `cloak sync` releases the note it names; any other reply found
among the notices is ignored, since a notice is never an answer. The notice is slim: the
submission ids, the round, the two txids and the witness's place in its block, 141 bytes at
test parameters where the full transactions were about 2.6 MB at production. So a round is
always asked for by number, and its answer must carry the txids its notice named, or
neither is believed.

**A transport fault found on the way.** A request made while a reply from an earlier one
sat buffered handed that reply back without sending its own frame, which dropped the frame
unsent. And a wait whose caller had given up (libcloak's deadline, twice the timeout) went
on polling for a second more, so a late reply could be marked delivered and handed to
nobody. A request now always sends first and is answered only by what arrives after it,
and its wait ends before the caller's, so a late reply stays for `drainReplies`. The
localnet transport test answers a request only after its caller gave up, and fails on the
old wait.

## 10. End to end on localnet (2026-09-24)

`test/localnet_e2e_test.dart` (`POOL_LOCALNET=1 POOL_E2E=1 dart test -t e2e`) issues a pool
with the coordinator's `PoolCreator`, runs it with `PoolServer` over a ricochet server, and
drives three wallets through the **compiled binary**, one process a command, with the real
ports: libspiffy's header chain and transparent wallet against the regtest node and ARC,
and the ricochet transport. A block is mined every four seconds, slow enough for a
command's chain to settle between blocks.

- **A deposit a round takes in** (8.2): coins from the node, handed over as a BEEF carrying
  the node's merkle proof, are taken in by `cloak receive` (7.1, against the real
  libspiffy); `cloak deposit` builds the transfer, libspiffy funds the covenant and ARC takes
  it; the next syncs submit it once mined, and read round 1 to take the note on.
- **A payment out of it**: into round 2, read by the payer's sync, proved by `cloak proof`,
  checked by the payee against its own headers, acknowledged, and the acknowledgement
  checked; the payee holds 1,200 and the payer's change of 3,800 is taken on.
- **A withdrawal**: 1,000 out of the change into round 3, and a mined round pays the node's
  address exactly that; 2,800 is left.
- **A refund** (8.3): a deposit never submitted is refused a refund before its height, naming
  it, and refunded after; the refund spends the covenant and returns the deposit less its fee.

All four pass, in 5 min 57 s on an Apple M3 Pro, most of it waiting for blocks and
rounds. Measured on the way: the pool issued in 26.9 s; a cold `cloak sync` (libspiffy
loading 31,000 regtest headers) 19 to 22 s, a warm one 10.5 s; `cloak deposit` 5.2 s; a
deposit to a spendable note 53 s, which is round 1's 20 s deadline plus mining; `cloak pay`
2.6 s; `cloak withdraw` 2.6 s; `cloak balance` 23 to 30 ms.

**What it found**, none of it visible to a fake:

- libspiffy answers a balance query about a wallet it never heard of with zero, so asking
  for a balance to learn whether the wallet exists always said yes and the wallet was never
  made. It is now asked to make the wallet every time, and "already exists" is the answer
  after the first run.
- libspiffy makes no mnemonic of its own. One is drawn here from `Random.secure()` and handed
  over; libspiffy keeps it in the sealed store, as section 7 already said.
- libspiffy issues a receiving address only with an invoice, and refuses an invoice for
  nothing, so `freshAddress` asks for one satoshi; only the address is kept.
- `SpiffyChain.stop` closed Isar under libspiffy work still in flight after shutdown, which
  failed that work and once crashed the process inside Isar's native library. The database
  is now left open (the process ends right after), and a process that runs many commands
  opens each once.
- A compiled binary cannot resolve a `package:` resource: dartsv's BIP-39 wordlist is one,
  so the English list is carried in the program (checked word for word against dartsv's by
  `test/bip39_test.dart`); and tstokenlib's native kernels, which ML-KEM needs, are found by
  `STARK_KERNELS_LIB` (README, "Running the compiled binary").
- libspiffy prints to stdout, which broke `--json`'s one object. What the libraries print is
  now a log line under `-v` and nothing otherwise.
- A new pool's first deposit was refused: before round 1 there is no announcement, so no
  live round's transaction. The live round at round 0 is the genesis, whose PP3 is the
  issuance's.

**On localnet itself:** ARC and the ricochet server both use port 9090, ricochet on the IPv4
loopback only, so ARC is reached on `[::1]`. And the run was made against libspiffy's last
commit, `0878996`, through a local `pubspec_overrides.yaml`, because libspiffy's working tree
was mid-edit and did not compile.


## 11. The record closed (2026-09-24)

Every number in sections 2 to 10 was taken on an Apple M3 Pro (twelve cores), macOS 14,
Dart 3.11.5, at tstokenlib's test parameters (a two-by-two pool, 32 leaves a round), with
the passphrase KDF at the suite's fast setting except where a section says otherwise. The
localnet runs used `../localnet`'s regtest node (about 31,000 headers) and ARC, and a
ricochet server built from `../go-ricochet` against localnet's PostgreSQL.

### What the sibling repositories landed

Section 1's table was written before any of it was committed. What cloak-cli builds on, by
commit:

| repository | commit | what |
|---|---|---|
| `../libspiffy` | `0878996` | the header chain's export (`BlockHeaderChain`, `BlockHeaderAnchor`, `HeaderAcceptResult`, `HeaderRejectReason`, `NetworkParams`), with libspiffy's own BRC-42 work |
| `../libcloak` | `e0ffd60` | `onramp-builders`: `DepositBuilder`, `WithdrawalBuilder`, `submitDeposit`, `submitWithdrawal`, four journal kinds |
| `../libcloak` | `2c42a6b`, `7c780c7` | its fake pools answer a round by number; a refused catch-up is a named refusal |
| `../tstokenlib` | `37ab3ac`, `48b5c35` | the catch-up messages exported; `wallet-rounds`: protocol version 3, ids and refusals on catch-up, a round by number, `ShieldedLedger.readLeaves`, and the slim mined-round notice |
| `../pool-coordinator` | `e83819e` | `wallet-catch-up`: catch-up answered at the last mined round, rounds by number, notices and late `expired` replies to the notices folder |

tstokenlib's work is on its `main` now (the `feature/shielded-pool` branch is vestigial); the others are on `main`.

### Decided against, group by group

Sections 1, 2 and 8 say what they decided against. For the others:

- **Headers (3).** A second database for headers apart from libspiffy's wallet: libspiffy
  keeps both in one Isar database, and splitting them would mean running its SPV core
  without its actor system, a change in libspiffy for no gain here. The spec was narrowed
  instead, with the person, to "header records name no wallet". A header chain written
  here, and headers from a third party, for the reasons in the change's design.
- **The transport (4).** A shared package for the ricochet host, and lifting the
  coordinator's own transport, which would make the wallet depend on its server. Any
  connection to the coordinator but through the ricochet server. Decoding anything in the
  transport: it hands frames up undecoded and libcloak matches them by id.
- **`cloak sync` (5).** Refusing a fold the pool will not prove: it is saved as folded and
  unchecked, and the next check need not fold it again. Catching up by the published runs
  past a round the wallet waits on: it folds to that round and keeps the frontier, since a
  leaf's path cannot be made without it. Asking for a round's transactions anywhere but the
  coordinator, and from any identity but the one that submitted into it.
- **Payments (6).** Counting the passphrase KDF in the host's share of `cloak pay`; sending
  an invoice, a proof or an acknowledgement anywhere: each is a file the person hands over.
- **Deposits (7).** A deposit in one command that waits for its covenant to be mined: it is
  two, decided with the person. Refund keys derived from the seed: they are drawn at
  random and sealed. Building the covenant through an export tstokenlib does not have.

### The suite, counted

`dart analyze lib bin test`: no issues. Then each form of the suite, on 2026-09-24:

| form | passed | skipped | what the skipped are |
|---|---|---|---|
| `dart test` | 119 | 13 | the localnet runs, the end-to-end run and the timing bounds, each asked for by its own switch |
| `dart test -P perf` | 5 | 3 | localnet's three timing bounds, without `POOL_LOCALNET` |
| `POOL_LOCALNET=1 dart test` | 121 | 11 | the timing bounds and the end-to-end run |
| `POOL_LOCALNET=1 dart test -P perf` | 8 | 0 | |
| `POOL_LOCALNET=1 POOL_E2E=1 dart test -t e2e` | 4 | 0 | |

The last readings of the bounds, in `POOL_LOCALNET=1 dart test -P perf`: `cloak --help`, first
run of a fresh binary, 355 ms (bound 500); `cloak balance` 22 ms (3 s); saving 1,000 notes,
best 49 ms (500 ms); a warm chain's first answer, best 961 ms (2 s); a hundred feed entries,
best 10 ms (5 s); 1,000 rounds, 5,042 ms whole (30 s) and 836 ms folding (2 s); the host's
share of `cloak pay`, best 61 ms (108 ms); building a deposit, best 107 ms (500 ms).

**Found while counting.**

- The localnet form hung, twice, on the thousand-round run: every ricochet server the suite
  starts opened its operator surface on 127.0.0.1:9090, so two in one pack collided, and
  that address is also where localnet publishes ARC. The test server now switches the
  surface off. With the hang gone, the run's folding share read 2,241 ms in the loaded
  pack against 836 ms alone, which is section 8's finding again: localnet's three timing
  bounds are now tagged `perf` like the others, and run by `POOL_LOCALNET=1 dart test -P
  perf`, one file at a time.
- The startup test printed the first run of `cloak --help` and asserted on the best one:
  the list was sorted in place inside the print. It now asserts on the first run, as
  section 2 says the bound is. The first run reads 314 to 403 ms alone; once, straight after
  compiling and after the heavy localnet runs, it read 950 ms, which did not recur.
- Section 5's thousand-round run waits on "a head proof the coordinator does not serve".
  The coordinator serves it now; the run starts no coordinator, so nobody answers, and the
  test now says so.

## 12. Release binaries, first half (2026-09-24)

The change `release-binaries`, applied as far as this repository and this machine allow
(Apple M3 Pro, macOS 14.6, Dart 3.11.5, rustc 1.84.0). What waits on other people's
accounts and repositories is listed in its tasks as group 0.

**Two decisions changed while applying.** tstokenlib 2.0.1, libspiffy 3.0.0 and ricochet
0.1.0 were published on pub.dev the same day, so the siblings come from pub.dev, pinned by
the lock, and libcloak follows once it is published. tstokenlib 2.0.1 also looks for its
kernels in `../lib` from the program's real path, so the bundle has no launcher script: it
is `bin/cloak` and `lib/`, and links point at the program itself.

**Measured on a trial bundle** (built from a working tree with changes, so its `--version`
says `-dirty`; its notices are a placeholder until libcloak has a license):

| | reading |
|---|---|
| the bundle, packed | 7,703,838 bytes (bound 25 MB) |
| Isar's core, built from source at `6643d064` | 27 s, 1.0 MB |
| tstokenlib's kernels, built from the locked package's crate | 8 s |
| the smoke test, whole | 4.3 s |
| the localnet end-to-end suite, run on the bundle's program with `STARK_KERNELS_LIB` unset | 4 passed |

**Counts.** `dart analyze lib bin test tool/release`: no issues. `dart test`: 150 passed, 13
skipped (the 13 as in section 11). The mutation test of the kernels library: 9 cases (empty,
zeroed, random, another platform's, truncated, a flipped header; the variable naming a
directory, a missing path, an empty string), each a `native library` refusal with exit 1.
The mutation test of `install.sh`: 9 cases, each exiting non-zero, naming what failed, and
leaving the installed version as it was.

**Found while applying.**

- A regtest wallet with no peers could not start the chain: libspiffy knows no regtest
  peers and refuses to start P2P with nobody to connect to. The chain now starts without
  P2P then; the transparent side and ARC need no peer. The refusal it gave said the header
  store "does not belong to regtest", because every error from libspiffy's start was read
  as a network mismatch; only the mismatch is now, and anything else is refused at `chain`.
- Isar, given no path, opens a bare file name first, which macOS resolves against the
  working directory: a planted `libisar.dylib` there would have been loaded. A released
  build names the bundled file.
- Isar's repository has no `Cargo.lock`, so a build from its tag floats to the newest
  dependencies, one of which already needed a newer compiler; the release keeps its own.
- The first secret scan flagged 22 runs of hex in the program. All are curve parameters
  written in the source of packages compiled in, so a hex run published in a package is
  now taken as public.

**Changed on 2026-09-25: macOS is a local, notarized disk image.** The person does not want
signing secrets on GitHub, and passed on Homebrew for now. The release workflow builds only
the two Linux bundles and holds no secret; `tool/release/macos.sh` builds the macOS bundle
on the maintainer's Mac, signs it, packs it in a disk image, has Apple notarize it, staples
the ticket and adds it to the workflow's draft. A stapled image also means the first run
needs no network, which a program in a tar.gz could not have. The Werkswinkel Pte Ltd team
is on this Mac, but only as an *Apple Development* certificate, which Apple's notary
service does not accept; a *Developer ID Application* certificate is still owed. A trial
(`macos.sh --trial`, signed with the Apple Development certificate, not notarized): the
whole suite, signing, links, smoke test and secret scan passed, and the image was
9,502,263 bytes, holding exactly the bundle. Copied out quarantined, its program was killed
by macOS and `spctl` rejected it, as it must be for anything not notarized, which shows
the check is a real one. Without a Developer ID, `macos.sh` refuses before building
anything and leaves no image.

**The Developer ID, 2026-09-25.** `Developer ID Application: Werkswinkel Pte Ltd
(32XLPKQ5TF)` is in the keychain (`C027D3BD...`). The trial bundle re-signed with it passed
`sign-macos.sh`'s checks (hardened runtime, timestamp, the one entitlement on the program,
none on the libraries, the chain up to Apple's Developer ID authority), and through a link
it ran `init` and `address`, which loads the signed kernels.

**Notarized, 2026-09-25.** `macos.sh --trial` with the Developer ID and `TRIAL_NOTARIZE=1`
(the whole suite and every check again, the image 9,501,662 bytes): Apple answered
`Accepted` (submission `dd3fb36a-b605-4501-839c-92367bc7e741`), the ticket stapled and
validated, and the image assessed as `source=Notarized Developer ID`. Copied out of the
quarantined image, the program ran `--version`, `init` and `address`; the same check on the
earlier trial, not notarized, had the program killed. An image whose program was signed
without the hardened runtime came back `Invalid` (submission `671886ce-...`) with "The
executable does not have the hardened runtime enabled", and the script failed printing it.

One thing the spec had wrong: `spctl --assess --type execute` judges only app bundles, and
says of any command-line program, notarized or not, "the code is valid but does not seem
to be an app". `codesign --check-notarization` did not tell the two trials apart either.
What does is macOS itself: a quarantined program it cannot vouch for is killed. So the
check is running the quarantined program, with the image's `open` assessment beside it.

**No dependency on the coordinator, 2026-09-25.** The person pointed out that a package
depending on an application is backwards. `pool_coordinator` is gone from
`dev_dependencies`: the localnet end-to-end run builds the coordinator from its checkout with
`dart build cli` and runs `create` and `run` as processes (its output in `coordinator.log`),
and the two localnet transport tests play its end of ricochet with
`test/support/coordinator_end.dart`. Every dependency now comes from pub.dev, and a copy of
the repository with no sibling checkouts resolves from the lock with `--enforce-lockfile`,
leaving it byte for byte unchanged.

The first run as processes hung: the coordinator refused to start, finding no kernels. Its
checkout locked tstokenlib 2.0.1, from before the build hook, and in the test's own process
it had been borrowing cloak's copy unnoticed. Its lock was upgraded to 2.1.0 (its pubspec
already allowed it; the change is in pool-coordinator's `pubspec.lock`, not committed here),
so its own build fetches its kernels as cloak's does, and the test now stops, naming the
cause, when a coordinator build bundles none. Then: the end-to-end run 4 passed (pool created
23.7 s, deposit to note 46.4 s), the localnet transport tests 2 passed, the thousand-round
sync bound passed (folding 832 ms), and the default suite 150 passed, 13 skipped. Two tests
that start a second `dart run` read its standard output, where the build hook now announces
itself; they pass `--verbosity=error`.

## 13. v0.1.0 built (2026-09-25)

**The Linux half, on GitHub.** Three things the first runs found, each fixed on `main` and
tried with the workflow's manual dry run before the tag moved: `.gitignore`'s bare `native`
had kept `lib/src/native/` out of the repository (now `/native`); two chain tests asked Isar
to download a library for Linux arm64, which Isar publishes none of (tests now take the
library just built, `ISAR_CORE_LIB`); and `dart build cli` gives the program the rpath
`$ORIGIN/`, which names no machine and is now allowed, while the Linux Dart runtime's 149 root
certificates are public and no longer taken for a secret (the scan looks for private keys).
CI on Linux had also found that `dlopen` of a damaged library kills the process there (the
program now reads a library before loading it), and that a test's child `dart run` rewrote
the kernels library under the test process (helpers run on `dartvm`).

Release run `36080803420` on `v0.1.0` (`a3a9cab`): Isar built from its commit `6643d064` on
both runners, the suite, links, smoke test and secret scan passed; the bundles are
`cloak-0.1.0-linux-amd64.tar.gz` 8,053,596 bytes and `cloak-0.1.0-linux-arm64.tar.gz`
7,816,605 bytes; the publish job made a draft pre-release with `SHA256SUMS`, and
`gh attestation verify` binds each bundle to `release.yml` at `refs/tags/v0.1.0`, `a3a9cab`.

**The macOS half, on the maintainer's Mac.** `tool/release/macos.sh` from the clean tag:
the suite and every check, signed as `Developer ID Application: Werkswinkel Pte Ltd
(32XLPKQ5TF)`, `cloak-0.1.0-macos-arm64.dmg` 9,563,872 bytes as uploaded, notarization
`Accepted` (submission `1d96dfba-e6bb-4688-ae9a-891816799e98`), stapled, assessed
`Notarized Developer ID`; copied out of a quarantined copy, `cloak --version` printed
`cloak 0.1.0 (a3a9cab...)`. It added the image to the draft and rewrote `SHA256SUMS`, and
everything downloaded from the draft checks against it.

Open: the draft is unpublished; `install.sh` and the README's install section on clean
machines (tasks 6.1, 6.4, 7.2); the timings of task 7.1.

## 14. Headers from a CDN first (2026-09-25)

A BSV node drops a connection after about 200,000 headers, so filling an empty store from
peers alone was slow on testnet and does not finish on mainnet. libspiffy 3.0.0 already
seeds a store from a CDN before it starts P2P (overnode_v2 does this): it downloads 50,000
headers per chunk and checks each chunk against the manifest's SHA-256, genesis or the
stored tip, `prevBlock` links and proof of work before writing it. cloak had never passed it
a URL. It now passes `chain.cdn`, which defaults to `https://headers.overnode.net` on mainnet
and testnet and is `none` on regtest. That host serves testnet only for now (1,719,437
headers, generated 2026-02-18); mainnet returns 404 until its manifest is published.

**A failed CDN is said.** libspiffy's fallback to peers is correct but silent: the reason
goes to a log warning, and a peer sync from an empty store looks like a hang. cloak prints
one progress line per chunk, and a `fallbackToP2P` phase prints a line with the URL, the
reason (taken from libspiffy's `CdnHeaderSyncService` warning, the only place it is given)
and `chain.cdn: none` as the way to stop trying. That line is printed however the start
ends: the first live mainnet run found a start that then failed for its peers, where the
refusal named only the peers. A URL that is not https is refused when the config is read,
because libspiffy's own check throws inside the start and is only logged.

**Asked once.** A store seeded from the CDN gets a `chain/cdn` file (the URL and the height),
and later starts do not ask the CDN. Otherwise every command that starts the chain would
make a request to a third party, and wait out a 30-second timeout whenever the CDN is down,
which would break the 2 s warm-start bound. A seed that failed leaves no file, so the next
start tries again.

**Trust.** Proof of work makes a forged mainnet chain impractical. Testnet allows
minimum-difficulty blocks, so a malicious CDN could make up a testnet chain cheaply;
testnet coins are worth nothing.

**Tested** by a CDN over https on this machine with mined regtest headers, through the real
libspiffy: a seed, no request once seeded, a missing manifest, a damaged chunk, and a start
that fails for its peers after the CDN did.

**Live, 2026-09-25.** An empty testnet store took all 1,719,437 headers from
`headers.overnode.net` in 36 progress lines and a few minutes; the store was 635 MB. Mainnet
said `Failed to fetch manifest: HTTP 404`. Both starts were then refused because libspiffy's
P2P could not connect to its one default seed (`testnet-seed.bitcoinsv.io:18333`,
`seed.bitcoinsv.io:8333`), although both accept TCP. That failure is libspiffy's and was
there before this change. A refused start does not mark the store; the next start finds no
chunks left to fetch and marks it.

## 15. Peers from every seed address, and the tip they agree on (2026-09-25)

The refused starts of section 14 were libspiffy's. It dialled a DNS seed as one `host:port`,
reaching whichever address the resolver listed first, and on 2026-09-25 two of
`testnet-seed.bitcoinsv.io`'s four nodes accepted a connection and never answered a version
handshake. Probed by hand, the seeds bitcoin-sv ships answered as follows: testnet
`testnet-seed.bitcoinsv.io` 2 of 4, `testnet-seed.bitcoinseed.directory` 0 of 2,
`testnet-seed.bitcoincloud.net` no records; mainnet `seed.bitcoinsv.io` 2 of 3,
`seed.satoshisvision.network` 1 of 2 (stuck at height 413,551), `seed.bitcoinseed.directory`
0 of 6. TAAL publishes no seed. GorillaPool's `testnet.gorillapool.io` and
`seed.gorillapool.io` are testnet nodes; `testnet-seed.gorillapool.io` resolves to private
addresses.

libspiffy 3.0.1, taken on the person's decision to fix it there and publish: every address
of every seed is dialled, the start goes on at the first that answers, the error names each
address and why, the seeds are the node's own plus GorillaPool's testnet nodes, and header
sync asks the peer that reported the highest height. A warm testnet start went from 19 s
(every dial waited out) to 4 s under `dart run`, of which P2P is about 0.5 s.

**The wait for the tip.** A chain start answered once its store had not moved for 750 ms.
After a CDN seed that is before the first peer's headers arrive, so the first live testnet
run answered at the CDN's 1,719,437 while the network was at 1,759,882, and a command would
have taken 40,000 blocks of history as the tip. The start now also waits while the store is
below the height its peers agreed on in their handshakes (`spiffyNodeBridge.currentHeight`),
within the same 60 s bound. From an empty store, testnet answered at 1,759,883 after 137 s:
the CDN, then the rest from peers.

**Found in spiffynode 1.1.0, not fixed:** a message with no payload is completed only when
more bytes follow it (`processData` loops while its buffer is non-empty), so a peer that
ended its handshake with a bare `verack` would time out. Real nodes send more after it; the
loopback test node in libspiffy sends a `ping`.

## 16. v0.1.1 built (2026-09-25)

The CDN seed (section 14) and libspiffy 3.0.1 (section 15), released by `docs/RELEASING.md`.
`v0.1.1` (annotated) on `a3946ad`, whose `ci` run `36123867480` was green. Release run
`36125740312` passed and made the draft with `cloak-0.1.1-linux-amd64.tar.gz` 8,085,622
bytes and `cloak-0.1.1-linux-arm64.tar.gz` 7,844,211 bytes; `gh attestation verify` binds
both to `release.yml` at `refs/tags/v0.1.1`, `a3946ad`.

**macOS.** `tool/release/macos.sh` from a clean worktree of the tag: suite 166 passed, 13
skipped; signed as `Developer ID Application: Werkswinkel Pte Ltd (32XLPKQ5TF)`; notarization
`Accepted` (submission `a4b240a2-62a5-4d42-bf1d-ced6bd6e0895`); stapled; the quarantined
program printed `cloak 0.1.1 (a3946ad...)`. `cloak-0.1.1-macos-arm64.dmg` is 9,599,401 bytes
as uploaded, and assesses as `Notarized Developer ID`. All three files check against the
draft's `SHA256SUMS` as downloaded.

**What went wrong: a checkout's path length.** The first two attempts failed in the build
hook before anything was built. tstokenlib 2.1.0's prebuilt `libstark_kernels` for
macos_arm64 was linked with 56 bytes to spare after its load commands, and Dart's hook
renames the library to its absolute path under `.dart_tool/lib`, so that path can be at
most 87 characters: the checkout's own path at most 38. `~/IdeaProjects/agentic/cloak-cli`
is 86 characters in all and fits; the worktree `.../cloak-v0.1.1` (89) did not, and neither
did the scratchpad. The release was built from `.../c011`. The fix belongs in tstokenlib:
link the published macOS libraries with `-headerpad_max_install_names`.

**Published** on the person's word as a full release, not a pre-release, and marked latest,
before steps 6 and 8. The draft had been made a pre-release, which `/releases/latest` skips,
so `install.sh` kept installing 0.1.0 until it was published this way. Afterwards the
published `install.sh`, run into an empty home directory, installed `cloak 0.1.1
(a3946ad...)`.

Open: the localnet end-to-end run against the signed program (step 6) and the clean
machines (step 8).

## 17. A pool that could not be asked (2026-09-25)

The first `cloak sync` from 0.1.1 on a new testnet wallet fetched its headers and was then
refused at "catch-up": "the pool does not serve catch-up (... the frame was not stored:
Exception: Failed to dial: Exception: No addresses found for peer: <the ricochet server>)".
Two faults.

**The transport forgot the server.** `sync` opens the transport before it starts the chain,
and a first chain start is minutes of CDN and peers with the connection idle. dart_libp2p
2.0.0 closes an idle connection about a minute after its last use and, although the server's
address was added for an hour and the peer is protected, the address book no longer held it
afterwards (probed against the pool's server: connected with one address at 60 s,
disconnected with none at 90 s), so the next stream had nothing to dial. The address comes
from `config.yaml` and is always right, so the transport gives it again before every
stream. `localnet_transport_test` closes the connection and clears the address as libp2p
does, and the next request is answered; without the fix it fails with the error above. Why
dart_libp2p drops a protected peer's address is its own bug, not fixed here.

**The refusal blamed the pool.** libcloak reports every transport failure at the step
`transport`, and `sync` took that step as a pool that does not serve catch-up, sending a
person to `--from-genesis`. That reading is right for silence from a pool that was asked
and wrong for a frame the server never took. The transport now says when its last frame
was not stored (`PoolMailbox.unreachable`), and `sync` then refuses at "transport": "the
pool could not be asked: <why>. Nothing was learned about the pool; ...".

## 18. v0.1.2 built (2026-09-25)

Section 17's fix, released by `docs/RELEASING.md`. `v0.1.2` (annotated) on `3886117`, whose
`ci` run `36130024827` was green. Release run `36131348024` passed:
`cloak-0.1.2-linux-amd64.tar.gz` 8,085,083 bytes, `cloak-0.1.2-linux-arm64.tar.gz`
7,844,761 bytes, both attested to `release.yml` at `refs/tags/v0.1.2`. `tool/release/macos.sh`
from a clean worktree of the tag at `../c012` (section 16's path limit): suite 167 passed, 14
skipped; notarization `Accepted` (submission `90e8398f-ba30-4713-aaea-4722019833ab`);
`cloak-0.1.2-macos-arm64.dmg` 9,598,905 bytes as uploaded, `Notarized Developer ID`; the
quarantined program printed `cloak 0.1.2 (3886117...)`. All three files check against
`SHA256SUMS` as downloaded. Published as a full release and marked latest; `install.sh` into
an empty home directory installed `cloak 0.1.2`.

Open, as for 0.1.1: the localnet end-to-end run against the signed program (step 6) and the
clean machines (step 8).

## 19. BEEF is handed over as hex (2026-09-25)

`cloak receive` read its file as raw BEEF bytes. Nobody has those: a wallet, an explorer or
ARC hands BEEF over as hex, and the first person to receive a payment pasted the hex into a
file and was refused at "Invalid BEEF version: expected 100beef, got 30313030", the
characters `0100` read as bytes. Converting the file with `xxd -r -p` was the only way in,
and that is not a step to ask of anyone. The person's call: hex only, typed on the command
line or in a file. `cloak receive <arg>` reads the file when `arg` names one, and otherwise
takes `arg` as the hex; spaces and line breaks are ignored, either case of digit is taken,
and a file that is not hex (raw bytes included) is refused naming the first character that
is not a hex digit. A file is bounded before it is read by twice the pool's per-transaction
bound plus room for line breaks, and the hex by the same bound once its spaces are gone.

## 20. BEEF by txid (2026-09-25)

`cloak receive --txid <txid>` asks a BEEF service (`beef.url`, default
`https://beef.xn--nda.network`, which answers `{"beef": "<hex>"}` for mainnet and testnet
alike, or `{"error": ...}`) for one transaction's BEEF. The answer is bounded by the largest
BEEF taken, must hold the transaction asked for, and is then the same hex path as a pasted
BEEF: shape, then its merkle proof against this wallet's own headers. A plaintext URL is
refused except on this machine, where the tests serve one.

**The rule this does not break.** README rule 1 had said `cloak` never asks the network about
a transaction of yours, and that was read as ruling this out. The rule is libspiffy's
(`spv-understanding.md`): the wallet does not manufacture state it cannot evidence. It does
not monitor addresses or scan blocks, does not follow transactions it is not a party to, and
takes no proof on a service's word. Fetching, at the person's request, evidence that is then
checked against the wallet's own headers is none of those. Rule 1 now says what the rule is.
