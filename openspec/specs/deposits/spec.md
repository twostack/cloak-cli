## Purpose

How money gets into the pool and back out: receiving BSV from another person over
BEEF, locking it behind the pool's deposit covenant, learning the note's leaf from the
round that took the receipt, taking back a deposit no round took in, and withdrawing a
note to a transparent address.

## Requirements

### Requirement: BSV arrives from a person, never by scanning

`cloak receive` SHALL take a BEEF payment another person hands over, validate its
merkle proof against block headers from the wallet's own source, and take the outputs
on. The program SHALL NOT discover incoming money by scanning the chain, by querying
an indexer, or by asking anyone about an address of the wallet's.

#### Scenario: A payment whose block the wallet has not reached
- **WHEN** a BEEF payment naming a block above the wallet's chain tip is received
- **THEN** it SHALL be parked, naming the height it waits for, and taken on once the
  chain reaches it
- **AND** the command SHALL NOT request that specific block

#### Scenario: A payment with a bad merkle proof
- **WHEN** a BEEF payment whose merkle proof does not check against the header at its
  height is received
- **THEN** it SHALL be refused naming the check, and no output SHALL be taken on

#### Scenario: Mutated BEEF never crashes the wallet
- **WHEN** a thousand BEEF payments, each valid with one byte mutated or truncated,
  are offered
- **THEN** every one SHALL produce a named refusal, and none SHALL throw

### Requirement: A deposit is locked to the pool's live successor

`cloak deposit` SHALL build a deposit covenant naming the outpoint of the live pool's
PP3 as the announced round carries it, so the deposit can only be taken in by the next
round. It SHALL refuse to build one against a round the wallet has not both folded and
checked, naming the round folded to and the round checked to.

#### Scenario: Depositing against an unchecked view
- **WHEN** `cloak deposit` is run while the pool view's folded round is ahead of its
  checked round
- **THEN** the command SHALL refuse naming both rounds and SHALL NOT spend anything

#### Scenario: The covenant names the round the wallet checked
- **WHEN** a deposit is built against a checked round
- **THEN** the covenant's named outpoint SHALL be that round's transaction with the
  output index the pool's PP3 occupies

### Requirement: A deposit's worst case is a delay, and the person is told so

The wallet cannot prove in advance that the coordinator will include its deposit. The
program SHALL therefore set a refund height far enough ahead that the next round can
be mined first, SHALL tell the person that height and what it means before the deposit
is broadcast, and SHALL NOT broadcast without the person's confirmation unless run
with an explicit flag saying to proceed.

#### Scenario: The person is told what they are risking
- **WHEN** `cloak deposit` is run interactively
- **THEN** it SHALL print the amount, the round it is depositing into, the refund
  height, and that the money is recoverable at that height if no round takes it
- **AND** SHALL wait for confirmation before broadcasting

#### Scenario: A refund height too close to be included
- **WHEN** a refund height is given that a coordinator would skip because the refund
  opens too soon
- **THEN** the command SHALL refuse naming the height given and the earliest height it
  will accept

### Requirement: A deposit is submitted once its covenant is mined

The coordinator takes a deposit only when its covenant is mined and unspent. `cloak
deposit` SHALL build, record and broadcast the covenant and return, without waiting for
it to be mined. The deposit's transfer SHALL be submitted, with the covenant attached, by
a later `cloak sync` or `cloak deposit --submit` once this wallet's own chain holds the
covenant mined. Until it is submitted, `cloak status` SHALL show the deposit waiting,
naming the covenant and its refund height.

#### Scenario: Submitted once mined
- **WHEN** a deposit's covenant has been broadcast and is not yet mined
- **THEN** `cloak status` SHALL list the deposit as waiting for its covenant
- **AND** once the covenant is mined, the next `cloak sync` SHALL submit the deposit's
  transfer and record the coordinator's answer

### Requirement: A deposit is a transfer with no real input

The transfer backing a deposit SHALL spend two dummy notes, bring money in, and carry
the depositor's note as its first output. It SHALL NOT spend a real note beside the
deposit, because a deposit is public and a real input beside it would name the
depositor as the owner of an earlier note.

#### Scenario: The transfer's shape is checked before it is sent
- **WHEN** a deposit transfer is built
- **THEN** its own shape check SHALL pass with both inputs dummy, the asset BSV, and
  money coming in
- **AND** a transfer built with a real input beside a deposit SHALL be refused naming
  the rule

### Requirement: A deposit becomes a spendable note only from a mined round

The deposit's note SHALL be taken into the note store only once the round that carried
its receipt has been mined and the wallet has found the note's commitment in it. Until
then the deposit SHALL be shown as pending, with the round it is waiting for.

#### Scenario: Pending until mined
- **WHEN** a deposit has been accepted by the coordinator but its round is not yet
  mined
- **THEN** `cloak status` SHALL list it as pending naming the round
- **AND** `cloak balance` SHALL NOT count it as spendable

#### Scenario: Taken on when the round arrives
- **WHEN** the round carrying the receipt is mined
- **THEN** the note SHALL be taken into the store at the leaf the round placed it at,
  and SHALL be spendable once the view is checked to that round

### Requirement: A deposit no round took is refunded

`cloak refund` SHALL build and broadcast the refund of a deposit covenant whose round
never took it in, at or after the covenant's refund height. It SHALL refuse before
that height, naming the height and the chain tip.

#### Scenario: Refunding too early
- **WHEN** `cloak refund` is run before the covenant's refund height
- **THEN** it SHALL refuse naming the refund height and the current tip

#### Scenario: Refunding a deposit that was taken in
- **WHEN** `cloak refund` is run for a deposit whose covenant output has been spent by
  a round
- **THEN** it SHALL refuse naming the outpoint and that it is already spent, and SHALL
  NOT broadcast

### Requirement: A withdrawal pays a transparent address out of a note

`cloak withdraw` SHALL build a transfer spending a note this wallet holds, taking BSV
out to a transparent address the person names, with the withdrawal record the transfer
must carry naming exactly the amount taken out. Change SHALL return as a note to a
fresh address of the wallet's.

#### Scenario: The withdrawal and the public amount agree
- **WHEN** a withdrawal transfer is built
- **THEN** the amount its withdrawal record names SHALL equal the amount its proof
  takes out
- **AND** a transfer where they differ SHALL be refused naming both

#### Scenario: Withdrawing more than the note holds
- **WHEN** an amount above the chosen note's value is asked for
- **THEN** the command SHALL refuse naming the amount asked and the note's value, and
  SHALL NOT compute a proof

### Requirement: Transparent and shielded sides never share an address

No address used on the transparent side SHALL be derived from a pool key, and no pool
address SHALL be derived from a transparent key. A withdrawal's destination and a
deposit's change SHALL each be a fresh address.

#### Scenario: Fresh addresses each time
- **WHEN** two deposits and two withdrawals are made
- **THEN** the four transparent addresses involved SHALL all differ

#### Scenario: The two key trees are unrelated
- **WHEN** the wallet's transparent addresses and its pool addresses are compared
- **THEN** neither SHALL be computable from the other

### Requirement: A deposit and a withdrawal are public, and the person is told

A deposit names an amount and a transparent source on the chain, and a withdrawal
names an amount and a transparent destination. The program SHALL say so before doing
either, because a person who believes these are private would be wrong.

#### Scenario: The warning is shown
- **WHEN** `cloak deposit` or `cloak withdraw` is run interactively
- **THEN** it SHALL state that the amount and the transparent side of the transaction
  are public

### Requirement: Spending the transparent side is atomic with recording it

A deposit or withdrawal SHALL record its own transaction in durable state before it is
broadcast, so a broadcast that succeeds while the program dies leaves a record the
next run can find and follow. A recorded-but-unbroadcast transaction SHALL be shown by
`cloak status`.

#### Scenario: Killed between recording and broadcasting
- **WHEN** the process is killed after the deposit is recorded and before it is
  broadcast
- **THEN** the next `cloak status` SHALL show it as recorded and not broadcast
- **AND** a command SHALL exist to broadcast it without rebuilding it

#### Scenario: Killed after broadcasting
- **WHEN** the process is killed after broadcast and before the reply is recorded
- **THEN** the next run SHALL find the record and SHALL NOT build a second deposit
  spending the same funding outpoint

### Requirement: Transactions are refused, not guessed at

Every transaction and BEEF payment read from another party SHALL be bounded and
version-checked before it is parsed, and refused naming the field that stopped it.

#### Scenario: An over-long deposit transaction
- **WHEN** a deposit transaction larger than the pool protocol permits in a submission
  is built or received
- **THEN** it SHALL be refused naming both sizes

### Requirement: These commands stay inside their bounds

Building a deposit, excluding the spend proof and the network, SHALL take under 500 ms;
so SHALL building a withdrawal. Validating a received BEEF payment of ten inputs SHALL
take under 1 second. All measured on the machine the suite records as best-of-N.

#### Scenario: Building a deposit inside the bound
- **WHEN** a deposit is built against the fixture pool and its phases are timed
- **THEN** the time outside the spend proof and outside the network SHALL be under
  500 ms
