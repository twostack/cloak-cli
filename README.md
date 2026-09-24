# cloak

A command-line wallet for the TSL1_SP shielded pool: receive BSV, put it into the pool,
pay people out of it, prove you paid, and take money back out.

`cloak` is a host. It wires two libraries together and adds nothing of its own to
either side of the ledger:

```
libspiffy   the transparent side: BEEF in, coins, signing, broadcast, the header chain
    |
  cloak     a HeaderSource, a Transport, a config file, a wallet directory, the commands
    |
libcloak    the shielded side: keys, notes, invoices, payments, proofs, the journal
```

The pool itself, its protocol and its deposit covenant come from `tstokenlib`. The pipe
to the pool's coordinator is `ricochet`: the wallet's only network connection is to one
ricochet server, and the coordinator is only ever an address on it.

## The rule it is built under

People pay people. A payment is made in consideration of something, so it is delivered
with its proof over the channel the payer and payee already have. `cloak` scans no chain
and makes no request that names an address, a txid or an outpoint of the wallet's. The
single exception will be restoring a wallet from its seed, where there is nobody to ask,
and that is not built yet.

Nothing is taken on trust either. Everything the pool says is checked against a round
this wallet proved off the chain with its own headers, so the coordinator is a server
and never an authority.

## The commands

| command | what it does |
|---|---|
| `cloak init` | makes a wallet and prints its seed once, on standard output, with nothing beside it |
| `cloak unlock` | checks the passphrase opens the wallet, and says what it holds |
| `cloak address` | issues a fresh pool address; `--transparent` a fresh transparent one |
| `cloak status` | the wallet directory and where its name came from, every file and whether it is encrypted, the formats this build reads, and what is pending |
| `cloak sync` | brings the pool view to the pool's tip and checks it; submits any deposit whose covenant is now mined |
| `cloak invoice new` | an invoice for an amount, to a fresh address, written to a file |
| `cloak invoice show` | reads and checks an invoice somebody handed you |
| `cloak pay` | pays an invoice out of one note this wallet holds |
| `cloak proof` | the payment proof for an invoice this wallet paid (waiting on the coordinator; see below) |
| `cloak check` | checks a payment proof against this wallet's own headers, and takes the note |
| `cloak ack` | acknowledges a payment you checked; `--check` checks one you were sent |
| `cloak balance` | spendable, reserved and stale, per asset, never added up |
| `cloak notes` | every note held, its leaf, round, value and state |
| `cloak journal` | the record of what was issued, paid, proved and acknowledged; `--invoice <id>` for one thread |
| `cloak receive` | takes a BEEF payment another person handed you |
| `cloak deposit` | puts BSV into the pool behind the deposit covenant |
| `cloak refund` | takes back a deposit no round took in, at its refund height |
| `cloak withdraw` | takes BSV out of the pool to a transparent address |

Every command accepts `--json` and prints one JSON object with the same facts. Exit
codes are 0 done, 1 refused, 2 malformed. A refusal names the rule that failed, in the
library's own words: `cloak check: refused at "PP1 is this pool's script": ...`.

The wallet directory is `--wallet <dir>`, else `$CLOAK_WALLET`, else `~/.cloak`.

The passphrase is typed at a prompt with echo off, or read from `$CLOAK_PASSPHRASE` for a
script. It is never an argument: every process on the machine can read another's
arguments. ARC's API key, where one is needed, is `$CLOAK_ARC_API_KEY`.

### A deposit is two steps

A deposit locks coins to a covenant naming the live round, and nothing can prove in
advance that the next round will take it in. So `cloak deposit` prints the amount, the
round, the refund height and what it means, and waits for you to confirm. If no round
takes the deposit in, `cloak refund` takes it back in full from that height, with
nobody's cooperation.

The coordinator takes a deposit only once its covenant is mined. `cloak deposit`
broadcasts the covenant and returns; the next `cloak sync` (or `cloak deposit --submit`)
submits it once it is mined. `cloak status` shows it waiting in between.

Deposits and withdrawals are public. The amount and the transparent side are on the chain
for anyone to read, and `cloak` says so before doing either.

## What to back up

**The whole wallet directory.** The seed alone is not yet enough.

| file | what it is | encrypted |
|---|---|---|
| `wallet.enc` | the seed and the address counter, under the passphrase | yes |
| `notes.store` | each note's opening, including its randomness | **no** |
| `pool.view` | the pool view: which leaves are this wallet's, and their paths | no |
| `journal/` | the record of every payment | no |
| `state.json` | the pool's descriptor, invoices issued, payments and deposits in flight | no |
| `keys.enc` | the transparent side's mnemonic and each deposit's refund key, sealed by the seed | yes |
| `identity.seed` | the key this wallet talks to the pool as; losing it costs only replies already sent | no |
| `chain/` | libspiffy's database: public block headers, and the transparent wallet's coins and transactions | no |

Until restoring from a seed exists, a person who keeps the seed and loses `notes.store`
has lost the money in it. The note store is not encrypted, by libcloak's design, so that
two stores holding the same notes are byte-identical; protect it beyond its permissions.

## Not here yet

- **Restoring from a seed.**
- **A wallet that caught up past one of its own rounds by the published runs.** A leaf's
  path above its block needs the pool's frontier as of that round, which `cloak sync` keeps
  when it folds through the round. A wallet that skipped it would need the coordinator to
  serve a frontier as of a past round, which it has offered to add.

## Running the compiled binary

`dart compile exe bin/cloak.dart` builds it. A deposit, a payment and a withdrawal encrypt
their notes with ML-KEM, which runs in tstokenlib's native kernels and has no Dart
fallback. A program run from the source tree finds them beside tstokenlib; a compiled one
has no source tree to look in, so it is told where the library is:

```
STARK_KERNELS_LIB=/path/to/libstark_kernels.dylib cloak deposit --amount 5000
```

The library is built by `cargo build --release --manifest-path native/stark_kernels/Cargo.toml`
in `../tstokenlib`. Without it, those commands refuse naming the build command.

## The suite

```
dart test                                         the suite, against a fake pool
dart test -P perf                                 the timing bounds, one file at a time
POOL_LOCALNET=1 dart test                         adds runs against ../localnet: a real
                                                  ricochet server, the real header chain
POOL_LOCALNET=1 dart test -P perf                 adds localnet's timing bounds
POOL_LOCALNET=1 POOL_E2E=1 dart test -t e2e       a real coordinator, end to end, driving
                                                  the compiled binary
```

The localnet runs need `../localnet` up (the node, and ARC on port 9090) and a built
`../go-ricochet/ricochet`; the end-to-end run also needs tstokenlib's native kernels built. The timing
bounds are bounds on one core, measured best-of-N: in the default pack every test file runs
at once, and a reading of 50 ms becomes 150, which is a fact about the pack and not about
the wallet. So they are asked for on their own.

## The record

`docs/DESIGN.md` is the running record, appended in dated sections: what was built, what
was measured, on which machine, and what was decided against. The plan is the OpenSpec
change `cloak-cli` under `openspec/changes/`.
