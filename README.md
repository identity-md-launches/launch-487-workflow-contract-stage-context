# Milestone contracts

Milestone uses MILE to fund agreements with one to five independently settled milestones.
This deliverable contains the immutable contracts, vendored dependencies, tests, and ABI
exports. Source publication, policy attestations, admission, deployment, reward allocation,
and the IPFS website are performed by the launch services and subsequent workflow stages.
The separate manifest assignment supplies `launch.json`; it is not generated here.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

`foundry.toml` pins Solidity **0.8.26**, Cancun, optimizer enabled with 200 runs, and
`bytecode_hash = "none"`. The verifier provides the pinned compiler. No dependency download,
environment variables, FFI, filesystem cheatcodes, or RPC connection is needed by the tests.
OpenZeppelin Contracts **5.0.2** and forge-std **1.9.7** are ordinary vendored source files
under `lib/`, with upstream licenses and archive hashes in each `VENDORED.md`.

Regenerate the checked-in JSON ABI arrays after source changes:

```sh
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect src/MilestoneEscrow.sol:MilestoneEscrow abi --json > docs/abi/MilestoneEscrow.json
```

## Contracts and deployment parameters

| Artifact | Constructor arguments | Deployment behavior |
| --- | --- | --- |
| `src/LaunchToken.sol:LaunchToken` | None | Mints exactly `1000000000000000000000000000` minor units to its deployment caller. |
| `src/MilestoneEscrow.sol:MilestoneEscrow` | `address token_` | Requires a nonzero address containing code; stores it immutably. Moves no tokens. |

The token name is **Milestone**, symbol **MILE**, decimals **18**, and total supply
**1,000,000,000 MILE**. It is a standard OpenZeppelin ERC-20 without public mint/burn,
ownership, pause, blocklist, fees, or upgrade functionality. Allowances follow standard
ERC-20 behavior, including unchanged maximum allowances.

The launch token is deployed first through ProjectFactory. The factory receives the entire
supply and applies the policy's allocations and market configuration. The application
identifier is `MilestoneEscrow`, with its sole constructor argument set to **`$token`** in
the later manifest. Neither contract needs `$owner`, initialization calls, or deployment
ETH. Both constructors are nonpayable. Deploy the actual `LaunchToken` as the escrow's
currency: the constructor verifies code presence, not token identity. No network address or
privileged wallet is hard-coded.

The service must pin the target network, factory, policy, resulting addresses and accepted
source artifacts, then validate the manifest's token linkage. Policy/signed-artifact linkage
belongs to those services. No deployment transaction or wallet key is part of this work.

## Escrow rules and assumptions

- A funder calls `openEscrow(recipient, arbiter, amounts, deadlines)` after approving the
  escrow for the **full sum** of `amounts`. Funds are pulled only from that caller. A failed
  or short deposit reverts the entire creation, including its ID and allowance changes.
- There must be 1–5 amounts and equally many deadlines. Amounts must be positive MILE minor
  units (`1 MILE = 10^18` units); addition uses checked arithmetic. Each deadline is an
  absolute Unix timestamp in seconds strictly later than the opening block's timestamp.
- Recipient and arbiter must be nonzero and cannot be the escrow contract itself. Parties
  may be contracts, and roles may overlap. The funder chooses these addresses irrevocably;
  the contract does not check real-world identities or require either party's consent.
- Milestones are independent. Deadlines may repeat or appear out of order. Approval of
  one milestone does not depend on progress on another.
- Only the named arbiter can approve a pending milestone, including at the exact deadline.
  **Approval after the deadline is rejected.** This resolves the otherwise ambiguous race
  between late approval and the funder's right to reclaim an unapproved expired milestone.
- Only the recipient can claim an approved milestone. Approval is irrevocable and never
  expires, including after cancellation. Payment always goes to the recorded recipient.
- Only the funder can reclaim a pending milestone, strictly **after** its deadline. Payment
  always goes to the recorded funder. Approved, claimed, or already refunded amounts cannot
  be reclaimed.
- Only the arbiter can cancel an escrow, once. Cancellation immediately refunds **every
  pending** milestone in one atomic transfer to the funder, whether expired or not. Claimed
  and refunded milestones remain settled, and approved milestones remain claimable.
- Cancellation is allowed even when no pending amounts remain; the refund is then zero.
  There are no amendment, role replacement, reopening, or global admin functions.

Milestone states have numeric ABI values: `Pending = 0`, `Approved = 1`, `Claimed = 2`,
`Refunded = 3`. Allowed transitions are:

| Starting state | Action | Ending state | Token movement |
| --- | --- | --- | --- |
| Pending | Arbiter approves on or before deadline | Approved | None |
| Approved | Recipient claims at any later time | Claimed | Amount to recipient |
| Pending | Funder reclaims after deadline | Refunded | Amount to funder |
| Pending | Arbiter cancels the escrow | Refunded | Amount to funder |

`totalAmount` is the original deposit. `remainingAmount` is pending plus approved principal
in that escrow. `totalLocked` sums those outstanding obligations across escrows. Every
successful payout reduces both liability counters; cancellation retains approved liabilities.
Failed transfers revert all state changes. All mutations share a reentrancy guard, and payouts
update state before calling the token. The escrow collects no fee or interest.

## Frontend and ABI handoff

Machine-readable ABIs are in [docs/abi/LaunchToken.json](docs/abi/LaunchToken.json) and
[docs/abi/MilestoneEscrow.json](docs/abi/MilestoneEscrow.json). Query token metadata and
`totalSupply()` from the deployed token; use the service-published deployment addresses.

Escrow IDs are contiguous **1 through `escrowCount()`**; milestone indexes are **0-based**.
`getEscrow(id)` returns the parties, original and remaining amounts, cancellation flag, and
at most five milestone records. `getMilestone(id, index)` returns one record. Unknown IDs
and invalid indexes revert. Fetch IDs in pages off-chain as the number of escrows grows.

| Wallet role | Transaction | UI condition |
| --- | --- | --- |
| Funder opening agreement | Token `approve(escrowAddress, total)`, then `openEscrow(...)` | Valid parties, 1–5 positive amounts, future deadlines, sufficient MILE |
| Arbiter | `approveMilestone(id, index)` | Pending, not cancelled, chain timestamp ≤ deadline |
| Recipient | `claimMilestone(id, index)` | Approved, including cancelled escrows |
| Funder | `reclaimMilestone(id, index)` | Pending, chain timestamp > deadline |
| Arbiter | `cancelEscrow(id)` | Not already cancelled |

Wait for the approval transaction before submitting the deposit. Prefer approval for the
exact intended total. Use chain timestamps, and refresh state after transactions; visible
buttons do not guarantee a transaction will remain valid when mined. Display cancellation
separately from milestone state because a cancelled escrow may still hold approved claims.

Events support indexing: `EscrowOpened`, `MilestoneCreated`, `MilestoneApproved`,
`MilestoneClaimed`, `MilestoneRefunded`, and `EscrowCanceled` (one `l` in the event name).
Cancellation emits individual refund events and an aggregate cancellation event. Read
current contract state to reconcile logs. Custom errors are included in the ABI.

## Custody and operational responsibilities

The funder trusts the chosen arbiter to assess work and decide approval or cancellation.
An arbiter can cancel pending milestones immediately or approve them without proof of work.
The contract enforces payment rights, not the quality of services delivered. If the arbiter
disappears, pending funds become reclaimable after their deadlines. Loss of the recipient's
key can permanently lock approved funds; loss of the funder's key can strand refunds.
There is no recovery authority, pause switch, or upgrade mechanism.

Participants must submit claim/reclaim/cancel transactions and pay network gas. Deadlines do
not trigger automatic settlement. Block inclusion and chain timestamp behavior affect the
deadline boundary; use deadlines with practical time margins.

Only the actual MILE token is supported in production. Fee-on-transfer or rebasing currencies
are not supported; the deposit balance check rejects short deposits, but it cannot make an
arbitrary malicious currency safe. Direct token transfers to the escrow are not deposits and
create no claim. They remain stranded because no sweep/recovery privilege exists. Normal ETH
transfers are rejected, and any forcibly sent ETH likewise has no withdrawal path.

The downstream independent review must inspect the accepted contracts **and** the generated
`launch.json`, including its constructor arguments, before release. Local tests and the
internal source review do not replace that review. The launch services publish source, attest,
admit and deploy the accepted artifacts, and provide the deployment data needed for the IPFS
frontend. Frontend hosting and those later service outcomes are outside this contract assignment.

## Validation coverage

Tests cover ERC-20 supply/metadata/transfers/allowances; input, role and state failures;
deadline boundaries; late claims; mixed-state cancellation; duplicate actions; independent
escrows; fuzzed lifecycle accounting; token failure rollback; callback reentrancy; and
factory-style deployment with runtime-size/forbidden-opcode checks. A stateful invariant suite
checks conserved supply and escrow liabilities through randomized sequences. Tests use no
external chain state. Only Foundry compilation, tests and formatting checks were run; Slither
and Mythril were not run.
