# Audit scope — Agent Bank contracts

Agent Bank is a non-custodial bank for AI agents. Each agent owns an ERC-7579 smart account (a Safe with the Safe7579 adapter). Agent Bank runs off-chain services: a policy engine, a co-signer, keepers and an indexer. **None of these can move user funds.** This repository holds the small set of custom on-chain contracts the bank relies on. This document defines the scope for the two independent audits required by the design (Phase 4 gate).

| | |
| --- | --- |
| Compiler | solc **0.8.30**, EVM **cancun**, optimizer on (10,000 runs), `via_ir = false`, no CBOR metadata (`bytecode_hash = "none"`) |
| Dependencies | OpenZeppelin Contracts **v5.7.0**, forge-std v1.16.2 (tests only) |
| Toolchain | Foundry 1.8.4 |
| Target chains | Base Sepolia (84532) and Anvil (31337). The deploy script refuses Base mainnet (`MAINNET_LOCKED`) and any other chain (`UNSUPPORTED_CHAIN`). |
| Settlement asset | USDC (Circle FiatToken v2.2) |

## 1. In-scope files

| File | nSLOC | Purpose |
| --- | ---: | --- |
| `src/AgentEscrow.sol` | 198 | Singleton multi-escrow. Lock, release by payer or arbiter, ERC-8004 validator release, refund, dispute/resolve, dispute-timeout liveness refund |
| `src/PaymentStreams.sol` | 136 | Pre-funded per-second streams and recurring payments: `accrued = min(deposit, floor(elapsed/interval)·rate)` |
| `src/TimeLockVaults.sol` | 121 | Time-locked savings vaults. Withdrawals only to the parent account; early withdrawal needs the owner's EIP-712 signature |
| `src/AgentPolicyHook.sol` | 329 | ERC-7579 hook (type 4): per-token per-transaction and per-UTC-day caps, allowlists, fail-closed targets |
| `src/SweepExecutor.sol` | 124 | ERC-7579 executor (type 2): owner-directed sweep of excess into an ERC-4626 fund, and redemption to keep a liquid floor |
| `src/TopUpExecutor.sol` | 134 | ERC-7579 executor (type 2): keeper-triggered refills from the org treasury to configured agent accounts |
| `src/utils/GuardianPausable.sol` | 44 | Inflow-only pause guardian |
| `src/utils/TokenTransfer.sol` | 25 | Exact-amount pull and balance-checked push helpers |
| `src/interfaces/*.sol` | 415 | Interfaces, events, errors and types; minimal ERC-7579 and ERC-8004 definitions |
| **Total** | **1,526** | |

**Out of scope:** `src/mocks/*` (MockUSDC, MockTreasuryFund, MockValidationRegistry: local and Anvil fixtures only, never deployed elsewhere), `test/**`, and `script/Deploy.s.sol`. The deploy script's chain guards are tested in `test/script/Deploy.t.sol`.

## 2. The core property: Agent Bank can never move user funds

Design rule: *no contract, admin function or upgrade path may let Agent Bank, or any bank-held key, move user funds.* How the code meets it:

**Global properties of the codebase**

- **No upgradeability.** No proxies, `delegatecall`, `selfdestruct` or initializer patterns. Deployed bytecode is final.
- **No owners or admins.** No `Ownable`, no access-controlled withdraw, rescue, sweep or skim function. Tokens sent to a contract by mistake are stuck forever. That is deliberate: there is no "recover" function that could be abused.
- **One bank-adjacent role: the pause guardian.** It exists on AgentEscrow, PaymentStreams and TimeLockVaults. `whenNotPaused` guards **only** functions that bring new money in: `lock`, `createStream`, `topUp`, `deposit`. It never guards `release`, `releaseByValidation`, `refund`, `dispute`, `resolve`, `settle`, `cancel`, `withdraw`, `withdrawWithSignature` or `setOwner`. The guardian can be rotated or renounced. Renouncing while paused retires the contract for new deposits only. A zero guardian can never act, not even as `msg.sender == address(0)`.
- **The modules hold no funds and grant no bank powers.** They act only on accounts that installed them, are configured only by those accounts, and can only reach destinations the account configured.

**Per contract: where funds can go**

| Contract | Funds can only go to | Who can trigger it | Bank powers |
| --- | --- | --- | --- |
| AgentEscrow | the escrow's **payer** or **payee** | payer and arbiter (release); anyone, if the payer-chosen validator approved before expiry; payee (refund any time); anyone (refund after expiry, or after a dispute timeout); arbiter (split, only between payer and payee) | pause new `lock`s |
| PaymentStreams | the stream's **payee** (accrued amount) or **payer** (remainder) | anyone (`settle`); **payer only** (`cancel`, `topUp`) | pause new streams and top-ups |
| TimeLockVaults | the vault's **parent account** | anyone after `unlockAt`; anyone holding the owner's EIP-712 signature before it | pause deposits |
| AgentPolicyHook | holds nothing; only restricts the account's own executions | — | none |
| SweepExecutor | between the account and the **owner-chosen fund**; shares and redemptions always go to the account | anyone (keeper), within the owner's rule | none |
| TopUpExecutor | from the treasury to **owner-configured agent accounts**, within the owner's daily cap | anyone (keeper), within the owner's rule | none |

The owner's exit path is the Safe's native `execTransaction`. ERC-7579 hooks never see it, so `AgentPolicyHook` can never trap funds. Module management (`installModule` and `uninstallModule`) always passes the hook, and the hook can be uninstalled whatever its state (`test_desyncedHook_failsClosed_butCanAlwaysBeUninstalled`).

## 3. Roles and trust assumptions

| Actor | Trusted for | Not trusted for |
| --- | --- | --- |
| **Account owner** (principal key on the Safe) | Everything about their own account: module installation, hook and executor configuration, vault ownership | — |
| **Agent session key** | Nothing beyond its Smart Sessions scope, and the hook's caps on top of it | Assumed compromised at all times. It must never get ERC-1271 signing rights (§6.1) or permission to call the account itself or install modules (§6.2). |
| **Agent Bank co-signer, keepers, relayers** | Liveness only: triggering sweeps, top-ups, settlements and refunds | Fund movement. They can only trigger owner-defined rules toward owner-defined destinations. |
| **Pause guardian** | Stopping new inflows during an incident | Anything else (see §2) |
| **Escrow arbiter** (chosen per escrow by the payer) | Releasing to the payee, and splitting a disputed escrow between payer and payee | Sending funds anywhere else. A silent arbiter cannot freeze funds past `expiresAt + 30 days`. |
| **ERC-8004 validator** (chosen per escrow by the payer) | Its response can release that escrow to the payee before expiry | Anything else |
| **ERC-8004 Validation Registry** (`0x8004Cb1B…4272` on Base Sepolia; a UUPS proxy) | Reporting validator responses honestly. Its upgrade admin could forge responses, which could release opted-in escrows **to their payees** early. | Payers who do not opt into validation are unaffected. |
| **USDC / FiatToken** (upgradeable; Circle can blacklist and pause) | Standard ERC-20 behaviour. If Circle blacklists an address, payouts to that address are frozen (§6.6); if it blacklists a contract, all funds in it are frozen. | — |
| **ERC-4626 fund** (chosen by the owner for SweepExecutor) | A NAV that cannot be manipulated within one transaction, since sweep and redeem are permissionless (§6.5). Its share accounting is checked by measured deltas. | Minting or paying less than promised (both checked). Losing more than 0.1% to share-price rounding (checked). |
| **Guardian recovery**: Candide SocialRecoveryModule v0.0.1, 72 h variant `0x38275826…541c` (external; audited by Ackee, Nethermind on the Safe-vendored version; Certora specs) | Rotating the Safe owner after 72 h when the guardian threshold confirms. The owner can cancel during the delay, and a guardian can never become an owner. **Agent Bank holds at most one guardian seat, with threshold ≥ 2 and threshold > guardians/2.** That policy is enforced at provisioning and by monitoring, not by the module (ADR 0002; `test/fork/CandideSocialRecovery.fork.t.sol`). | Acting alone: Agent Bank's seat can never reach the threshold. |
| **ERC-7579 account implementation** (Safe7579) | Passing the full `msg.data` to `preCheck`; enforcing that only installed executors can call `executeFromExecutor`; decoding executions per the spec | — |
| **Smart Sessions** (session-key validator; the first on-chain spend layer) | Enforcing the session scope that `AgentPolicyHook` backs up. **Use Smart Sessions V1 at `0x00000000008bDABA…`**, verified by the chain integration package on a Base Sepolia fork. The `0x00000000002B0eCf…` deployment is the pre-V1 beta and must not be used. Agent sessions must have no ERC-1271 policies and no actions targeting the account itself (§6.1, §6.2). | — |
| **ERC-7484 module registry** (Safe7579 `setRegistry`) | Not relied on. The hook and both executors are **not attested** in the module registry. Accounts must therefore disable the registry check before installing them: `setRegistry(address(0), [], 0)`, the chain package's `disableModuleRegistry` step. With the registry off, module vetting rests on the owner and these audits rather than on attestations, and that applies to every module the owner installs later (§6.12). | — |

## 4. Invariants (all tested)

Unit tests check exact behaviour. Fuzz tests check the properties below over random inputs. Handler-based invariant tests check them over random call sequences. The default profile runs 256 runs × 100 depth; the `ci` profile runs 1,000 × 200. Ghost accounting tracks expected state, and in-handler postconditions are recorded as counters rather than asserted, so `fail_on_revert = false` cannot hide them.

| # | Invariant | Where |
| --- | --- | --- |
| E1 | `balanceOf(escrow) == totalLocked[token] + donations ≥ totalLocked[token]` | `AgentEscrow.invariant` · `invariant_balanceCoversLockedFunds` |
| E2 | `totalLocked[token] == Σ amount` over Active and Disputed escrows | `invariant_totalLockedMatchesOpenEscrows` |
| E3 | Every escrow pays out exactly once; terminal statuses never change | `invariant_paidOutExactlyOnceAndTerminalIsFinal` |
| E4 | Funds only move between payers, payees and the escrow; arbiters, validators and third parties never receive anything | `invariant_conservationAndNoLeakage`, `testFuzz_lifecycle_fundsOnlyToPayerOrPayee` |
| E5 | Liveness: an Active escrow is refundable by anyone at `expiresAt`; a Disputed one at `expiresAt + DISPUTE_TIMEOUT` | `test_refund_*`, `testFuzz_refund_thirdPartyOnlyAfterExpiry` |
| S1 | Per stream: `paid + refunded ≤ deposit`, `paid ≤ accrued ≤ deposit` | `PaymentStreams.invariant` · `invariant_perStreamAccounting` |
| S2 | Cancelled streams are frozen: `accrued` stays constant and `refunded == deposit − accrued` | `invariant_perStreamAccounting` |
| S3 | `balanceOf(streams) == Σ outstanding + donations` and `totalOutstanding == Σ outstanding` | `invariant_balanceEqualsSumOfOutstanding` |
| S4 | The accrual formula matches the reference for any parameters; cancel splits the deposit exactly | `testFuzz_accrual_matchesFormula`, `testFuzz_cancel_conservesDeposit` |
| S5 | A frozen payee never traps the payer's refund; a frozen payer never stops the payee's settlement | `test_cancel_blacklisted*`, plus the freeze-toggling handler action |
| S6 | Only the payer ever cancels or tops up a stream: an agent can never be made to fund someone else's stream | `invariant_onlyPayerCancelsOrTopsUp`, `PaymentStreams.t.sol` · `testFuzz_accessControlMatrix` |
| E6 | Access-control matrix (fuzzed callers): `release` payer or arbiter only; `dispute` payer or payee only, before expiry; `resolve` arbiter only; refund before expiry payee only (refunds always go to the payer) | `AgentEscrow.t.sol` · `testFuzz_accessControlMatrix` |
| V1 | `balanceOf(vaults) == totalHeld + donations` and each vault's balance equals deposits − withdrawals | `TimeLockVaults.invariant` · `invariant_accounting` |
| V2 | Withdrawals only ever reach the vault's parent account | `invariant_fundsOnlyReturnToParentAccounts` |
| V3 | No withdrawal before `unlockAt` without the current owner's signature; the owner's signature is always honoured | `invariant_onlyOwnerUnlocksEarly` |
| H1 | Whatever executions an agent submits, committed outflow (transfers, approvals, native value) per token per UTC day is ≤ `maxPerDay` | `AgentPolicyHook.invariant` · `invariant_dailyCapHolds` |
| H2 | The account never loses more than the outflow the policy committed | `invariant_outflowBoundedByCommitted` |
| H3 | With the allowlist on, non-allowlisted addresses receive no funds or allowances, directly or as escrow payees | `invariant_recipientAllowlistHolds` |
| H4 | The agent path can never change the policy | `invariant_policyUnchanged` |
| W1 | After a sweep the liquid balance is ≥ the floor and invested value is ≤ `maxSavingsBps` of total | `SweepExecutor.invariant` · `invariant_rulePostconditions` |
| W2 | Keepers never receive or redirect anything; no allowance lingers; only the account holds fund shares | `invariant_noRedirection` |
| T1 | Every top-up respects the rule in force: only below `whenBelow`, never above `refillTo`, never above `maxPerDay` | `TopUpExecutor.invariant` · `invariant_rulesRespected` |
| T2 | Treasury funds only reach configured agents | `invariant_fundsOnlyToConfiguredAgents` |
| P1 | Exits are never blocked by the pause; only the current guardian toggles it | `GuardianPausable.t.sol` · `invariant_exitsNeverBlocked_onlyGuardianToggles` |

## 5. Design decisions worth reviewing

1. **Escrow `lock` takes a 9th argument, `validationThreshold`** (1..100). It sits between `validationRequestHash` and `termsHash`. A threshold of 0 is rejected when a validator is set, because the ERC-8004 registry exposes no "has responded" flag, so 0 would accept an unanswered request.
2. **Validation release rules.** The registry's `validatorAddress` for the request hash must equal the escrow's validator; this defeats a payee front-running the request with a validator it controls. The latest response must be `≥ threshold`. The response must not predate the escrow (`lastUpdate ≥ createdAt`); this defeats replay of a stale validation. Release only happens while Active and strictly before `expiresAt`, so validation release and the expiry refund are mutually exclusive in time. A dispute suspends the validator path.
3. **Escrow parameter sanity.** The arbiter must differ from payer and payee. The validator must differ from the payee (no self-validation). Expiry must fall within (now, now + 365 days]. Disputes require an arbiter.
4. **Streams.** Accrual is in arrears (nothing is payable before `start + interval`). `start` cannot be in the past. **Only the payer can top up or cancel**: nobody can route funds into someone else's stream, and the payee cannot end a stream. A top-up after a stream ran dry pays the unfunded periods at once (a debt clock). Its payee payout is balance-checked (`tryPushExact`): a token that pays but reports failure cannot cause a double payment, and a token that reports success without paying cannot mark the debt settled.
5. **Vaults.** The owner can never be the parent account. Otherwise any key with ERC-1271 rights on the account, such as a session key, could sign early withdrawals. `MAX_LOCK_DURATION` is 3,650 days. Re-signing `setOwner` for the same owner invalidates outstanding signatures.
6. **Hook config through the hooked path is blocked** (`HookCallBlocked`). The owner configures the hook at install time or through the Safe's native `execTransaction`. Calls with `target == account` are allowed (module management), as the brief requires.
7. **Hook fail-closed target rules.** A call may target only: the account itself; a configured token, with `transfer`, `transferFrom`, `approve`, `increaseAllowance` or `decreaseAllowance`; an allowlisted contract; or an address receiving plain native value. Everything else reverts, including delegatecall, staticcall, custom mode selectors and unknown exec types.
8. **What the hook counts.** Approvals count against caps when granted (an allowance is a future outflow), not when pulled. `transferFrom` into the account counts as an inflow (used to recover a spend-key float). The per-transaction cap applies to the sum of a token's outflows across one hooked execution, single or batch.
9. **SweepExecutor semantics.** A sweep triggers once `liquid − floor ≥ sweepThreshold`. It then subscribes the excess above the floor, capped by `maxSavingsBps` of total value and by `fund.maxDeposit`. Redemption refills the floor (shares rounded up by the fund, capped by `maxRedeem`). Every subscription must keep at least 99.9% of value (`MAX_SUBSCRIPTION_LOSS_BPS = 10`). The fuzzer found that donation/inflation set-ups on near-empty funds otherwise lose value on permissionless sweeps.
10. **TopUpExecutor** (added during Phase 4 at the orchestrator's request). The amount is `min(refillTo − balance, maxPerDay − spentToday, treasuryBalance)`. The agent's received amount is verified by balance delta. Rule changes keep the day's running total.

## 6. Known limitations and residual risks

1. **ERC-1271 bypasses on-chain caps.** EIP-3009 and EIP-2612 pulls authorised through the account's ERC-1271 never pass through the hook. Agent session keys must never get ERC-1271 rights; x402 uses a separate EOA spend key with a small float instead. See the Phase 0 spike (`docs/spike-x402-erc1271.md`), ADR 0001, and `test/spike/Erc1271SpendCapBypass.t.sol`.
2. **The hook is not an access-control layer for account management.** A key that can call the account itself (`installModule`, `uninstallModule`, Safe owner functions) can remove the hook. Validators (Smart Sessions) must never grant self-calls to session keys.
3. **Generic allowlisted contracts are trusted to route funds.** Payee checks exist only for the known Agent Bank kinds (escrow `lock`, streams `createStream`, vault `deposit`). Nested self-executions are each capped separately; the daily cap is the hard bound.
4. **Token assumptions.** Fee-on-transfer tokens and other short-crediting tokens are rejected on every inflow (`TransferAmountMismatch`). Rebasing tokens are unsupported. ERC-777-style hooks are neutralised by `nonReentrant` (transient storage) on every state-changing entry point. Other outflows use `SafeERC20.safeTransfer` and trust the token's accounting.
5. **Donations are unrecoverable.** Tokens sent directly to AgentEscrow, PaymentStreams or TimeLockVaults are never credited to anyone and cannot be withdrawn, since there is no admin.
6. **USDC freezes.** If Circle blacklists a payee, payouts to it revert. The payer keeps the refund paths: escrow refund after expiry, a zero-to-payee `resolve`, or stream `cancel` (the payee's share is deferred, not lost). A frozen payer cannot receive refunds until unfrozen. A frozen contract freezes everything in it.
7. **Dispute griefing.** A party can dispute just before expiry and push the earliest third-party refund to `expiresAt + 30 days`. The arbiter can resolve at any time. Payers choose expiry (capped at 365 days) and arbiters.
8. **Validator downgrade race.** A validator can lower its response after reaching the threshold. Release happens on the first observation that is at or above the threshold.
9. **Fund NAV manipulation.** SweepExecutor bounds rounding loss, but a fund whose price can be moved and restored within one block could still be sandwiched. Owners must select funds with oracle- or NAV-based pricing.
10. **Counterfactual owners.** TimeLockVaults signature checks support EOAs and *deployed* ERC-1271 contracts. ERC-6492 is not supported, and EIP-7702-delegated EOAs are validated through their delegate's ERC-1271.
11. **Validation registry draft.** The ERC-8004 Validation Registry spec is still a draft and the reference registry is upgradeable. If its interface changes, `releaseByValidation` reverts; every other path is unaffected.
12. **Module registry disabled.** Our modules are not attested in the ERC-7484 registry, so accounts install them only after disabling Safe7579's registry check (`disableModuleRegistry`). Until they are attested, and the registry is re-enabled with Agent Bank's attester, Safe7579 does not block an unvetted module the owner installs. The owner's signature is still required for every install.
13. **Recovery policy is off-chain.** Candide's SocialRecoveryModule does not enforce "threshold > n/2" or "Agent Bank holds at most one seat". Provisioning enforces those rules and monitoring alerts on any guardian change that breaks them. The owner can re-configure guardians with their own signature (ADR 0002). The deployed bytecode (v0.0.1) should be checked against Ackee's audited commit during the audit.

## 7. Static analysis

`forge lint` (high, medium and low severities) runs on every build, and CI runs it with `--deny warnings`. Two lints are disabled project-wide in `foundry.toml`, with reasons:

- `block-timestamp`: expiry, accrual, unlocks and daily caps are time-based by design.
- `require-revert-in-loop`: one policy violation must abort a whole batch.

Every other suppression is inline with a justification. They cover:

- `unsafe-typecast`: values bounded by prior checks, and field extraction from the 7579 mode word;
- `reentrancy-events`: the only preceding external calls are STATICCALLs (ERC-1271 checks, registry and vault reads) or measured deltas, and every entry point is `nonReentrant`;
- `unused-return`: executor return data is deliberately not trusted; balances are checked instead;
- `divide-before-multiply`: only whole intervals accrue;
- `calls-loop`, `missing-zero-check`, `mixed-case-function` (`DOMAIN_SEPARATOR`), `empty-block` (`postCheck`).

**Slither 0.11.5** was run with `slither . --filter-paths "lib/|test/|script/|src/mocks/" --exclude-dependencies`. It found 52 results, triaged below. Two earlier findings led to code changes:

- `arbitrary-send-erc20`: `TokenTransfer.pullExact` now always pulls from `msg.sender`.
- `uninitialized-local` in `AgentEscrow.release`: the release reason is now computed after the authorization check.

| Detector (count) | Verdict |
| --- | --- |
| `reentrancy-balance` (6): SweepExecutor `sweep`/`redeem`, TopUpExecutor `topUp` | Intentional. Balances are measured around the account execution to *verify* its effect (shares minted, assets received, amount delivered). All three are `nonReentrant`, and every mismatch reverts (fails closed). |
| `uninitialized-state` (1): `TimeLockVaults._vaults` | False positive. The mapping is written through a `Vault storage` pointer in `createVault`. |
| `incorrect-equality` (14) | Intentional: zero-amount checks, UTC-day bucket comparisons, and exact balance-delta checks in `TokenTransfer`. |
| `unused-return` (5) | Intentional. The registry tuple is partially destructured (unused fields are ignored), and executor and `trySafeTransfer` results are replaced by balance checks. |
| `divide-before-multiply` (1) | Intentional: only whole intervals accrue. |
| `timestamp` (18), `calls-loop` (1), `missing-zero-check` (1, renounce), `assembly` (3), `naming-convention` (2) | Intentional; see above. |

## 8. Tests and how to run them

```sh
forge build --sizes                                                   # all deployables < 12 KB
forge test                                                            # unit + fuzz (1k runs) + invariant (256 x 100)
FOUNDRY_PROFILE=ci forge test                                         # fuzz 10k runs, invariant 1k x 200
FOUNDRY_PROFILE=fork forge test -vv                                   # Base Sepolia fork tests (needs RPC; skips if none)
forge coverage --report summary --no-match-coverage '^(test|script)/' # src/ coverage
```

At the time of writing:

- **254 tests** pass under the default and `ci` profiles: unit, fuzz, 12 invariant suites, deploy-script tests and the local spike companions.
- **21 fork tests** pass on Base Sepolia, both at the pinned block and at chain head: 14 for the x402 spike and 7 for guardian recovery.
- `src/` coverage is **100% of lines, statements, branches and functions**.

## 9. Deployment determinism

`script/Deploy.s.sol` deploys through the canonical CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C` with salt `keccak256("agentbank.contracts.v1/<Name>")`.

- An address depends only on the salt, the creation bytecode and the constructor arguments. Bytecode is pinned by the compiler settings above; with no CBOR metadata, comment and formatting changes do not move addresses.
- AgentPolicyHook, SweepExecutor and TopUpExecutor take no arguments, so they share an address on every chain.
- PaymentStreams and TimeLockVaults also depend on `PAUSE_GUARDIAN`. AgentEscrow additionally depends on the chain's validation registry.
- The script is idempotent: contracts already deployed are skipped. A broadcast writes `deployments/<chainId>.json`.
