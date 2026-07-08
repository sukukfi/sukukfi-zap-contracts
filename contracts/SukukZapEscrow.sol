// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  IERC20
 * @notice Minimal ERC20 interface — only what this contract needs.
 */
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/**
 * @title  IERC7540Vault
 * @notice Minimal ERC-7540 vault interface — only what this contract needs.
 */
interface IERC7540Vault {
    function asset() external view returns (address);
    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId);
}

/**
 * @title  IIntentExecutor
 * @notice Interface for the tiny CREATE2-deployed sweeper below.
 */
interface IIntentExecutor {
    function sweep(address token, address to) external returns (uint256 amount);
}

/**
 * @title  IHoneyFactory
 * @notice Minimal HoneyFactory interface — same signature zap.js already
 *         calls for the existing 2-step flow's USDe→HONEY mint.
 */
interface IHoneyFactory {
    function mint(address asset, uint256 amount, address receiver, bool expectBasketMode) external returns (uint256);
    function isBasketModeEnabled(bool isMint) external view returns (bool);
}

// ── Shared safe-transfer helpers ────────────────────────────────────────────
//
// Free functions (not tied to either contract below) since both IntentExecutor
// and SukukZapEscrow move value and both need the same tolerance. IERC20.transfer
// and IERC20.approve are declared to return bool, so Solidity's ABI decoder
// reverts on zero-length return data — which a non-compliant token (canonical
// USDT and others) returns on success instead of an encoded `true`. Any
// configured asset behaving that way would otherwise revert every call site
// that touches it unconditionally, including IntentExecutor.sweep() (the first
// hop that moves funds out of `A`, used by every settle path AND userReclaim),
// bricking settlement, refunds, and the reclaim escape hatch simultaneously.
// This mirrors OpenZeppelin's SafeERC20 pattern without adding the dependency,
// consistent with this file's existing minimal-interface-only style.

function _safeERC20Call(address token, bytes memory data) {
    (bool success, bytes memory returndata) = token.call(data);
    require(success, "ERC20 call failed");
    if (returndata.length > 0) {
        require(abi.decode(returndata, (bool)), "ERC20 call returned false");
    }
}

function _safeTransfer(address token, address to, uint256 amount) {
    _safeERC20Call(token, abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
}

function _safeApprove(address token, address spender, uint256 amount) {
    _safeERC20Call(token, abi.encodeWithSelector(IERC20.approve.selector, spender, amount));
}

/**
 * @title  IntentExecutor
 * @notice Deployed via CREATE2 at a counterfactual address `A` derived from an
 *         Intent. Both bridge providers (LayerZero OFT, NEAR Intents) deliver
 *         ERC20 tokens to `A` before this contract ever exists there. Once
 *         deployed, `sweep()` forwards whatever balance of a given token sits
 *         at `A` to the deployer (always the SukukZapEscrow that created it).
 *
 *         Deliberately takes no constructor arguments: `deployer` is read from
 *         `msg.sender` at construction, which does not vary the creation
 *         bytecode. Every IntentExecutor ever deployed, for every intent, has
 *         byte-identical creationCode — this is what lets the CREATE2 address
 *         be predicted off-chain with zero RPC calls (constant init code hash).
 *
 *         `sweep()` is callable repeatedly and returns 0 once already drained,
 *         so an early call (before funds arrive) is a safe no-op rather than a
 *         one-shot action that would strand later, real, deliveries.
 */
contract IntentExecutor {
    address public immutable deployer;

    constructor() {
        deployer = msg.sender;
    }

    function sweep(address token, address to) external returns (uint256 amount) {
        require(msg.sender == deployer, "IntentExecutor: only deployer");
        amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) {
            _safeTransfer(token, to, amount);
        }
    }
}

/**
 * @title  SukukZapEscrow
 * @notice Operator-completed single-confirm deposit escrow for SukukFi's duPRT
 *         and trUST vaults. Implements the design locked in
 *         docs/superpowers/specs/2026-06-29-zap-composer-revised.md.
 *
 * Flow:
 *   1. Off-chain (frontend), the user builds an Intent and computes its
 *      counterfactual CREATE2 address `A` via intentAddress(intent) — no
 *      transaction, no RPC call needed once the escrow address and the
 *      IntentExecutor init code hash are known.
 *   2. The user signs exactly once on the source chain, sending funds to `A`
 *      (an OFT.send with `to = A`, or a NEAR Intents deposit with
 *      `recipient = A`). Nothing to sign on Berachain.
 *   3. The operator calls operatorSettle(intent), which dispatches on
 *      intent.action:
 *        - action 0 (DUPRT): sweeps `A`, calls requestDeposit on the target
 *          duPRT vault crediting intent.user. Any failure refunds intent.user.
 *        - action 1 (TRUST): sweeps `A`, hands the funds directly to
 *          `operator` — see the custody note below, this is NOT a completed
 *          deposit.
 *        - action 2 (USDE_HONEY_DUPRT): sweeps USDe, mints HONEY, deposits
 *          the resulting HONEY into the duPRT HONEY vault. Refunds USDe if
 *          minting fails, refunds HONEY if the deposit fails after a
 *          successful mint.
 *        - action 3 (USDE_HONEY_TRUST): same mint step as action 2, then
 *          hands the resulting HONEY to `operator` instead of depositing —
 *          same custody note as action 1.
 *   4. The user (any time) or anyone (after reclaimDelay from first touch)
 *      can call userReclaim(intent) to sweep `A` and return funds to
 *      intent.user instead, if the operator never settles.
 *
 * Custody invariant (duPRT actions 0 and 2 only): for any such intent, the
 * only two possible outcomes are a deposit crediting intent.user, or a refund
 * to intent.user. No function can move funds to any other destination. This
 * contract never issues on its own authority (issuance always happens via
 * requestDeposit, which only queues — the vault's own operator fulfils it,
 * matching Phase 0's finding that requestDeposit is permissionless escrow,
 * not permissionless minting).
 *
 * Custody note for trUST (actions 1 and 3): trUST's WERC vault gates
 * `deposit()` on `msg.sender`, not on the receiver (confirmed live in
 * Phase 0) — this escrow is never whitelisted (whitelisting it would open a
 * permissionless mint channel), so it can never call WERC.deposit() itself.
 * The only way to support trUST at all is this handoff: once
 * operatorSettle hands funds to `operator` for a trUST intent, this
 * contract's custody invariant no longer applies to those funds —
 * userReclaim can no longer help, since the funds have left the contract.
 * The actual WERC.deposit() call happens as a separate transaction from the
 * operator's own whitelisted wallet, entirely outside this contract. This is
 * a deliberate, accepted trade-off (see the Phase 2 build plan), not an
 * oversight — trUST is not receiver-gated on-chain, so this is the only way
 * to remove the user's second signature for that leg at all.
 */
contract SukukZapEscrow {
    // ── Types ────────────────────────────────────────────────────────────────

    struct Intent {
        uint8 action;      // 0=DUPRT, 1=TRUST, 2=USDE_HONEY_DUPRT, 3=USDE_HONEY_TRUST
        address user;      // who gets credited (deposit/handoff) or refunded
        uint8 vaultId;     // index into duprtVaults for actions 0/1; must be HONEY_VAULT_ID for actions 2/3
        uint256 minOut;    // floor on the amount reaching its final destination; below this, refund
        uint256 nonce;     // caller-chosen, makes repeat deposits from the same user distinct
    }

    uint8 public constant ACTION_DUPRT = 0;
    uint8 public constant ACTION_TRUST = 1;
    uint8 public constant ACTION_USDE_HONEY_DUPRT = 2;
    uint8 public constant ACTION_USDE_HONEY_TRUST = 3;
    uint8 public constant HONEY_VAULT_ID = 2;

    // touch()'s arming check for HONEY actions (2/3) observes the pre-mint USDe
    // balance at the intent's address, but i.minOut is denominated in HONEY (the
    // MINTED output — see the honeyAmount < i.minOut checks in _settleHoneyDuprt
    // and _settleHoneyTrust). Because HoneyFactory's mint rate can be sub-100%
    // (see _mintHoneyOrRefund), a raw USDe balance equal to i.minOut can
    // understate how much USDe is actually needed to guarantee i.minOut HONEY
    // out — making it cheaper than intended to arm the reclaim clock on a HONEY
    // intent. This contract has no on-chain way to preview HoneyFactory's exact
    // mint rate (the minimal IHoneyFactory interface exposes no rate-preview
    // function), so this is a conservative, documented safety margin rather
    // than an exact conversion — tune it if HoneyFactory's real worst-case mint
    // efficiency is known precisely. 11_000 = require 110% of i.minOut in raw
    // USDe terms before arming a HONEY intent's clock.
    uint256 public constant HONEY_ARM_BUFFER_BPS = 11_000;

    // Third-party userReclaim only needs to outlast how long the operator's own
    // settlement bot could plausibly be down (crash/redeploy, RPC outage, a
    // botched release) — not any downstream vault fulfillment or trUST minting
    // time, since operatorSettle() already removes the funds from this escrow's
    // custody regardless of action type. The user's own self-reclaim is never
    // gated by this at all (see userReclaim). A deployment with reclaimDelay
    // below this floor would let anyone touch() then userReclaim() an intent
    // in the same block, ahead of any honest operator, repeatedly denying
    // settlement — floor enforced in the constructor below.
    uint256 public constant MIN_RECLAIM_DELAY = 6 hours;

    // ── Storage ──────────────────────────────────────────────────────────────

    address public immutable operator;
    uint256 public immutable reclaimDelay;
    address public immutable honeyFactory;
    address public immutable honey;
    address public immutable usde;

    // vaultId → duPRT ERC-7540 vault address. Fixed at construction; only
    // ever populates the 3 live duPRT vaults. Also used to resolve which
    // stablecoin to sweep for action 1 (TRUST) — the escrow never calls the
    // WERC vaults themselves, so their addresses aren't needed here at all.
    mapping(uint8 => address) public duprtVaults;

    // keccak256(abi.encode(intent)) → timestamp a real (>= minOut) delivery
    // was first observed at that intent's address, written only by touch().
    // Reference point for reclaimDelay. Cleared back to 0 whenever that
    // funding round is fully resolved (settled, handed off, or reclaimed),
    // so a later, independent funding round of the same intent tuple starts
    // its own clock instead of inheriting a stale, already-expired one.
    // 0 = never funded yet, or the last funding round already resolved.
    mapping(bytes32 => uint256) public firstTouchedAt;

    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ── Events ───────────────────────────────────────────────────────────────

    event IntentSettled(address indexed user, address indexed vault, uint256 amount);
    event IntentHandedToOperator(address indexed user, uint8 indexed vaultId, address indexed asset, uint256 amount);
    event IntentRefunded(address indexed user, address indexed asset, uint256 amount);
    event IntentReclaimed(address indexed user, address indexed asset, uint256 amount);

    // Emitted exactly once per funding round, the moment touch() durably arms
    // the reclaim clock (see touch()'s docs). This is the only on-chain signal
    // that an intent has real funds sitting at its CREATE2 address awaiting
    // operatorSettle — nothing else about an intent is observable on-chain
    // before this fires, since intent addresses are counterfactual and never
    // registered anywhere. An off-chain watcher can index this event and alert
    // if operatorSettle hasn't resolved it (via IntentSettled/IntentHandedToOperator)
    // within some operational SLA, without needing any separate intent registry.
    event IntentTouched(bytes32 indexed salt, address indexed user, uint8 action, uint8 vaultId, address asset, uint256 amount);

    // ── Constructor ──────────────────────────────────────────────────────────

    constructor(
        address _operator,
        uint256 _reclaimDelay,
        address _duprtUsdcE,
        address _duprtUsdt0,
        address _duprtHoney,
        address _honeyFactory,
        address _honey,
        address _usde
    ) {
        require(_operator != address(0), "operator: zero address");
        require(_reclaimDelay >= MIN_RECLAIM_DELAY, "reclaimDelay too small");
        operator = _operator;
        reclaimDelay = _reclaimDelay;
        honeyFactory = _honeyFactory;
        honey = _honey;
        usde = _usde;

        duprtVaults[0] = _duprtUsdcE;
        duprtVaults[1] = _duprtUsdt0;
        duprtVaults[HONEY_VAULT_ID] = _duprtHoney;

        _status = _NOT_ENTERED;
    }

    // ── Modifiers ────────────────────────────────────────────────────────────

    modifier nonReentrant() {
        require(_status != _ENTERED, "reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ── CREATE2 addressing ───────────────────────────────────────────────────

    /**
     * @notice Predicts the counterfactual address funds should be sent to for
     *         a given intent. Pure function of (this contract's address, the
     *         intent's encoding) — no state read, matching how the frontend
     *         computes the same address off-chain with zero RPC calls.
     */
    function intentAddress(Intent calldata i) public view returns (address) {
        bytes32 salt = keccak256(abi.encode(i));
        bytes32 initCodeHash = keccak256(type(IntentExecutor).creationCode);
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)
        ))));
    }

    // ── Operator settlement ──────────────────────────────────────────────────

    function operatorSettle(Intent calldata i) external nonReentrant {
        require(msg.sender == operator, "not operator");

        if (i.action == ACTION_DUPRT) {
            _settleDuprt(i);
        } else if (i.action == ACTION_TRUST) {
            _settleTrustHandoff(i);
        } else if (i.action == ACTION_USDE_HONEY_DUPRT) {
            _settleHoneyDuprt(i);
        } else if (i.action == ACTION_USDE_HONEY_TRUST) {
            _settleHoneyTrust(i);
        } else {
            revert("unknown action");
        }
    }

    /// @dev action 0: sweep the vault's own asset, requestDeposit, refund on any failure.
    function _settleDuprt(Intent calldata i) internal {
        address vault = duprtVaults[i.vaultId];
        require(vault != address(0), "unknown vault");
        address asset = IERC7540Vault(vault).asset();

        address a = _ensureExecutor(i);
        uint256 amount = IIntentExecutor(a).sweep(asset, address(this));
        if (amount == 0) return; // nothing delivered yet — operator can retry later

        bytes32 salt = keccak256(abi.encode(i));

        if (amount < i.minOut) {
            _refund(i.user, asset, amount);
            _clearTouch(salt);
            return;
        }

        _forceApprove(asset, vault, amount);
        try IERC7540Vault(vault).requestDeposit(amount, i.user, address(this)) returns (uint256) {
            _forceApprove(asset, vault, 0);
            emit IntentSettled(i.user, vault, amount);
        } catch {
            _forceApprove(asset, vault, 0);
            _refund(i.user, asset, amount);
        }
        _clearTouch(salt);
    }

    /// @dev action 1: sweep the stablecoin and hand it directly to `operator` — no
    ///      vault call from the escrow. See the contract-level custody note: this is
    ///      a handoff, not a completed deposit, and userReclaim cannot undo it.
    function _settleTrustHandoff(Intent calldata i) internal {
        address vaultForAsset = duprtVaults[i.vaultId]; // reused only to resolve the asset
        require(vaultForAsset != address(0), "unknown vault");
        address asset = IERC7540Vault(vaultForAsset).asset();

        address a = _ensureExecutor(i);
        uint256 amount = IIntentExecutor(a).sweep(asset, address(this));
        if (amount == 0) return;

        bytes32 salt = keccak256(abi.encode(i));

        if (amount < i.minOut) {
            _refund(i.user, asset, amount);
            _clearTouch(salt);
            return;
        }

        _safeTransfer(asset, operator, amount);
        emit IntentHandedToOperator(i.user, i.vaultId, asset, amount);
        _clearTouch(salt);
    }

    /// @dev action 2: sweep USDe, mint HONEY, requestDeposit into the duPRT HONEY
    ///      vault. Refunds USDe if minting fails (nothing converted yet), refunds
    ///      HONEY if the deposit fails after a successful mint.
    function _settleHoneyDuprt(Intent calldata i) internal {
        require(i.vaultId == HONEY_VAULT_ID, "action requires HONEY vault");
        address vault = duprtVaults[HONEY_VAULT_ID];
        require(vault != address(0), "unknown vault");

        address a = _ensureExecutor(i);
        uint256 usdeAmount = IIntentExecutor(a).sweep(usde, address(this));
        if (usdeAmount == 0) return;

        bytes32 salt = keccak256(abi.encode(i));

        uint256 honeyAmount = _mintHoneyOrRefund(i.user, usdeAmount);
        if (honeyAmount == 0) {
            _clearTouch(salt); // mint failed and USDe was already refunded
            return;
        }

        if (honeyAmount < i.minOut) {
            _refund(i.user, honey, honeyAmount);
            _clearTouch(salt);
            return;
        }

        _forceApprove(honey, vault, honeyAmount);
        try IERC7540Vault(vault).requestDeposit(honeyAmount, i.user, address(this)) returns (uint256) {
            _forceApprove(honey, vault, 0);
            emit IntentSettled(i.user, vault, honeyAmount);
        } catch {
            _forceApprove(honey, vault, 0);
            _refund(i.user, honey, honeyAmount);
        }
        _clearTouch(salt);
    }

    /// @dev action 3: same mint step as action 2, then hand the resulting HONEY to
    ///      `operator` instead of depositing. Same custody note as action 1.
    function _settleHoneyTrust(Intent calldata i) internal {
        require(i.vaultId == HONEY_VAULT_ID, "action requires HONEY vault");

        address a = _ensureExecutor(i);
        uint256 usdeAmount = IIntentExecutor(a).sweep(usde, address(this));
        if (usdeAmount == 0) return;

        bytes32 salt = keccak256(abi.encode(i));

        uint256 honeyAmount = _mintHoneyOrRefund(i.user, usdeAmount);
        if (honeyAmount == 0) {
            _clearTouch(salt); // mint failed and USDe was already refunded
            return;
        }

        if (honeyAmount < i.minOut) {
            _refund(i.user, honey, honeyAmount);
            _clearTouch(salt);
            return;
        }

        _safeTransfer(honey, operator, honeyAmount);
        emit IntentHandedToOperator(i.user, i.vaultId, honey, honeyAmount);
        _clearTouch(salt);
    }

    /// @dev Mints HONEY from the escrow's own USDe balance. On a reverted mint
    ///      attempt, nothing was pulled by the factory (EVM revert undoes it),
    ///      so the full usdeAmount is refunded. On a technically-successful
    ///      mint that returns 0 HONEY (plausible for dust amounts under
    ///      HoneyFactory's sub-100% mint rate), we can't assume the same —
    ///      many factories pull the full stated input before computing output
    ///      (the same pattern as ERC-4626's deposit()), so the USDe may already
    ///      be gone even though nothing was minted. Refunding a fixed assumed
    ///      amount in that case can revert (or worse, over-refund) depending on
    ///      the real factory's behavior, so we refund whatever the escrow
    ///      actually still holds instead of trusting usdeAmount blindly.
    function _mintHoneyOrRefund(address user, uint256 usdeAmount) internal returns (uint256 honeyAmount) {
        _forceApprove(usde, honeyFactory, usdeAmount);
        try IHoneyFactory(honeyFactory).isBasketModeEnabled(true) returns (bool basket) {
            try IHoneyFactory(honeyFactory).mint(usde, usdeAmount, address(this), basket) returns (uint256 minted) {
                if (minted == 0) {
                    _forceApprove(usde, honeyFactory, 0);
                    _refundAvailable(user, usde, usdeAmount);
                    return 0;
                }
                honeyAmount = minted;
                _forceApprove(usde, honeyFactory, 0);
            } catch {
                _forceApprove(usde, honeyFactory, 0);
                _refund(user, usde, usdeAmount);
                return 0;
            }
        } catch {
            _forceApprove(usde, honeyFactory, 0);
            _refund(user, usde, usdeAmount);
            return 0;
        }
    }

    /// @dev Refunds whatever balance of `asset` the escrow actually holds,
    ///      capped at `cap` — the amount this specific call's own sweep is
    ///      known to have contributed. Used only for the zero-mint edge case
    ///      above, where the amount that arrived and the amount still held
    ///      may legitimately differ (a factory that pulls its full stated
    ///      input regardless of output leaves nothing to refund; one that
    ///      pulls nothing leaves the full amount).
    ///
    ///      The cap matters: reading the escrow's raw aggregate balance
    ///      without one would refund whatever else happens to be sitting in
    ///      the contract too — a prior intent's uncleaned dust from a partial
    ///      mint, or a direct external donation to the escrow's own address —
    ///      misattributing funds that were never this intent's to a user who
    ///      never delivered them. Capping at `cap` means this call can never
    ///      pay out more than what it itself is entitled to, regardless of
    ///      what else the escrow's balance might contain.
    function _refundAvailable(address user, address asset, uint256 cap) internal {
        uint256 available = IERC20(asset).balanceOf(address(this));
        uint256 amount = available < cap ? available : cap;
        if (amount > 0) {
            _refund(user, asset, amount);
        }
    }

    function _refund(address user, address asset, uint256 amount) internal {
        _safeTransfer(asset, user, amount);
        emit IntentRefunded(user, asset, amount);
    }

    // ── User / permissionless reclaim ────────────────────────────────────────

    /**
     * @notice Permissionless: stamps firstTouchedAt the first time a REAL
     *         delivery — meeting the intent's own minOut floor, the same bar
     *         every settlement path already uses to decide "did something
     *         meaningful arrive" — is observed at the intent's address.
     *         No-op if already touched, or if the balance there doesn't yet
     *         clear minOut. Reverts only for a malformed intent (an
     *         action/vaultId combination `_resolveReclaimAsset` itself
     *         rejects) — never for a valid intent, funded or not, which is
     *         the "never reverts" property the design note below relies on.
     * @dev    This is deliberately a separate function from userReclaim, not
     *         inlined into it. If a third party's "start the clock" write and
     *         the reclaimDelay check lived in the same call, that call would
     *         have to revert on an insufficient delay — and a revert undoes
     *         every state change made during it, including the timestamp
     *         write that same call just made. That's a deadlock: a third
     *         party could never durably start the clock at all. Splitting
     *         touch() out means the write can commit on its own, in a call
     *         that never reverts, and userReclaim only ever reads it.
     *
     *         Gating on `i.minOut` rather than "any nonzero balance" matters:
     *         a bare `balanceOf > 0` check can be satisfied with 1 wei of dust
     *         sent by anyone (A is a publicly computable address, nothing
     *         about an intent is secret), which would let an attacker
     *         pre-arm the clock cheaply before the user's real delivery
     *         lands — reopening the exact class of bug this function exists
     *         to close, just at a smaller balance instead of zero.
     *
     *         An intent constructed with `minOut == 0` has no meaningful
     *         floor to gate on, so touch() can never stamp it — that intent
     *         simply has no third-party liveness backstop at all (its owner
     *         can still always self-reclaim immediately, unaffected by any
     *         of this). Refusing to arm the clock on an unverifiable "real
     *         funds" signal is safer than arming it on a spoofable one.
     *
     *         For HONEY actions (2/3), the floor compared against is not
     *         `i.minOut` directly but `_armThreshold(i)` — see its docs for why
     *         the raw USDe balance needs a conservative buffer over `i.minOut`
     *         rather than a direct comparison.
     */
    function touch(Intent calldata i) external {
        address asset = _resolveReclaimAsset(i);
        bytes32 salt = keccak256(abi.encode(i));
        // Checking i.minOut > 0 before the balanceOf call (unlike the original
        // left-to-right && order) skips a wasted external call on intents that
        // can never arm at all — same outcome, one fewer read on that path.
        if (firstTouchedAt[salt] == 0 && i.minOut > 0) {
            uint256 amount = IERC20(asset).balanceOf(intentAddress(i));
            if (amount >= _armThreshold(i)) {
                firstTouchedAt[salt] = block.timestamp;
                emit IntentTouched(salt, i.user, i.action, i.vaultId, asset, amount);
            }
        }
    }

    /**
     * @notice Refunds intent.user by sweeping whatever is sitting at the
     *         intent's address. Callable by intent.user at any time; callable
     *         by anyone else only once reclaimDelay has elapsed since touch()
     *         was first called with real funds present, so the refund path
     *         has no single point of liveness failure even if intent.user is
     *         unreachable — while a third party still can't shorten the
     *         operator's settlement window by touching an unfunded intent early.
     * @dev    Requires a real, configured vaultId (so the asset to look for at
     *         `A` is known) — a reclaim can only ever be attempted for an
     *         intent that was constructed against a valid vault, matching how
     *         the frontend only ever generates valid intents in the first place.
     *
     *         For actions 2/3, whatever sits at `A` is always USDe: minting
     *         only ever happens inside a successful operatorSettle call and
     *         never lingers at `A` itself, so reclaim always looks for `usde`
     *         there regardless of vaultId.
     *
     *         For actions 1/3, once operatorSettle has already handed funds to
     *         `operator`, this function sees a drained `A` and no-ops — same
     *         as after any ordinary settlement. There is no separate error for
     *         "already handed to operator": mechanically it's indistinguishable
     *         from "already settled" from this contract's point of view. See
     *         the contract-level custody note for what that means for trUST.
     *
     *         This function only ever reads firstTouchedAt to decide
     *         eligibility — see touch() above for why the initial write has
     *         to live in its own, always-succeeding function. It does clear
     *         firstTouchedAt back to 0 once a reclaim actually completes,
     *         for the same reason every _settle* handler does: the same
     *         intent's address can legitimately be funded more than once
     *         (a retried bridge delivery, or a caller reusing the same
     *         tuple), and a stale timestamp from a prior, already-resolved
     *         funding round must not silently satisfy reclaimDelay for a
     *         completely new one.
     */
    function userReclaim(Intent calldata i) external nonReentrant {
        address asset = _resolveReclaimAsset(i);
        bytes32 salt = keccak256(abi.encode(i));

        if (msg.sender != i.user) {
            uint256 touchedAt = firstTouchedAt[salt];
            require(touchedAt != 0 && block.timestamp >= touchedAt + reclaimDelay, "reclaim: too early");
        }

        address a = _ensureExecutor(i);
        uint256 amount = IIntentExecutor(a).sweep(asset, address(this));
        if (amount == 0) return;

        _safeTransfer(asset, i.user, amount);
        emit IntentReclaimed(i.user, asset, amount);
        _clearTouch(salt);
    }

    /// @dev Shared by touch() and userReclaim(): resolves which asset to look
    ///      for at an intent's address, given its action/vaultId. Bounds-checks
    ///      `action` the same way operatorSettle's dispatcher does — not for
    ///      any known exploit (action is part of the CREATE2 salt, so an
    ///      out-of-range action can only ever map to its own empty address,
    ///      never collide with a real intent), but so touch()/userReclaim()
    ///      reject the same malformed input operatorSettle already would,
    ///      instead of silently treating it as a duPRT/TRUST lookup.
    function _resolveReclaimAsset(Intent calldata i) internal view returns (address) {
        if (i.action == ACTION_USDE_HONEY_DUPRT || i.action == ACTION_USDE_HONEY_TRUST) {
            require(i.vaultId == HONEY_VAULT_ID, "action requires HONEY vault");
            return usde;
        }
        require(i.action == ACTION_DUPRT || i.action == ACTION_TRUST, "unknown action");
        address vault = duprtVaults[i.vaultId];
        require(vault != address(0), "unknown vault");
        return IERC7540Vault(vault).asset();
    }

    /// @dev Used only by touch(). For non-HONEY actions (0/1), the asset
    ///      observed at `A` pre-settlement IS the asset i.minOut is compared
    ///      against downstream (see amount < i.minOut in _settleDuprt /
    ///      _settleTrustHandoff), so no buffer is needed — i.minOut applies
    ///      directly. For HONEY actions (2/3), the pre-settlement asset is USDe
    ///      but i.minOut is checked against the MINTED HONEY output downstream,
    ///      a different unit entirely — see HONEY_ARM_BUFFER_BPS's docs for why
    ///      a conservative buffer applies here instead of a 1:1 comparison.
    function _armThreshold(Intent calldata i) internal pure returns (uint256) {
        if (i.action == ACTION_USDE_HONEY_DUPRT || i.action == ACTION_USDE_HONEY_TRUST) {
            return (i.minOut * HONEY_ARM_BUFFER_BPS) / 10_000;
        }
        return i.minOut;
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    /**
     * @dev Deploys IntentExecutor at the intent's CREATE2 address on first
     *      touch (by operatorSettle or userReclaim); idempotent — returns the
     *      existing address on every subsequent call for the same intent
     *      instead of attempting to redeploy. Does NOT stamp firstTouchedAt —
     *      that write lives exclusively in touch(), and only ever fires once
     *      a real (>= minOut) balance is observed (see touch()'s docs for why
     *      it has to be a separate, always-succeeding function).
     */
    function _ensureExecutor(Intent calldata i) internal returns (address a) {
        a = intentAddress(i);
        if (a.code.length == 0) {
            bytes32 salt = keccak256(abi.encode(i));
            new IntentExecutor{salt: salt}();
        }
    }

    /// @dev Clears firstTouchedAt once a funding round is fully resolved
    ///      (deposited, handed off, or refunded), so a later, independent
    ///      re-funding of the same intent tuple — a retried bridge delivery,
    ///      or a caller reusing the same fields — starts its own clock
    ///      instead of inheriting a stale, already-expired timestamp from the
    ///      round that just completed.
    function _clearTouch(bytes32 salt) internal {
        if (firstTouchedAt[salt] != 0) {
            delete firstTouchedAt[salt];
        }
    }

    /**
     * @dev Reset-to-zero-then-set approve, defensive against non-standard
     *      ERC20s that reject changing a non-zero allowance directly.
     */
    function _forceApprove(address token, address spender, uint256 amount) internal {
        _safeApprove(token, spender, 0);
        if (amount > 0) {
            _safeApprove(token, spender, amount);
        }
    }
}
