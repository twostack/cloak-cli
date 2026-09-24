# cloak

A command-line wallet for the TSL1_SP shielded pool. With it you can take BSV in, put it
into the pool, pay people privately out of the pool, prove that you paid, and take money
back out to an ordinary address.

```
cloak invoice new --amount 1200 --memo "a crate of oranges" --out oranges.invoice
cloak pay oranges.invoice
cloak proof --invoice 3f9a… --out oranges.proof
```

**Contents**

1. [How it works](#how-it-works)
2. [Installing](#installing)
3. [Your first wallet](#your-first-wallet)
4. [Getting paid](#getting-paid)
5. [Paying someone](#paying-someone)
6. [Money in and out of the pool](#money-in-and-out-of-the-pool)
7. [The commands](#the-commands)
8. [Command reference](#command-reference)
9. [Configuration](#configuration)
10. [Output, exit codes and scripting](#output-exit-codes-and-scripting)
11. [What to back up](#what-to-back-up)
12. [When a command refuses](#when-a-command-refuses)
13. [Not here yet](#not-here-yet)
14. [For developers](#for-developers)

## How it works

`cloak` holds money in two places:

- **The transparent side**: ordinary BSV at ordinary addresses, visible on the chain. This is
  how money enters and leaves the pool.
- **The pool**: notes inside the shielded pool. A note says who owns how much, and nobody
  reading the chain can tell which note is whose or who paid whom.

A pool is run by a **coordinator**, which gathers everyone's transfers into **rounds** and
puts each round on the chain. You reach the coordinator through a **ricochet server**, a
store-and-forward relay. The ricochet server is the only machine on the network your wallet
talks to about the pool.

```
libspiffy   the transparent side: coins, signing, broadcast, and the chain's block headers
    |
  cloak     the commands, the wallet directory, the config file, the pipe to the pool
    |
libcloak    the pool side: keys, notes, invoices, payments, proofs, the journal
```

Two rules shape everything `cloak` does:

1. **People pay people, and hand each other the paperwork.** An invoice, a payment proof and
   an acknowledgement are files. You send them to the other person over whatever channel you
   already share: email, a chat, a USB stick. `cloak` never looks anything up on the chain on
   your behalf, and never asks the network about an address, a transaction or an output of
   yours. That is what keeps your payments private.
2. **Nothing is taken on trust.** Your wallet follows the chain's block headers itself.
   Everything the coordinator says is checked against a round your wallet proved from those
   headers, so a coordinator that lies is refused, not followed.

## Installing

Each release on [GitHub](https://github.com/twostack/cloak-cli/releases) carries a bundle for
each platform, with the program and the two native libraries it needs (tstokenlib's kernels,
for ML-KEM, and Isar's, for the header store). Nothing is downloaded when `cloak` runs.

**Platforms:** macOS 14 or later on Apple silicon; Linux on x86_64 or aarch64 with glibc 2.35
or later (Ubuntu 22.04, Debian 12, Fedora 36 and their successors). Intel Macs and Windows
are not built for. Releases are `0.x` pre-releases: a seed alone cannot yet restore a
wallet (see [What to back up](#what-to-back-up)).

### With the install script

```
curl -fsSL https://raw.githubusercontent.com/twostack/cloak-cli/main/install.sh | sh
```

It picks the bundle for your machine (on macOS, the disk image), checks it against the
release's `SHA256SUMS`, unpacks it into `~/.local/share/cloak/<version>/` and links `~/.local/bin/cloak` to it, with no
`sudo`. It says so if `~/.local/bin` is not on your `PATH`. `sh install.sh --version 0.1.0`
installs a given version. If the download fails or does not match its checksum, nothing is
installed and what you had is left as it was.

### On macOS, from the disk image

Download `cloak-<version>-macos-arm64.dmg` from the release and open it. It holds one folder,
`cloak-<version>-macos-arm64`; copy it somewhere of yours and link the program onto your
path:

```
mkdir -p ~/.local/share/cloak ~/.local/bin
cp -R "/Volumes/cloak 0.1.0/cloak-0.1.0-macos-arm64" ~/.local/share/cloak/0.1.0
ln -sf ~/.local/share/cloak/0.1.0/bin/cloak ~/.local/bin/cloak
```

The image is signed with the Developer ID of Werkswinkel Pte Ltd and notarized by Apple,
with Apple's ticket stapled to it, so macOS runs the program without a warning, offline
too. To check it yourself:

```
spctl --assess --type open --context context:primary-signature -v cloak-0.1.0-macos-arm64.dmg
```

which should say `accepted` and `source=Notarized Developer ID`.

### On Linux, by hand

Download `cloak-<version>-linux-<arch>.tar.gz` and `SHA256SUMS` from the release, then check
the bundle before unpacking it:

```
sha256sum -c SHA256SUMS --ignore-missing
gh attestation verify cloak-0.1.0-linux-amd64.tar.gz --repo twostack/cloak-cli
```

The first says the file is the one the release lists (it works for the disk image too, with
`shasum -a 256 -c` on macOS); the second, that GitHub's release workflow built it from this
repository at the release's tag. Then:

```
tar -xzf cloak-0.1.0-linux-amd64.tar.gz -C ~/.local/share/cloak
ln -sf ~/.local/share/cloak/cloak-0.1.0-linux-amd64/bin/cloak ~/.local/bin/cloak
```

Run the program through a link or by its path, and keep `bin/` and `lib/` together: it finds
its libraries in `lib/` beside its own `bin/`, following links, whatever directory you run it
from. `cloak status` says where it found them.

### Upgrading and removing

Run the install script again. Each version keeps its own directory
and only the link moves, so the previous version is still there to go back to.

`sh install.sh --uninstall` removes the program. Neither ever
opens, reads or removes a wallet: `~/.cloak`, or wherever `CLOAK_WALLET` points, stays as it
is, and the uninstaller says where it is.

### Building from source

You need the Dart SDK, 3.10 or later. The libraries come from pub.dev at the versions
`pubspec.lock` pins; to work against checkouts beside this one instead, copy
`pubspec_overrides.yaml.example` to `pubspec_overrides.yaml`.

```
dart pub get
dart build cli -o build/cli
build/cli/bundle/bin/cloak --version
```

tstokenlib's build hook puts its kernels library in `build/cli/bundle/lib/`: the prebuilt one
published for its crate, checked against the SHA-256 the package pins, or, where none is
published, one built from the crate with cargo (so a Rust toolchain helps). `dart compile exe`
cannot build a program whose dependencies have build hooks. A binary built this way is a
development build: `cloak --version` says so, and it finds Isar's library the way Isar does,
by downloading it on first use. `tool/release/` builds a bundle the way a release is built.

## Your first wallet

**1. Make the wallet.** You need the address of the pool's ricochet server and the
coordinator's peer id; whoever runs the pool publishes both.

```
cloak init --network testnet \
  --server /ip4/203.0.113.7/udp/4001/udx/p2p/12D3KooW… \
  --pool 12D3KooW…
```

You are asked for a passphrase twice. The seed is printed once, as a single line on standard
output, with everything else on standard error. Write it down on paper, somewhere the
passphrase is not, and do not save it in a file beside the wallet. The wallet lives in
`~/.cloak` unless you pass `--wallet <dir>` or set `CLOAK_WALLET`.

If you leave out `--server` and `--pool`, set them later in `config.yaml` in the wallet
directory (see [Configuration](#configuration)).

**2. Follow the pool.**

```
cloak sync --from-genesis
```

The first sync reads the pool's descriptor and starts following the chain's headers, which
can take a minute on a new machine. `--from-genesis` is only for this first sync of a pool
that is still young; later syncs are just `cloak sync`.

**3. Take BSV in.** Get a transparent address and have someone pay it:

```
cloak address --transparent
```

The person paying you hands you the payment as a BEEF file (the transaction with its merkle
proof). Take it in:

```
cloak receive payment.beef
```

`cloak` checks the merkle proof against your own headers. If the payment's block is newer
than your wallet's chain, it is parked and taken in once the chain reaches it; nothing asks
the network for that block.

**4. Put it into the pool.** See [Depositing](#depositing). Once a round has taken your
deposit in, `cloak balance` shows it as spendable.

## Getting paid

**1. Issue an invoice**, for an amount in satoshis, to a fresh address of yours:

```
cloak invoice new --amount 1200 --expires 7d --memo "a crate of oranges" --out oranges.invoice
```

Send `oranges.invoice` to the person paying you.

**2. Check their proof.** When they have paid, they send you a proof file:

```
cloak sync
cloak check oranges.proof
```

`cloak check` proves the payment against your own headers, confirms it pays your invoice, and
takes the note into your wallet. If it says the payment's block is newer than your chain,
run `cloak sync` and check again.

**3. Acknowledge it**, and send the acknowledgement back as their receipt:

```
cloak ack oranges.proof --out oranges.ack
```

## Paying someone

**1. Read the invoice** you were sent. This checks it belongs to your pool, has not expired
and is signed by its issuer:

```
cloak invoice show oranges.invoice
```

**2. Pay it:**

```
cloak pay oranges.invoice
```

A payment is made out of **one** note, so it needs a single note at least as large as the
invoice; `cloak balance` shows your largest. The note is reserved before anything is sent,
so two payments can never pick the same note. If the pool does not answer in time, the
payment is recorded as unanswered and the note stays reserved: it may already be in a
round. The next `cloak sync` settles it either way.

**3. Wait for the round, then make the proof.** Once the round holding your payment is mined:

```
cloak sync
cloak proof --invoice 3f9a… --out oranges.proof
```

The invoice id is printed by `cloak pay` and `cloak invoice show`, and listed by
`cloak journal`. Send `oranges.proof` to the payee. `--short` makes a smaller proof for a
payee whose wallet follows the pool too.

**4. Check their acknowledgement** when it comes back:

```
cloak ack --check oranges.ack --invoice 3f9a…
```

Your change comes back to a fresh address of yours in the same round, and the sync that
reads the round takes it in.

## Money in and out of the pool

Deposits and withdrawals happen on the chain in the open: the amount and the transparent
address or coins involved are public. `cloak` says so, and asks you to confirm, before
either one.

### Depositing

```
cloak sync
cloak deposit --amount 5000
```

A deposit locks coins from your transparent side to a **covenant** naming the pool's current
round. Nothing can promise in advance that the next round will take it in, so before
anything is broadcast `cloak deposit` prints the amount, the round, and the **refund
height**: the block from which you can take the money back yourself if no round takes it.
Type `y` to go ahead, or pass `--yes` in a script. `--refund-height <block>` picks another
refund height; it must be at least `refund_minimum` blocks ahead, because a coordinator
skips a deposit whose refund opens too soon.

A deposit is two steps. The coordinator only takes a deposit once its covenant is mined, so
`cloak deposit` broadcasts the covenant and returns. Then:

```
cloak sync               # submits the deposit once its covenant is mined
cloak sync               # later: reads the round that took it in; the note is spendable
```

`cloak deposit --submit` does only the submitting. `cloak status` shows a deposit that is
waiting.

### Refunding a deposit

If no round took a deposit in, take it back at its refund height, with nobody's cooperation:

```
cloak refund --deposit <covenant txid>
```

Before the refund height it refuses and names the height. A deposit a round has already
taken in cannot be refunded; its money is a note in your wallet.

### Withdrawing

```
cloak withdraw --amount 1000 --to mzJ9…
```

The amount is paid to that transparent address by the next round, out of one of your notes,
with the change back to you inside the pool. As with a payment, `cloak sync` reads the round
afterwards.

## The commands

| command | what it does |
|---|---|
| `cloak init` | makes a wallet and prints its seed once, on standard output, with nothing beside it |
| `cloak unlock` | checks the passphrase opens the wallet, and says what it holds |
| `cloak address` | issues a fresh pool address; `--transparent` a fresh transparent one |
| `cloak status` | the wallet directory and where its name came from, every file and whether it is encrypted, the formats this build reads, and what is pending |
| `cloak sync` | brings the pool view to the pool's tip and checks it; settles payments and deposits whose rounds are mined; submits deposits whose covenant is mined |
| `cloak invoice new` | an invoice for an amount, to a fresh address, written to a file |
| `cloak invoice show` | reads and checks an invoice somebody handed you |
| `cloak pay` | pays an invoice out of one note this wallet holds |
| `cloak proof` | the payment proof for an invoice this wallet paid, once its round is read |
| `cloak check` | checks a payment proof against this wallet's own headers, and takes the note |
| `cloak ack` | acknowledges a payment you checked; `--check` checks one you were sent |
| `cloak balance` | spendable, reserved and stale, per asset, never added up |
| `cloak notes` | every note held, its leaf, round, value and state |
| `cloak journal` | the record of what was issued, paid, proved and acknowledged; `--invoice <id>` for one thread |
| `cloak receive` | takes a BEEF payment another person handed you |
| `cloak deposit` | puts BSV into the pool behind the deposit covenant |
| `cloak refund` | takes back a deposit no round took in, at its refund height |
| `cloak withdraw` | takes BSV out of the pool to a transparent address |

`cloak --help` lists them, and `cloak <command> --help` gives a command's options.

## Command reference

Options every command takes: `--wallet <dir>`, `--json`, and `-v` / `--verbose` (see
[Output](#output-exit-codes-and-scripting)).

### init

`cloak init [--network regtest|testnet|mainnet] [--server <multiaddr>] [--pool <peer id>]`

Makes a new wallet in the wallet directory, which must not already hold one. The network
defaults to `testnet`. `--server` is the ricochet server's multiaddr, ending in
`/p2p/<peer id>`; `--pool` is the coordinator's peer id.

### unlock

`cloak unlock`

Checks the passphrase opens the wallet file, and prints its key derivation, its birthday
round and how many addresses it has issued. Changes nothing.

### address

`cloak address [--transparent]`

A fresh pool address, never issued before. With `--transparent`, a fresh transparent BSV
address for taking coins in. You rarely need a pool address yourself: `cloak invoice new`
issues one per invoice.

### status

`cloak status`

The wallet directory and whether it came from `--wallet`, `CLOAK_WALLET` or the default;
each file, its size and whether it is encrypted; the file formats this build reads; where
the two native libraries are and whether each is there; the pool's descriptor; the pool
view's round; and anything pending (deposits waiting, payments unanswered). Needs no
passphrase, loads no library and touches no network.

### sync

`cloak sync [--from-genesis]`

Brings the pool view up to the pool's latest round and checks it against a round proved
from your own headers. Along the way it:

- settles answers to payments that went unanswered;
- reads each mined round something of yours was in: marks spent notes spent, takes in your
  change and deposited notes, and keeps the proof of each payment you made for
  `cloak proof`;
- releases the note of a transfer the pool dropped;
- submits deposits whose covenant is now mined.

It asks for the passphrase only when something needs settling. `--from-genesis` folds the
pool's whole history, for a new wallet on a young pool.

### invoice new

`cloak invoice new --amount <satoshis> --out <file> [--expires <duration>] [--memo <text>]`

`--expires` takes `30m`, `24h`, `7d` or a UTC time, and defaults to `24h`. The memo is at
most 512 bytes. The invoice goes to a fresh address and is recorded, so a proof that pays it
can be matched later.

### invoice show

`cloak invoice show <file>`

Reads an invoice and checks it: that it is for this wallet's pool, that it has not expired,
and that its signature holds. Prints the amount, the expiry and the memo.

### pay

`cloak pay <invoice file>`

Pays the invoice out of one note. Prints the invoice id, the note it is paid from, the
change, the submission id and the pool's answer: `accepted` into a round, `refused` with the
pool's reason (the note is released), or unanswered (the note stays reserved until
`cloak sync` settles it).

### proof

`cloak proof --invoice <id> --out <file> [--short]`

The proof that you paid invoice `<id>`, made from the mined round your payment is in. It is
available once `cloak sync` has read that round. The default, standing proof lets anyone
check it against the chain's headers alone; `--short` is smaller, for a payee whose wallet
follows the pool.

### check

`cloak check <proof file>`

Checks a proof: that its round is mined in a block on your chain with enough confirmations
(`chain.confirmations`), that the round is this pool's, and that it pays one of your
invoices. Then takes the note into your wallet. Prints the value, the round and the
confirmations.

### ack

`cloak ack <proof file> --out <file>`
`cloak ack --check <acknowledgement file> --invoice <id>`

The first acknowledges a payment you checked, made with the key your invoice was issued
under and dated by the block the payment was mined in. The second, used by the payer, checks an acknowledgement
against the invoice you paid, and records it in the journal.

### balance

`cloak balance`

Per asset, three lines that are never added together:

- **spendable**, and the largest single note, since a payment comes out of one note;
- **reserved**: notes held for a payment or withdrawal still in flight;
- **stale**: notes you hold but cannot spend until `cloak sync` brings the view closer to
  the pool's tip.

Reads only local files: no passphrase, no network.

### notes

`cloak notes`

Every note: its leaf position, the round it was made in, its value, and its state:
`proven` (yours to spend), `reserved` (held for a payment or withdrawal in flight) or
`spent`. A proven note the view cannot spend yet is marked stale, with the reason.

### journal

`cloak journal [--invoice <id>]`

The record of each invoice's life: issued or received, paid, submitted, answered, proved,
checked, acknowledged. `--invoice` shows one thread.

### receive

`cloak receive <BEEF file>`

Takes a BEEF payment to one of your transparent addresses. The file is checked for shape
before anything else sees it, then its merkle proof is checked against your headers. A
payment whose block your chain has not reached is parked, and the height it waits for is
printed.

### deposit

`cloak deposit --amount <satoshis> [--refund-height <block>] [--yes]`
`cloak deposit --submit`
`cloak deposit --broadcast <txid>`

Builds the deposit, has the transparent side fund and sign the covenant, records both, and
broadcasts the covenant. `--submit` submits deposits whose covenant is mined, and does
nothing else. `--broadcast` sends a recorded covenant again without rebuilding it, for when
the first broadcast failed. Needs a pool view that is checked up to its latest round: run
`cloak sync` first.

### refund

`cloak refund --deposit <covenant txid>`
`cloak refund --broadcast <txid>`

From the refund height on, spends the deposit covenant with the refund key only this wallet
holds, back to a fresh transparent address of yours, less the fee. The refund is recorded
before it is broadcast; `--broadcast <txid>` sends a recorded refund again.

### withdraw

`cloak withdraw --amount <satoshis> --to <address> [--yes]`

Pays `<amount>` out of the pool to a transparent address by the next round. Prints a warning
that the amount and the address will be public, and asks before sending unless `--yes` is
given.

## Configuration

`config.yaml` in the wallet directory, written by `cloak init`. Nothing in it is secret.

```yaml
version: 1
network: testnet              # regtest, testnet or mainnet
pool:
  server: /ip4/203.0.113.7/udp/4001/udx/p2p/12D3KooW…   # the ricochet server
  coordinator: 12D3KooW…      # the coordinator's peer id; its feed is the pool's
  timeout_seconds: 30         # how long to wait for the pool to answer
chain:
  confirmations: 6            # blocks deep before a payment counts, its own block counting as one
  peers: []                   # BSV nodes to take headers from, host:port; empty uses libspiffy's defaults
deposit:
  refund_margin: 144          # blocks ahead a deposit's refund opens at, by default
  refund_minimum: 100         # the fewest blocks ahead it may open at
arc:
  url: ~                      # the ARC broadcast service; empty uses TAAL's for the network
```

**Environment variables:**

| variable | what it is |
|---|---|
| `CLOAK_WALLET` | the wallet directory, when `--wallet` is not given (default `~/.cloak`) |
| `CLOAK_PASSPHRASE` | the passphrase, for scripts; otherwise it is asked for at a prompt with echo off |
| `CLOAK_ARC_API_KEY` | the API key for the ARC service, where one is needed |
| `STARK_KERNELS_LIB` | another kernels library to use instead of the one that came with `cloak` |

The passphrase is never a command-line argument, and `cloak` refuses one given that way:
every process on a machine can read every other's arguments.

## Output, exit codes and scripting

A command prints what it did as plain lines. With `--json` it prints one JSON object with the
same facts instead, on standard output, and nothing else goes there:

```
cloak balance --json
cloak pay oranges.invoice --json | jq -r .submission
```

**Exit codes:** `0` done, `1` refused, `2` the command line was malformed.

When a command refuses, it says which rule stopped it, in the words of the library that
checked it:

```
cloak check: refused at "PP1 is this pool's script": …
```

What completed before the refusal is still printed, so a command that stopped halfway says
how far it got.

`-v` logs what the libraries underneath are doing to standard error, for when something is
slow or unclear.

Only one `cloak` command changes a wallet at a time. A second one waits briefly and then
refuses, naming the process holding the wallet.

## What to back up

**The whole wallet directory.** The seed alone is not yet enough to restore a wallet.

| file | what it is | encrypted |
|---|---|---|
| `wallet.enc` | the seed and the address counter, under the passphrase | yes |
| `notes.store` | each note's opening, including its randomness | **no** |
| `pool.view` | which leaves are this wallet's, and their paths | no |
| `journal/` | the record of every invoice and payment | no |
| `state.json` | the pool's descriptor, invoices issued, payments and deposits in flight | no |
| `keys.enc` | the transparent side's mnemonic and each deposit's refund key, sealed by the seed | yes |
| `identity.seed` | the key this wallet talks to the pool as; losing it costs only replies not yet read | no |
| `proofs/` | the proofs of payments you made, for `cloak proof` | no |
| `chain/` | libspiffy's database: public block headers, and the transparent wallet's coins and transactions | no |
| `config.yaml` | the settings above | no |

Until restoring from a seed exists, keeping the seed but losing `notes.store` loses the money
in it. The note store is not encrypted, by design, so protect the directory beyond its file
permissions: an encrypted disk, and a backup kept apart from the passphrase. `cloak` warns if
the directory's permissions let other users read it.

## When a command refuses

The step named in the refusal tells you where to look. The common ones:

| refused at | what it means, and what to do |
|---|---|
| `config` | the config file is missing or incomplete, often the pool not named yet; edit `config.yaml` |
| `passphrase` | the passphrase does not open the wallet |
| `lock` | another `cloak` command is changing this wallet; wait for it |
| `unchecked` | the pool view is not checked up to its latest round; run `cloak sync` |
| `round` | the wallet has not read the round a command needs; run `cloak sync` |
| `head proof`, `notYet` | the pool has not proved a mined round yet (a new pool, or one between rounds); sync again later |
| `transport`, `no answer` | the ricochet server or the coordinator did not answer; check `pool.server` and try again |
| `refund height` | a refund opens too soon (deposit) or has not opened yet (refund); the block is named |
| `confirmation` | a deposit or withdrawal was not confirmed; nothing was done |
| `BEEF` | a received payment file is not a well-formed BEEF |
| `transparent side`, `funding`, `broadcast` | the transparent wallet or ARC could not do what was asked; the message is theirs |
| `network` | the chain data in the wallet was built for another network than `config.yaml` names |
| `native library` | a library that came with `cloak` is missing, damaged or of another version, and the file is named; reinstall, or fix `STARK_KERNELS_LIB` if you set it |
| `chain` | the header chain could not be started; the message is libspiffy's |

A refusal never leaves money half-spent: a note is reserved before anything is sent, and a
deposit or refund is recorded before it is broadcast, with `--broadcast <txid>` to send it
again.

## Not here yet

- **Restoring from a seed.** Back up the whole directory.
- **An interactive shell.** Each command does one thing and exits.
- **Catching up past a round of your own.** To place a note from an old round, `cloak sync`
  keeps the pool's frontier as it passes that round. A wallet that skipped such a round
  entirely would need the coordinator to serve an old frontier, which it does not yet.

## For developers

```
dart test                                         the suite, against a fake pool
dart test -P perf                                 the timing bounds, one file at a time
POOL_LOCALNET=1 dart test                         adds runs against ../localnet: a real
                                                  ricochet server, the real header chain
POOL_LOCALNET=1 dart test -P perf                 adds localnet's timing bounds
POOL_LOCALNET=1 POOL_E2E=1 dart test -t e2e       a real coordinator, end to end, driving
                                                  the compiled binary
```

The localnet runs need `../localnet` up (the regtest node, and ARC on port 9090) and a built
`../go-ricochet/ricochet`; the end-to-end run also builds and runs the real coordinator from a
pool-coordinator checkout (`../pool-coordinator`, or wherever `POOL_COORDINATOR` points), whose
lock must pin tstokenlib 2.1.0 or later so that its build bundles its own kernels. It is a
program of its own: neither this package nor its tests depend on it. The
timing bounds are bounds on one core: in the default run every test file runs at once, and a
reading of 50 ms becomes 150, which says something about the load and nothing about the
wallet. So they are asked for on their own.

Releases are built by `.github/workflows/release.yml` from a `v<version>` tag, with the
scripts in `tool/release/`; `docs/RELEASING.md` is the checklist.

`docs/DESIGN.md` is the running record of what was built, measured and decided against, in
dated sections. The plan is the OpenSpec change `cloak-cli` under `openspec/changes/`.
