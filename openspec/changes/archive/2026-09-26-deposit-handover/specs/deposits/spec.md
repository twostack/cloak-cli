## REMOVED Requirements

### Requirement: A deposit is submitted once its covenant is mined
**Reason**: The coordinator (pool-coordinator 0.1.8 and later) takes the covenant unbroadcast, broadcasts it itself and admits it once the network has seen it, so there is nothing to wait for.
**Migration**: Replaced by "A deposit is handed to the coordinator, which broadcasts it". A coordinator that still requires a mined covenant is met by that requirement's fallback, which is this requirement's old flow.

## MODIFIED Requirements

### Requirement: A deposit's worst case is a delay, and the person is told so

The wallet cannot prove in advance that the coordinator will include its deposit. The
program SHALL therefore set a refund height far enough ahead that the next round can
be mined first, SHALL tell the person that height and what it means before the
covenant is handed to the coordinator, and SHALL NOT hand it over without the person's
confirmation unless run with an explicit flag saying to proceed.

#### Scenario: The person is told what they are risking
- **WHEN** `cloak deposit` is run interactively
- **THEN** it SHALL print the amount, the round it is depositing into, the refund
  height, and that the money is recoverable at that height if no round takes it
- **AND** SHALL wait for confirmation before handing the covenant over

#### Scenario: A refund height too close to be included
- **WHEN** a refund height is given that a coordinator would skip because the refund
  opens too soon
- **THEN** the command SHALL refuse naming the height given and the earliest height it
  will accept

## ADDED Requirements

### Requirement: A deposit is handed to the coordinator, which broadcasts it

`cloak deposit` SHALL build and record the covenant and the deposit's transfer, then
submit the transfer with the covenant attached, without broadcasting the covenant
itself, and report the coordinator's answer in the same command. On acceptance the
covenant SHALL be recorded as broadcast and the wallet SHALL ask its transparent side
for the covenant's status, so its coins count as spent and its change is taken in.
When the coordinator refuses because the covenant is not mined (a coordinator from
before this handover), the command SHALL broadcast the covenant itself and leave the
deposit to `cloak sync`, as before. When the coordinator does not answer within the
wallet's reply timeout, the deposit SHALL stay recorded as submitting, and `cloak sync`
and `cloak deposit --submit` SHALL submit it again; a resubmission refused because a
pending transfer already backs the covenant SHALL count as accepted.

#### Scenario: One command against a coordinator that broadcasts
- **WHEN** `cloak deposit` is run against an in-process coordinator that takes
  unbroadcast covenants
- **THEN** the command SHALL report the deposit accepted into the next round, and the
  wallet SHALL have broadcast nothing itself

#### Scenario: A coordinator that wants the covenant mined
- **WHEN** the coordinator refuses the deposit because its covenant is not mined
- **THEN** the command SHALL broadcast the covenant, say that `cloak sync` submits it
  once mined, and a later `cloak sync` after the covenant is mined SHALL submit it

#### Scenario: No answer
- **WHEN** the coordinator does not answer within the reply timeout
- **THEN** `cloak status` SHALL show the deposit as submitting, and the next
  `cloak sync` SHALL submit it again and record the answer

### Requirement: A deposit the coordinator refused costs nothing

When the coordinator refuses a deposit for any reason other than an unmined covenant,
the wallet SHALL give the covenant's coins back only if the network does not know the
covenant, and SHALL tell the person the deposit was refused, why, and that nothing was
spent. If the network does know it, the deposit SHALL stay recorded as broadcast, with
its refund height, so `cloak refund` takes it back.

#### Scenario: Refused and never broadcast
- **WHEN** the coordinator refuses a deposit whose covenant the network does not know
- **THEN** the command SHALL report the refusal and its reason, and `cloak balance`
  SHALL show the covenant's coins spendable again

#### Scenario: Refused after the network saw it
- **WHEN** the coordinator refuses a deposit whose covenant the network knows
- **THEN** the deposit SHALL stay recorded as broadcast with its refund height, and
  `cloak refund` SHALL be the way back
