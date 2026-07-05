# SukukZapEscrow

An operator-completed, single-confirm deposit escrow for [SukukFi](https://sukuk.fi)'s duPRT and trUST vaults on Berachain.

**Status: pre-audit draft. Not deployed. Not a professional security audit.** This repo exists to let outside eyes look at the design and code before it goes anywhere near mainnet funds. See [Audit status](#audit-status) below for exactly what review has and hasn't happened.

## What this solves

SukukFi's existing zap flow bridges a user's stablecoins to Berachain, then requires a second, separate signature on Berachain to actually deposit into a vault. This contract removes that second signature: the user signs once on the source chain, sending funds to a CREATE2-derived address computed entirely off-chain (no RPC call needed), and an operator completes the deposit on their behalf once the funds arrive.

## Design

- **`intentAddress(intent)`** predicts a counterfactual address `A` for a given `Intent` (action, user, vaultId, minOut, nonce) — a pure function of the escrow's own address and the intent's encoding, computable by any frontend with zero RPC calls.
- The user's bridge provider (LayerZero OFT, NEAR Intents, or a direct transfer) delivers funds to `A` before any contract exists there.
- **`operatorSettle(intent)`** deploys a tiny `IntentExecutor` at `A` on first touch, sweeps whatever balance is there, and either deposits into the target vault (duPRT) or hands the funds to the operator's own wallet (trUST — see the custody note below for why).
- **`touch(intent)` / `userReclaim(intent)`** give the user (and, after a delay, anyone) a way to get funds back if the operator never settles. Split into two functions deliberately — see the NatSpec on `touch()` in the contract for why a single combined function would deadlock.

Four actions are supported:

| Action | Path |
|---|---|
| 0 — DUPRT | Direct stablecoin deposit into a duPRT vault |
| 1 — TRUST | Direct stablecoin, handed to the operator for a separate trUST deposit |
| 2 — USDE_HONEY_DUPRT | USDe minted to HONEY, then deposited into the duPRT HONEY vault |
| 3 — USDE_HONEY_TRUST | USDe minted to HONEY, then handed to the operator for trUST |

### Custody invariant

For actions 0 and 2, the only two possible outcomes for any intent are a deposit crediting the user, or a refund to the user. No function can move funds anywhere else.

For actions 1 and 3, this invariant does **not** fully hold, by necessity: trUST's vault gates `deposit()` on `msg.sender`, not on the receiver, and this escrow is deliberately never whitelisted (whitelisting it would open a permissionless mint channel for a KYB-gated settlement instrument). The only way to remove the user's second signature for trUST at all is to hand funds to the operator's own whitelisted wallet, which happens as a separate transaction outside this contract. Once that handoff executes, `userReclaim` can no longer help — this is a deliberate, accepted trade-off, documented in the contract itself, not an oversight.

Full design rationale, including the CREATE2 addressing mechanism and why several early designs were rejected, is in the contract's own NatSpec — it's kept there rather than duplicated here so the documentation can't drift from the code.

## Audit status

This contract has **not** had a professional security audit. What it has had:

- Two full passes of an AI-assisted, multi-agent adversarial review (12 independent specialist agents per pass — access control, economic security, execution trace, invariants, periphery, asymmetry, boundary conditions, and cross-cutting gap-hunters), using [Pashov Audit Group's open-source `solidity-auditor` skill](https://github.com/pashov/skills).
- The first pass found 3 confirmed issues; all three were fixed.
- A second pass, run specifically to check whether those fixes held, found that two of the three fixes had real gaps of their own (a griefing vector in the reclaim-timer logic, and a fund-misattribution bug in a refund path), plus one additional issue. All were fixed and independently re-verified.
- 29 Foundry tests cover the custody logic, including regression tests for every finding from both audit passes.

None of this is a substitute for a paid, professional audit. Treat this code as unverified until one happens.

## Build & test

```bash
forge build
forge test -vv
```

No external dependencies — this repo intentionally has none, matching the style of SukukFi's other on-chain contracts. Cheatcodes used in tests are declared directly against Foundry's built-in precompile in `test/Vm.sol` rather than pulling in `forge-std`. One test (`testForkVaultAssetsMatchRealTokens`) forks live Berachain read-only to confirm the real duPRT vaults' `asset()` matches what the contract assumes — it needs network access to `rpc.berachain.com`, a public RPC with no API key required.

## What's not here

- **trUST/HONEY vault addresses are never needed on-chain.** The escrow never calls the trUST (WERC) contracts directly — see the custody note above — so this repo has no dependency on their addresses or ABI.
- **No frontend integration yet.** The `zap.js`/`app.html` wiring to actually compute intents and drive this contract from the browser hasn't been built.
- **No deployment script.** `operator` and `reclaimDelay` are real parameters that need real values decided at deploy time, gated behind the professional audit this repo doesn't yet have.

## License

MIT
