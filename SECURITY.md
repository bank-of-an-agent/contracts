# Security policy

## Status

These contracts are **pre-audit and testnet-only**. They are developed for Base Sepolia (84532) and local Anvil (31337); the deploy script refuses Base mainnet. Do not use them with real funds. See [AUDIT_SCOPE.md](AUDIT_SCOPE.md) for the threat model, invariants and known limitations.

## Reporting a vulnerability

**Please do not open a public issue, discussion or pull request for a security problem.**

Report it privately through GitHub Security Advisories:

1. Open this repository's **Security** tab.
2. Choose **Report a vulnerability**.
3. Fill in the private advisory form. Only the maintainers can see it.

Please include:

- the affected contract(s) and the commit hash;
- a description of the issue and its impact (which funds or which guarantee is at risk);
- a proof of concept, ideally a Foundry test that fails on the current code;
- any suggested fix.

## What to expect

| Step | Target |
| --- | --- |
| Acknowledgement | within 3 business days |
| Initial triage and severity assessment | within 7 days |
| Fix or mitigation plan for high/critical issues | as fast as possible, coordinated with you |
| Public disclosure | coordinated with the reporter; by default 90 days after the report or once a fix ships, whichever is first |

We credit reporters in the advisory unless you prefer to stay anonymous.

## Scope

In scope:

- `src/` except `src/mocks/` (AgentEscrow, PaymentStreams, TimeLockVaults, AgentPolicyHook, SweepExecutor, TopUpExecutor, shared utilities and interfaces);
- `script/Deploy.s.sol`.

Out of scope:

- `src/mocks/` and everything under `test/` (local test fixtures only);
- third-party dependencies (OpenZeppelin, forge-std, Safe, ERC-8004 registries, USDC). Please report those upstream;
- issues already listed as known limitations in [AUDIT_SCOPE.md](AUDIT_SCOPE.md), unless you show they are worse than documented.

Of particular interest:

- any way for Agent Bank, a pause guardian, a keeper, an arbiter or an agent session key to move user funds outside the paths documented in AUDIT_SCOPE.md;
- any way to bypass `AgentPolicyHook` caps or allowlists on the execution path;
- any way to permanently lock funds.

## Safe harbor

Good-faith research is welcome and will not be pursued legally if it:

- is done on local forks or testnets;
- never touches mainnet or other people's funds;
- avoids privacy violations and service disruption;
- gives us reasonable time to fix the issue before you disclose it.

## Bug bounty

A public bug bounty is planned before the closed mainnet beta. It is not live yet.
