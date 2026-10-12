# Agent Bank contracts

The small set of custom Solidity contracts behind [Agent Bank](https://github.com/bank-of-an-agent),
a non-custodial bank for AI agents: escrow, payment streams, time-locked vaults, an on-chain
spending-limit hook, and owner-installed top-up and treasury-sweep executors.

[![contracts-ci](https://github.com/bank-of-an-agent/contracts/actions/workflows/ci.yml/badge.svg)](https://github.com/bank-of-an-agent/contracts/actions/workflows/ci.yml)
![Solidity 0.8.30](https://img.shields.io/badge/solidity-0.8.30-363636)
![Foundry](https://img.shields.io/badge/built%20with-Foundry-orange)
![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue)

> [!IMPORTANT]
> Pre-release and **unaudited**. Testnet only: the deploy script refuses Base mainnet. Two
> independent audits are planned before any mainnet beta ([audit scope](AUDIT_SCOPE.md)).

## About

Every agent in Agent Bank owns an ERC-7579 smart account (a Safe with the Safe7579 adapter). Its
owner key belongs to the human or company behind the agent; the agent holds a short-lived session
key; Agent Bank holds a co-signing key that can refuse a payment but never make one.

These contracts add what an agent account needs beyond a wallet, without giving Agent Bank any
power over funds: **no contract has an owner, admin, upgrade path or withdraw function.** The
only bank-adjacent role is a pause guardian that can block *new* deposits and never releases,
refunds, withdrawals or exits.

| Contract | Kind | What it does |
| --- | --- | --- |
| [`AgentEscrow`](src/AgentEscrow.sol) | Singleton | Lock funds for a task; release by payer or arbiter, or by an ERC-8004 validator response; refund on expiry; dispute and resolve; a dispute timeout guarantees funds can never be stuck |
| [`PaymentStreams`](src/PaymentStreams.sol) | Singleton | Pre-funded per-second streams and recurring payments: `accrued = min(deposit, floor(elapsed / interval) × amountPerInterval)`; anyone can settle, only the payer can top up or cancel |
| [`TimeLockVaults`](src/TimeLockVaults.sol) | Singleton | Savings vaults whose funds only ever return to the parent account: after the unlock date, or earlier with the owner's EIP-712 signature (agents can't withdraw early) |
| [`AgentPolicyHook`](src/AgentPolicyHook.sol) | ERC-7579 hook | Per-token per-transaction and per-UTC-day caps across a whole operation (fees included), recipient allowlists, fail-closed on unknown targets |
| [`TopUpExecutor`](src/TopUpExecutor.sol) | ERC-7579 executor | Keeper-triggered refills from the org treasury to its own agent accounts, within owner-set limits |
| [`SweepExecutor`](src/SweepExecutor.sol) | ERC-7579 executor | Owner-directed sweep of excess balance into one allowlisted ERC-4626 fund, redeeming to keep a liquid floor (gated on counsel sign-off in the product) |

Mocks for local work (`MockUSDC` with EIP-3009/EIP-2612 and FiatToken parity, `MockTreasuryFund`,
`MockValidationRegistry`) live in [`src/mocks`](src/mocks) and are never deployed outside Anvil.

## Key results

- **254 tests** (unit, fuzz, invariant) with **100% line, statement, branch and function
  coverage** of `src/`; CI runs fuzzing at 10,000 runs and invariant suites at 1,000 × 200.
- **Phase 0 spike** on a Base Sepolia fork: a deployed Safe can pay an x402 payment through
  ERC-1271, but on-chain caps cannot hold on that path, so agents pay x402 from a per-agent
  **spend key** holding a small float ([report](docs/spike-x402-erc1271.md),
  [ADR 0001](docs/adr/0001-x402-spend-key-float.md)).
- **Guardian recovery** uses Candide's audited SocialRecoveryModule (72-hour delay): fork tests
  show two of three guardians can rotate the owner, Agent Bank alone cannot, and the owner can
  cancel ([ADR 0002](docs/adr/0002-guardian-recovery.md)).

## Requirements

- [Foundry](https://getfoundry.sh) 1.8 or later (`nix shell nixpkgs#foundry` on NixOS)
- Network access to `https://sepolia.base.org` only for fork tests

## Usage

```bash
git clone --recurse-submodules https://github.com/bank-of-an-agent/contracts.git
cd contracts
forge build
forge test                               # unit, fuzz and invariant tests
FOUNDRY_PROFILE=ci forge test            # the CI profile: 10k fuzz runs, 1k × 200 invariants
FOUNDRY_PROFILE=fork forge test -vv      # Base Sepolia fork tests (spike, guardian recovery)
forge coverage --report summary --no-match-coverage '^(test|script)/'
```

Deterministic deployments go through the canonical CREATE2 factory with
`salt = keccak256("agentbank.contracts.v1/<Name>")`; bytecode carries no metadata hash, so only
code changes move addresses. Dry-run against a local Anvil or Base Sepolia:

```bash
anvil &                                                     # local chain
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545
forge script script/Deploy.s.sol --rpc-url https://sepolia.base.org   # simulation only
```

Nothing has been broadcast yet. Choose the `PAUSE_GUARDIAN` before broadcasting; it changes the
escrow, streams and vaults addresses. Deployments are written to `deployments/<chainId>.json`.

## Repository layout

```
src/                contracts, interfaces and mocks
test/unit           unit and fuzz tests per contract
test/invariant      handler-based invariant suites
test/spike          the Phase 0 x402 spike (fork), the cap-bypass reproduction and the spend-key float design
test/fork           Base Sepolia fork test of the guardian recovery module
script/Deploy.s.sol deterministic deployment with mainnet and unknown-chain guards
scripts/export-abis.sh  writes abis/*.json (CI fails if they drift)
abis/               ABIs consumed by the TypeScript and exit-tool packages
```

## How the other repositories use these contracts

- [`agent-bank`](https://github.com/bank-of-an-agent/agent-bank): `packages/chain` copies `abis/`
  (`scripts/sync-abis.sh`) and builds the calls; the API, co-signer and reconciler work from the
  events these contracts emit.
- [`exit-tool`](https://github.com/bank-of-an-agent/exit-tool): refunds expired escrows, cancels
  streams and withdraws vaults when an owner leaves without Agent Bank.

## Security

- [AUDIT_SCOPE.md](AUDIT_SCOPE.md): in-scope files, trust assumptions, invariants and how each
  contract upholds "Agent Bank can never move user funds".
- [SECURITY.md](SECURITY.md): report vulnerabilities privately through GitHub security advisories.

## Contributing

Read the [organization contributing guide](https://github.com/bank-of-an-agent/.github/blob/main/CONTRIBUTING.md).
Contract changes need unit, fuzz and invariant tests, must keep coverage at 100%, and must keep
`forge fmt --check`, `forge build --deny warnings`, `forge lint` and the ABI drift check clean.

## License

Apache-2.0. See [LICENSE](LICENSE).
