# Phase 0 spike: x402 "exact" payments signed by a Safe (ERC-1271) on Base Sepolia USDC

| | |
| --- | --- |
| Date | 2026-10-11 |
| Question | Does an x402 `exact` payment (EIP-3009 `transferWithAuthorization`) signed by a Safe smart account through ERC-1271 settle with Base Sepolia USDC? And does the on-chain spending cap still hold on that path? |
| Answer | **It settles.** A deployed Safe can pay through either USDC overload. **But the on-chain hard cap does not hold on this path**, and an undeployed (counterfactual) Safe cannot pay. |
| Decision | Use a per-agent EOA **spend key** holding a small USDC float, refilled by the smart account under policy: [ADR 0001](adr/0001-x402-spend-key-float.md) |
| Tests | [`test/spike/X402SafeErc1271.fork.t.sol`](../test/spike/X402SafeErc1271.fork.t.sol) (Base Sepolia fork, 14 tests); local companions [`Erc1271SpendCapBypass.t.sol`](../test/spike/Erc1271SpendCapBypass.t.sol) (4) and [`SpendKeyFloat.t.sol`](../test/spike/SpendKeyFloat.t.sol) (5). All pass. |

## 1. Method

The test forks Base Sepolia (chain id 84532). It runs at pinned block **47,990,000** (2026-10-11 19:51:28 UTC). I also ran it at chain head (block 47,997,287) with the same results. It uses only contracts that are already deployed:

| Contract | Address | Checked on-chain |
| --- | --- | --- |
| USDC (FiatTokenProxy) | `0x036CbD53842c5426634e7929541eC2318f3dCF7e` | `name()` = "USDC", `version()` = "2", `decimals()` = 6 |
| USDC implementation (FiatToken v2.2) | `0xd74cc5d436923b8ba2c179b4bCA2841D8A52C5B5` | read from the proxy's implementation slot; bytecode dispatches both `0xcf092995` (`bytes signature`) and `0xe3ee160e` (`v,r,s`) |
| USDC `DOMAIN_SEPARATOR()` | `0x71f17a3b…c9818` | equals `keccak256(EIP712Domain("USDC","2",84532,proxy))` |
| SafeProxyFactory v1.4.1 | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` | |
| SafeL2 v1.4.1 singleton (used) | `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` | `VERSION()` = "1.4.1" |
| CompatibilityFallbackHandler v1.4.1 | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` | read from the Safe's fallback-handler slot |

Procedure:

1. **Deploy a Safe.** The test calls `createProxyWithNonce(SafeL2, setup([owner], 1, …, CompatibilityFallbackHandler, …), salt)`. The owner is a test EOA.
2. **Fund it through the real mint path.** The test pranks the USDC `masterMinter()` (`0xD52081E444544C744B3ECbb0dE7fF06e63ef4E1c`) to call `configureMinter(testMinter, max)`, then pranks `testMinter` to call `mint(safe, 1,000 USDC)`. FiatToken v2.2 packs the blacklist bit into the balance slot. The real mint path avoids raw storage writes and keeps `totalSupply` consistent.
3. **Build the x402 payload.** The digest is `keccak256("\x19\x01" ‖ USDC.DOMAIN_SEPARATOR() ‖ hashStruct(TransferWithAuthorization{from: safe, to: seller, value: 1.25 USDC, validAfter: now-1, validBefore: now+5min, nonce}))`.
4. **Produce the Safe ERC-1271 signature.** USDC calls `safe.isValidSignature(digest, sig)`. That call reaches the CompatibilityFallbackHandler, which checks owner signatures over the SafeMessage hash `keccak256(0x19 ‖ 0x01 ‖ safe.domainSeparator() ‖ keccak256(abi.encode(keccak256("SafeMessage(bytes message)"), keccak256(abi.encode(digest)))))`. The owner signs that hash with ECDSA. The test cross-checks the hash against the handler's own `getMessageHashForSafe`, and checks that `isValidSignature` returns `0x1626ba7e`.
5. **Settle from a relayer.** A separate "facilitator" address calls `transferWithAuthorization`. The test tries both overloads, and also a 2-of-3 Safe.
6. **Attack and edge cases.** Replay, a non-owner signature, expiry, not-yet-valid, amount or recipient tampering by the facilitator, a raw-digest signature, and an undeployed counterfactual Safe, both with and without an ERC-6492 wrapper.

Reproduce:

```sh
FOUNDRY_PROFILE=fork forge test -vv                               # pinned block 47,990,000
BASE_SEPOLIA_FORK_BLOCK=0 FOUNDRY_PROFILE=fork forge test -vv     # chain head
BASE_SEPOLIA_RPC_URL=<your-endpoint> FOUNDRY_PROFILE=fork forge test
```

If no RPC is reachable, the suite reports every test as `SKIP` instead of failing. The default profile excludes `*.fork.t.sol`.

## 2. Results

Tooling: forge 1.8.4, solc 0.8.30, EVM cancun. **14 passed, 0 failed, 0 skipped**, both at the pinned block and at head.

| # | Scenario | Outcome | Revert reason / evidence | Exec gas* |
| --- | --- | --- | --- | --- |
| 1 | Environment: USDC is FiatToken v2.2, domain ("USDC","2"), both overloads present | ✅ as expected | implementation slot, `DOMAIN_SEPARATOR`, PUSH4 scan | – |
| 2 | Safe is v1.4.1, 1-of-1, CompatibilityFallbackHandler set, funded 1,000 USDC | ✅ as expected | storage + views | – |
| 3 | **Safe 1-of-1, ERC-1271 signature, `bytes` overload (`0xcf092995`)** | ✅ **settles** | payer −1.25, seller +1.25, supply unchanged, nonce consumed, `AuthorizationUsed` emitted | **131,471** |
| 4 | Safe 1-of-1, 65-byte Safe signature, `v,r,s` overload (`0xe3ee160e`) | ✅ **settles** | FiatToken re-packs `(r,s,v)` and still routes contract signers to ERC-1271 | 130,870 |
| 5 | Safe 2-of-3, 130-byte signature, `bytes` overload | ✅ **settles** | only the `bytes` overload can carry it | 139,262 |
| 5b | Safe 2-of-3 with only one owner signature | ❌ reverts | `FiatTokenV2: invalid signature` | – |
| 6 | Baseline: EOA spend key, `v,r,s` overload | ✅ settles | | **106,009** |
| 6b | EOA spend key tries to sign more than its float | ❌ reverts | `ERC20: transfer amount exceeds balance` (the loss is bounded by the float) | – |
| 7 | Replay the same authorization | ❌ reverts | `FiatTokenV2: authorization is used or canceled` | – |
| 7b | Same nonce, different payload (re-signed) | ❌ reverts | `FiatTokenV2: authorization is used or canceled`. Nonces are per authorizer, not per payload | – |
| 8 | Signature by a non-owner (valid ECDSA over the right SafeMessage) | ❌ reverts | `FiatTokenV2: invalid signature`. The Safe's `checkSignatures` fails inside the 1271 STATICCALL, so USDC sees `false` | – |
| 9 | Owner signs the EIP-3009 digest directly, not the SafeMessage | ❌ reverts | `FiatTokenV2: invalid signature` | – |
| 10 | `validBefore == now`, or settled after `validBefore` | ❌ reverts | `FiatTokenV2: authorization is expired` (`validBefore` is exclusive) | – |
| 11 | `validAfter == now` | ❌ reverts | `FiatTokenV2: authorization is not yet valid` (`validAfter` is exclusive) | – |
| 12 | Facilitator raises the amount or changes the recipient | ❌ reverts | `FiatTokenV2: invalid signature`. The untampered authorization still settles afterwards | – |
| 13a | **Undeployed counterfactual Safe**, plain signature | ❌ **reverts** | `FiatTokenV2: invalid signature`. With no code at `from`, USDC treats it as an EOA and `ecrecover` returns the wrong address | – |
| 13b | Undeployed counterfactual Safe, ERC-6492-wrapped signature | ❌ **reverts** | `ECRecover: invalid signature length`. USDC has no ERC-6492 support | – |
| 13c | Deploy the Safe at the predicted address, then settle the same plain signature | ✅ settles | funds sent to the counterfactual address beforehand were safe and spendable | – |
| 14 | ERC-1271 sees only a digest: sign a 1-unit payment and a 999.999999 USDC "drain" | ✅ both settle | the Safe's balance went to 0. During settlement there were **0 storage writes** to the Safe (`vm.accesses`) and the Safe nonce did not change | – |

\* Execution gas measured inside the test around the `transferWithAuthorization` call on a cold fork. Real transactions add the 21,000 intrinsic gas plus calldata. The Safe ERC-1271 path costs about 25k gas (~24%) more than the EOA path.

### Ecosystem facts that affect the result

- **x402 reference facilitator** (`coinbase/x402` @ `dd927a2`, `typescript/packages/mechanisms/evm/src/exact/facilitator/`):
  - Settlement calls the `(v,r,s)` overload when the signature is exactly 65 bytes, and the `bytes` overload otherwise. Results 4 and 5 show a deployed Safe works on both routes.
  - Off-chain verification uses viem `verifyTypedData` (EOA, ERC-1271 and ERC-6492).
  - For an undeployed wallet, the facilitator deploys it from the ERC-6492 factory data only if `deployERC4337WithEIP6492` is enabled. That flag **defaults to `false`**. Otherwise the payment is rejected as `ErrUndeployedSmartWallet`. On-chain, USDC itself never understands ERC-6492 (result 13b).
- **Smart Sessions** (`erc7579/smartsessions` @ `f5aaf86`), the planned session-key module:
  - ERC-1271 policies implement `I1271Policy.check1271SignedAction(ConfigId, address requestSender, address account, bytes32 hash, bytes signature) external view returns (bool)`.
  - `ERC20SpendingLimitPolicy` is an `IActionPolicy`. It runs only on user-operation executions, never on `isValidSignature`.
- **ERC-8004 Validation Registry** (relevant to the escrow, recorded here for completeness): v2.0.0 is deployed on Base Sepolia at `0x8004Cb1BF31DAf7788923b405b754f57acEB4272`. It is a UUPS proxy.

## 3. Analysis

### 3.1 The mechanics work, with one deployment caveat

A **deployed** Safe can pay any x402 `exact` seller on Base with no changes to USDC or to the facilitator. For a 1-of-1 Safe the facilitator even uses its usual EOA code path, the `(v,r,s)` overload. The relayer pays gas and the Safe needs no ETH. EIP-3009's replay, expiry and binding protections hold as designed (results 7–12).

The caveat: the design gives every account a counterfactual (CREATE2) address so it can receive funds before deployment. Receiving works (13a–13c). **Paying does not, until the Safe is deployed.** Every agent account would have to be deployed before its first x402 payment. Alternatively, Agent Bank's own facilitator could deploy it from ERC-6492 data, which the stock x402 facilitator does not do by default.

### 3.2 The on-chain hard cap does not hold on the ERC-1271 path

Design principle 2 is "limits live in code, not prompts". The design also requires that session-key scope be enforced on-chain, "so limits hold even if the bank's off-chain systems were compromised". On the ERC-1271 path that guarantee does not hold, for three structural reasons:

1. **The account only sees a digest.** `isValidSignature(bytes32 hash, bytes signature)` receives an opaque EIP-712 hash. The token, amount, recipient and deadline are hashed away. Result 14 shows the account vouching identically for a 1-unit payment and for a full drain. Smart Sessions' `I1271Policy.check1271SignedAction` also receives only `bytes32 hash`. ERC-7739 nested typed data can expose the *type* and app domain of what is signed, but not the field values.
2. **The account cannot keep state.** `isValidSignature` is reached through a STATICCALL. Result 14 measured **zero storage writes** to the Safe, and an unchanged Safe nonce, across a full settlement. Even a policy that could decode the amount could not count it toward a daily or monthly cap. `I1271Policy` is declared `view` for the same reason.
3. **The transfer never runs through the account.** The money moves inside `USDC._transfer`. The Safe's `execute` path never runs, so neither the ERC-7579 hook (`AgentPolicyHook`) nor Smart Sessions' `ERC20SpendingLimitPolicy` (an action policy) ever sees the payment.

Consequence: any key that can make the account return `0x1626ba7e` for an arbitrary digest can sign away the **entire balance**. This includes a session key whose scope enables ERC-1271 signing, and a co-signer working together with such a key. The same holds for an EIP-2612 `permit` to an attacker-chosen spender, which is a persistent allowance and worse than a single transfer. USDC's per-authorizer nonces stop *replay*, not *amount*.

**Local reproduction with this repository's own hook.** [`Erc1271SpendCapBypass.t.sol`](../test/spike/Erc1271SpendCapBypass.t.sol) runs against MockUSDC, which has FiatToken's EIP-3009 and EIP-2612 semantics. An agent account runs `AgentPolicyHook` with these settings: 25 USDC per transaction, 200 USDC per day, recipient allowlist on.

- On the execution path, the session key is capped. A transfer to a non-allowlisted address reverts with `RecipientNotAllowed`. A transfer of 10,000 USDC reverts with `PerTxLimitExceeded`.
- Once the account accepts that key's ERC-1271 signatures, two things go through and the hook records **0** spend:
  - an EIP-3009 authorization moves the **entire 10,000 USDC** to the attacker;
  - an EIP-2612 permit gives the attacker an unlimited allowance.
- Removing the key's ERC-1271 rights makes USDC reject the same signatures with `FiatTokenV2: invalid signature`.

The only bound left on this path is the off-chain co-signer's policy check. That is exactly the bound the design says must not be the last line of defence. **The spike therefore fails the security requirement** even though it passes the mechanical one. By the design doc's rule, this "forces the fallback design".

### 3.3 Alternatives considered

| Option | Verdict |
| --- | --- |
| A. Let session keys sign ERC-1271 for x402 and rely on the co-signer | ❌ No on-chain cap. A co-signer compromise combined with a session-key compromise drains the whole account. Violates the non-negotiable "limits hold even if the bank's off-chain systems were compromised". |
| B. A custom stateless ERC-1271 policy that requires the full `TransferWithAuthorization` preimage in the signature and checks `value ≤ perTx` and `to ∈ allowlist` | ⚠️ Per-payment cap only. It cannot enforce cumulative caps (the call is a view), needs a custom signature format and a custom audited policy, and still breaks for undeployed accounts. |
| C. Pre-approve each digest on-chain (Safe `signedMessages` or a module that decodes and caps the authorization), then settle with an empty signature | ⚠️ Gives a real on-chain cap, but every x402 payment needs a prior user operation: latency, gas and complexity. It removes x402's main advantage (gasless, instant authorizations). |
| D. **Per-agent EOA spend key holding a small float**, refilled from the smart account under session + co-signer + on-chain hook caps | ✅ **Recommended.** Standard EIP-3009 that every facilitator supports (result 6, the cheapest path at 106k gas). The worst-case loss from a leaked spend key is the float (result 6b). Refills are ordinary account executions, so the on-chain caps apply to the cumulative x402 spend. |

## 4. Recommendation (decision recorded in ADR 0001)

Adopt **Option D**. Requirements that follow from the spike:

1. **No ERC-1271 for agents.** Agent session configurations must not enable ERC-1271 signing (no Smart Sessions `erc1271Policies` and no ERC-7739 contents for agent sessions). Otherwise the bypass in 3.2 comes back through EIP-3009 or EIP-2612 `permit`. This needs an explicit Phase 2 test.
2. **Spend key.** One EOA per agent, generated client-side by the SDK next to the session key, and never held by Agent Bank. It signs standard EIP-3009 authorizations. Floats are small: the beta cap is per account, and a float of about one day of expected x402 spend (for example ≤ 25 USDC) is suggested.
3. **Refill.** The smart account transfers USDC to the spend key as a normal user operation. That user operation passes Smart Sessions scope (spending limit), the co-signer's policy, and `AgentPolicyHook` (spend key on the recipient allowlist, per-transaction and daily caps). Cumulative x402 spend is therefore hard-capped on-chain, at the refill.
4. **Float recovery.** At provisioning, the spend key signs an EIP-2612 `permit` that gives the parent account an allowance. The owner's exit tool can then sweep a float back with `transferFrom(spendKey → account)` without the agent runtime. `AgentPolicyHook` classifies that pull as an inflow.
5. **Deployment.** Deploy agent accounts before first use. Ideally do it at account creation, sponsored by the paymaster. This matters for any future smart-account-signed flows. The spend-key design itself is unaffected.
6. **Ledger and indexer.** Model the spend key as part of the agent's account set (for example `pocket:x402-float`). A refill is an internal movement. Each x402 payment is reconciled from the spend key's USDC `Transfer` and `AuthorizationUsed` events.

**Reference flow.** [`SpendKeyFloat.t.sol`](../test/spike/SpendKeyFloat.t.sol) exercises Option D end to end with this repository's contracts:

- **Standard payment.** The spend key signs an EIP-3009 authorization; the facilitator settles it through the `(v,r,s)` overload.
- **Refill caps.** Refills pass the on-chain cap of 25 USDC per transaction and 100 USDC per day. The fifth refill of the day reverts with `DailyLimitExceeded`, so daily x402 spend is bounded on-chain.
- **Refill recipient.** A refill can only go to the spend key.
- **Leaked key.** A leaked spend key loses exactly its float. It cannot sign for the account and has no allowance from it.
- **Recovery.** The owner sweeps the float back through the provisioning-time permit allowance, without the agent.

## 5. Open questions for human sign-off

- **Gate decision.** The design doc says to stop and ask when the spike "fails or forces the fallback design". This spike forces the fallback. ADR 0001 is recorded as Accepted at the orchestrator's instruction, and the Phase 0 gate report should present it for explicit sign-off.
- **Custody and counsel.** A spend key can move its float alone. That is non-custodial only as long as **the principal's side** (agent runtime or SDK) holds it. If Agent Bank ever hosts agent runtimes, for example remote MCP agents, Agent Bank would hold keys that move funds. Counsel must review that before any hosted offering.
- **Float sizing and beta cap.** How the per-agent float relates to the $1,000 per-account beta cap: is the float counted inside it?
