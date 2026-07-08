// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../contracts/SukukZapEscrow.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockERC7540Vault.sol";
import "./mocks/MockHoneyFactory.sol";
import "./mocks/MaliciousReentrantVault.sol";
import "./Vm.sol";

/**
 * @title  SukukZapEscrowTest
 * @notice No forge-std dependency by design (see the plan for this build):
 *         this repo has zero external Solidity dependencies today, and
 *         installing one was declined. `Vm.sol` declares just the handful of
 *         cheatcode signatures used below, calling straight into forge's own
 *         built-in cheatcode precompile. Assertions are plain `require` —
 *         functionally identical to forge-std's assertTrue/assertEq, just
 *         without importing anything to get there.
 *
 *         Most tests run against local mock contracts (MockERC20,
 *         MockERC7540Vault) so the custody logic itself is fully exercised
 *         with no network dependency. One fork test at the bottom checks the
 *         real live duPRT vaults' `asset()` against the addresses this
 *         contract would be deployed with, so the interface assumptions above
 *         are checked against the real thing too.
 */
contract SukukZapEscrowTest {
    Vm constant vm = Vm(VM_ADDRESS);

    SukukZapEscrow escrow;
    MockERC20 usdc;
    MockERC20 usdt0;
    MockERC20 honey;
    MockERC20 usdeToken;
    MockERC7540Vault vaultUsdc;
    MockERC7540Vault vaultUsdt0;
    MockERC7540Vault vaultHoney;
    MockHoneyFactory honeyFactoryMock;

    address operator = address(0xA11CE);
    address user = address(0xB0B);
    uint256 constant RECLAIM_DELAY = 24 hours;

    // Real, live Berachain addresses (config/deployment.json) — used only by
    // the fork sanity test at the bottom.
    address constant REAL_VAULT_USDC_E = 0x1B610abd3dFA170fdC579c48da7007217c06149D;
    address constant REAL_ASSET_USDC_E = 0x549943e04f40284185054145c6E4e9568C1D3241;
    address constant REAL_VAULT_USDT0 = 0x3d6D8D7e66594f3cFbbF2c65dcE305edCD325f7e;
    address constant REAL_ASSET_USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address constant REAL_VAULT_HONEY = 0xdc9D7e60f3091029FA2479919325385a56F2A2F8;
    address constant REAL_ASSET_HONEY = 0xFCBD14DC51f0A4d49d5E53C2E0950e0bC26d0Dce;

    function setUp() public {
        usdc = new MockERC20("USDC.e", "USDC.e", 6);
        usdt0 = new MockERC20("USDT0", "USDT0", 6);
        honey = new MockERC20("HONEY", "HONEY", 18);
        usdeToken = new MockERC20("USDe", "USDe", 18);

        vaultUsdc = new MockERC7540Vault(address(usdc));
        vaultUsdt0 = new MockERC7540Vault(address(usdt0));
        vaultHoney = new MockERC7540Vault(address(honey));
        honeyFactoryMock = new MockHoneyFactory(address(usdeToken), address(honey));

        escrow = new SukukZapEscrow(
            operator,
            RECLAIM_DELAY,
            address(vaultUsdc),
            address(vaultUsdt0),
            address(vaultHoney),
            address(honeyFactoryMock),
            address(honey),
            address(usdeToken)
        );
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    function _intent(address u, uint8 vaultId, uint256 minOut, uint256 nonce)
        internal
        pure
        returns (SukukZapEscrow.Intent memory)
    {
        return SukukZapEscrow.Intent({action: 0, user: u, vaultId: vaultId, minOut: minOut, nonce: nonce});
    }

    function _intentA(uint8 action, address u, uint8 vaultId, uint256 minOut, uint256 nonce)
        internal
        pure
        returns (SukukZapEscrow.Intent memory)
    {
        return SukukZapEscrow.Intent({action: action, user: u, vaultId: vaultId, minOut: minOut, nonce: nonce});
    }

    // ── 0b. Constructor rejects a zero honeyFactory/honey/usde — these three
    //         have no downstream `require(!= address(0))` guard the way
    //         duprtVaults entries do (caught per-call by "unknown vault"), so
    //         a misconfigured zero here would otherwise let every HONEY call
    //         silently no-op instead of reverting (the missing-zero-check
    //         finding) ──────────────────────────────────────────────────────

    function testConstructorRejectsZeroHoneyFactory() public {
        vm.expectRevert(bytes("honeyFactory: zero address"));
        new SukukZapEscrow(
            operator, RECLAIM_DELAY, address(vaultUsdc), address(vaultUsdt0), address(vaultHoney),
            address(0), address(honey), address(usdeToken)
        );
    }

    function testConstructorRejectsZeroHoney() public {
        vm.expectRevert(bytes("honey: zero address"));
        new SukukZapEscrow(
            operator, RECLAIM_DELAY, address(vaultUsdc), address(vaultUsdt0), address(vaultHoney),
            address(honeyFactoryMock), address(0), address(usdeToken)
        );
    }

    function testConstructorRejectsZeroUsde() public {
        vm.expectRevert(bytes("usde: zero address"));
        new SukukZapEscrow(
            operator, RECLAIM_DELAY, address(vaultUsdc), address(vaultUsdt0), address(vaultHoney),
            address(honeyFactoryMock), address(honey), address(0)
        );
    }

    // ── 1. intentAddress matches a manually-computed CREATE2 address ────────

    function testIntentAddressMatchesCreate2() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 0, 1);
        address predicted = escrow.intentAddress(i);

        bytes32 salt = keccak256(abi.encode(i));
        bytes32 initCodeHash = keccak256(type(IntentExecutor).creationCode);
        address manual = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(escrow), salt, initCodeHash))))
        );

        require(predicted == manual, "intentAddress does not match manual CREATE2 computation");
    }

    // ── 2. Happy path: funds at A, operator settles, vault credited ─────────

    function testHappyPathSettle() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 0, 1);
        address a = escrow.intentAddress(i);
        usdc.mint(a, 100e6);

        vm.prank(operator);
        escrow.operatorSettle(i);

        require(usdc.balanceOf(a) == 0, "A should be fully drained after settle");
        require(vaultUsdc.pendingDepositRequest(1, user) == 100e6, "vault should credit user's request");
    }

    // ── 2b. IntentSettled carries the real requestId (previously discarded —
    //         the unused-return finding), so it's correlatable on-chain with
    //         the vault's own pendingDepositRequest(requestId, controller) ──

    function testIntentSettledEmitsRealRequestId() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 0, 101);
        address a = escrow.intentAddress(i);
        usdc.mint(a, 25e6);

        // MockERC7540Vault's nextRequestId starts at 1 and is fresh per-vault
        // per setUp(), so the first request against vaultUsdc in this test is
        // deterministically requestId 1.
        vm.expectEmit(true, true, false, true);
        emit SukukZapEscrow.IntentSettled(user, address(vaultUsdc), 25e6, 1);
        vm.prank(operator);
        escrow.operatorSettle(i);
    }

    // ── 3. Early/zero-balance settle is a safe no-op; later delivery still settles ──

    function testEarlySettleThenRealDeliveryStillSettles() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 0, 2);
        bytes32 salt = keccak256(abi.encode(i));
        address a = escrow.intentAddress(i);

        vm.prank(operator);
        escrow.operatorSettle(i); // nothing there yet — must not revert, must not strand A
        require(escrow.firstTouchedAt(salt) == 0, "operatorSettle must never stamp firstTouchedAt");
        require(vaultUsdc.pendingDepositRequest(1, user) == 0, "nothing should be credited yet");

        usdc.mint(a, 50e6);
        vm.prank(operator);
        escrow.operatorSettle(i); // real delivery arrives — must settle now

        require(vaultUsdc.pendingDepositRequest(1, user) == 50e6, "real delivery should settle on retry");
    }

    // ── 4. userReclaim before any funds arrive is a safe no-op ───────────────

    function testReclaimBeforeFundsIsNoOp() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 0, 3);
        vm.prank(user);
        escrow.userReclaim(i); // must not revert
        require(usdc.balanceOf(user) == 0, "nothing to reclaim yet");
    }

    // ── 5. userReclaim by the user themselves is allowed immediately ────────

    function testUserReclaimImmediate() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 0, 4);
        address a = escrow.intentAddress(i);
        usdc.mint(a, 77e6);

        vm.prank(user);
        escrow.userReclaim(i);

        require(usdc.balanceOf(user) == 77e6, "user should receive the full refund");
        require(usdc.balanceOf(a) == 0, "A should be drained");
    }

    // ── 6. Third-party reclaim before reclaimDelay reverts ───────────────────

    function testThirdPartyReclaimTooEarlyReverts() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 1e6, 5); // nonzero minOut — touch() needs a real floor to arm on
        address a = escrow.intentAddress(i);
        usdc.mint(a, 10e6);

        address stranger = address(0xCAFE);
        vm.prank(stranger);
        escrow.touch(i); // durably starts the clock — must not itself revert

        vm.prank(stranger);
        vm.expectRevert(bytes("reclaim: too early"));
        escrow.userReclaim(i);
    }

    // ── 7. Third-party reclaim after reclaimDelay succeeds, pays intent.user ──

    function testThirdPartyReclaimAfterDelaySucceeds() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 1e6, 6); // nonzero minOut — touch() needs a real floor to arm on
        address a = escrow.intentAddress(i);
        usdc.mint(a, 42e6);

        address stranger = address(0xCAFE);
        vm.prank(stranger);
        escrow.touch(i);

        vm.warp(block.timestamp + RECLAIM_DELAY);

        vm.prank(stranger);
        escrow.userReclaim(i);

        require(usdc.balanceOf(user) == 42e6, "funds must go to intent.user, not the caller");
        require(usdc.balanceOf(stranger) == 0, "stranger must not receive anything");
    }

    // ── 7b. touch() on an unfunded intent never arms the clock (the audit finding) ──

    function testTouchOnUnfundedIntentDoesNotArmClock() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 1e6, 61); // nonzero minOut — touch() needs a real floor to arm on
        bytes32 salt = keccak256(abi.encode(i));

        address stranger = address(0xCAFE);
        vm.prank(stranger);
        escrow.touch(i); // nothing at A yet
        require(escrow.firstTouchedAt(salt) == 0, "touching an unfunded intent must not start the clock");

        // Real funds land later — the clock must start from THIS moment, not the
        // earlier no-op touch, so a stranger still can't reclaim immediately.
        address a = escrow.intentAddress(i);
        usdc.mint(a, 5e6);

        address stranger2 = address(0xF00D);
        vm.prank(stranger2);
        vm.expectRevert(bytes("reclaim: too early"));
        escrow.userReclaim(i); // this call's own touch() logic doesn't apply — userReclaim never writes firstTouchedAt
    }

    // ── 7b2. touch() never arms on dust below minOut, only on funding that meets it ──

    function testTouchDoesNotArmOnDustBelowMinOut() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 1e6, 63); // minOut = 1e6
        bytes32 salt = keccak256(abi.encode(i));
        address a = escrow.intentAddress(i);

        address attacker = address(0xBEEF);
        usdc.mint(a, 1); // 1 wei of dust — the exact griefing vector the audit found

        vm.prank(attacker);
        escrow.touch(i);
        require(escrow.firstTouchedAt(salt) == 0, "dust below minOut must not arm the clock");

        // Real funds land later, meeting minOut — only THIS should arm the clock.
        usdc.mint(a, 1e6 - 1);
        vm.prank(attacker);
        escrow.touch(i);
        require(escrow.firstTouchedAt(salt) != 0, "a delivery meeting minOut must arm the clock");
    }

    // ── 7c. an operator probe on an unfunded intent never arms the clock either ──

    function testOperatorProbeDoesNotArmClockForThirdPartyReclaim() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 1e6, 62); // nonzero minOut — touch() needs a real floor to arm on
        address a = escrow.intentAddress(i);

        vm.prank(operator);
        escrow.operatorSettle(i); // the exact "empty probe" pattern the audit flagged

        usdc.mint(a, 5e6);

        address stranger = address(0xCAFE);
        vm.prank(stranger);
        escrow.touch(i);
        vm.warp(block.timestamp + RECLAIM_DELAY - 1);

        vm.prank(stranger);
        vm.expectRevert(bytes("reclaim: too early"));
        escrow.userReclaim(i); // full reclaimDelay must elapse from the real touch, not the earlier probe
    }

    // ── 7d. firstTouchedAt resets after a full resolution, so address reuse starts fresh ──

    function testFirstTouchedAtResetsAfterSettlementSoReuseStartsFresh() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 1e6, 64);
        bytes32 salt = keccak256(abi.encode(i));
        address a = escrow.intentAddress(i);

        // Cycle 1: touch, then a full settlement resolves and drains A.
        usdc.mint(a, 5e6);
        vm.prank(address(0xCAFE));
        escrow.touch(i);
        require(escrow.firstTouchedAt(salt) != 0, "cycle 1 should have armed the clock");

        vm.prank(operator);
        escrow.operatorSettle(i);
        require(escrow.firstTouchedAt(salt) == 0, "a full settlement must clear the stale touch");

        // Cycle 2: a second, independent funding round to the SAME intent tuple
        // (e.g. a retried bridge delivery) must NOT inherit cycle 1's long-expired
        // timestamp — a third party must wait the full reclaimDelay again.
        usdc.mint(a, 3e6);
        address stranger = address(0xF00D);
        vm.prank(stranger);
        vm.expectRevert(bytes("reclaim: too early"));
        escrow.userReclaim(i); // firstTouchedAt is 0 again — must not trivially satisfy the delay check

        vm.prank(stranger);
        escrow.touch(i);
        vm.warp(block.timestamp + RECLAIM_DELAY);
        vm.prank(stranger);
        escrow.userReclaim(i);

        require(usdc.balanceOf(user) == 3e6, "cycle 2's funds should reach the user after its own full delay");
    }

    // ── 8. operatorSettle from a non-operator reverts ────────────────────────

    function testNonOperatorSettleReverts() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 0, 7);
        vm.prank(address(0xDEAD));
        vm.expectRevert(bytes("not operator"));
        escrow.operatorSettle(i);
    }

    // ── 9. Delivered amount below minOut refunds instead of depositing ──────

    function testBelowMinOutRefunds() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 100e6, 8); // minOut = 100
        address a = escrow.intentAddress(i);
        usdc.mint(a, 40e6); // less than minOut

        vm.prank(operator);
        escrow.operatorSettle(i);

        require(usdc.balanceOf(user) == 40e6, "under-minOut delivery should refund the user");
        require(vaultUsdc.pendingDepositRequest(1, user) == 0, "vault should not be touched");
    }

    // ── 10. Settling twice is safe: second call is a no-op ───────────────────

    function testDoubleSettleIsNoOp() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 0, 9);
        address a = escrow.intentAddress(i);
        usdc.mint(a, 20e6);

        vm.prank(operator);
        escrow.operatorSettle(i);
        require(vaultUsdc.pendingDepositRequest(1, user) == 20e6, "first settle should credit");

        vm.prank(operator);
        escrow.operatorSettle(i); // second call — must not double-credit

        require(vaultUsdc.pendingDepositRequest(1, user) == 20e6, "second settle must not double-credit");
    }

    // ── 11. Different intents never collide on the same address (fuzz) ──────

    function testFuzzDistinctIntentsDoNotCollide(uint256 nonceA, uint256 nonceB) public {
        if (nonceA == nonceB) nonceB = nonceA + 1; // force distinct
        SukukZapEscrow.Intent memory a1 = _intent(user, 0, 0, nonceA);
        SukukZapEscrow.Intent memory a2 = _intent(user, 0, 0, nonceB);
        require(escrow.intentAddress(a1) != escrow.intentAddress(a2), "distinct intents must not collide");
    }

    // ── 12. trUST handoff (action 1): happy path lands on `operator`, not a vault ──

    function testTrustHandoffHappyPath() public {
        SukukZapEscrow.Intent memory i = _intentA(1, user, 0, 0, 10); // vaultId 0 = USDC.e asset
        address a = escrow.intentAddress(i);
        usdc.mint(a, 60e6);

        vm.prank(operator);
        escrow.operatorSettle(i);

        require(usdc.balanceOf(a) == 0, "A should be drained");
        require(usdc.balanceOf(operator) == 60e6, "funds must land on operator, not a vault");
        require(vaultUsdc.pendingDepositRequest(1, user) == 0, "no vault should ever be touched for action 1");
    }

    // ── 13. trUST handoff: below minOut refunds instead of handing off ─────

    function testTrustHandoffBelowMinOutRefunds() public {
        SukukZapEscrow.Intent memory i = _intentA(1, user, 0, 100e6, 11);
        address a = escrow.intentAddress(i);
        usdc.mint(a, 10e6);

        vm.prank(operator);
        escrow.operatorSettle(i);

        require(usdc.balanceOf(user) == 10e6, "under-minOut should refund the user");
        require(usdc.balanceOf(operator) == 0, "operator should receive nothing");
    }

    // ── 14. trUST handoff: early no-op settle, then real delivery still hands off ──

    function testTrustHandoffEarlySettleThenRealDelivery() public {
        SukukZapEscrow.Intent memory i = _intentA(1, user, 0, 0, 12);
        address a = escrow.intentAddress(i);

        vm.prank(operator);
        escrow.operatorSettle(i); // nothing there yet

        usdc.mint(a, 15e6);
        vm.prank(operator);
        escrow.operatorSettle(i);

        require(usdc.balanceOf(operator) == 15e6, "real delivery should hand off on retry");
    }

    // ── 15. trUST handoff: userReclaim still works BEFORE the handoff happens ──

    function testTrustHandoffReclaimBeforeHandoffWorks() public {
        SukukZapEscrow.Intent memory i = _intentA(1, user, 0, 0, 13);
        address a = escrow.intentAddress(i);
        usdc.mint(a, 25e6);

        vm.prank(user);
        escrow.userReclaim(i);

        require(usdc.balanceOf(user) == 25e6, "user should be able to self-reclaim before any handoff");
    }

    // ── 16. trUST handoff: userReclaim is a no-op AFTER the handoff — the documented gap ──

    function testTrustHandoffReclaimAfterHandoffIsNoOp() public {
        SukukZapEscrow.Intent memory i = _intentA(1, user, 0, 0, 14);
        address a = escrow.intentAddress(i);
        usdc.mint(a, 33e6);

        vm.prank(operator);
        escrow.operatorSettle(i); // hands off to operator

        vm.prank(user);
        escrow.userReclaim(i); // must not revert, must not pull from operator's own balance

        require(usdc.balanceOf(user) == 0, "reclaim after handoff must not conjure funds back");
        require(usdc.balanceOf(operator) == 33e6, "operator keeps what was already handed off");
    }

    // ── 17. USDe→HONEY→duPRT (action 2): happy path mints then deposits ─────

    function testHoneyDuprtHappyPath() public {
        SukukZapEscrow.Intent memory i = _intentA(2, user, escrow.HONEY_VAULT_ID(), 0, 20);
        address a = escrow.intentAddress(i);
        usdeToken.mint(a, 80e18);

        vm.prank(operator);
        escrow.operatorSettle(i);

        require(usdeToken.balanceOf(a) == 0, "A should be drained of USDe");
        require(honey.balanceOf(address(escrow)) == 0, "escrow should not retain HONEY after settling");
        require(vaultHoney.pendingDepositRequest(1, user) == 80e18, "HONEY vault should credit user's request");
    }

    // ── 18. USDe→HONEY: mint failure refunds USDe, not HONEY ────────────────

    function testHoneyMintFailureRefundsUsde() public {
        honeyFactoryMock.setForceRevert(true);
        SukukZapEscrow.Intent memory i = _intentA(2, user, escrow.HONEY_VAULT_ID(), 0, 21);
        address a = escrow.intentAddress(i);
        usdeToken.mint(a, 50e18);

        vm.prank(operator);
        escrow.operatorSettle(i);

        require(usdeToken.balanceOf(user) == 50e18, "mint failure must refund the original USDe");
        require(honey.balanceOf(user) == 0, "no HONEY should exist to refund if mint never happened");
    }

    // ── 19. USDe→HONEY→duPRT: post-mint deposit failure refunds HONEY, not USDe ──

    function testHoneyDuprtPostMintDepositFailureRefundsHoney() public {
        vaultHoney.setForceRevert(true);
        SukukZapEscrow.Intent memory i = _intentA(2, user, escrow.HONEY_VAULT_ID(), 0, 22);
        address a = escrow.intentAddress(i);
        usdeToken.mint(a, 65e18);

        vm.prank(operator);
        escrow.operatorSettle(i);

        require(honey.balanceOf(user) == 65e18, "post-mint deposit failure must refund HONEY, the held token");
        require(usdeToken.balanceOf(user) == 0, "USDe was already converted, must not also refund USDe");
    }

    // ── 19b. touch() requires a buffer above i.minOut for HONEY actions, since
    //         i.minOut is HONEY-denominated (the minted output) but touch()
    //         observes pre-mint USDe — see HONEY_ARM_BUFFER_BPS ────────────────

    function testHoneyTouchRequiresBufferAboveMinOut() public {
        SukukZapEscrow.Intent memory i = _intentA(2, user, escrow.HONEY_VAULT_ID(), 1e18, 90);
        bytes32 salt = keccak256(abi.encode(i));
        address a = escrow.intentAddress(i);

        // Exactly i.minOut in raw USDe must NOT arm — this is the exact
        // "cheaper early-arm" gap the audit flagged: a sub-100% mint rate means
        // i.minOut USDe in doesn't guarantee i.minOut HONEY out.
        usdeToken.mint(a, 1e18);
        vm.prank(address(0xBEEF));
        escrow.touch(i);
        require(escrow.firstTouchedAt(salt) == 0, "exactly minOut in USDe must not arm a HONEY intent's clock");

        // Reaching the documented buffer (110% of minOut) does arm it.
        usdeToken.mint(a, 0.1e18); // total 1.1e18 = 110% of minOut
        vm.prank(address(0xBEEF));
        escrow.touch(i);
        require(escrow.firstTouchedAt(salt) != 0, "110% of minOut in USDe must arm a HONEY intent's clock");
    }

    // ── 19c. touch() emits IntentTouched exactly when it arms the clock — the
    //         on-chain signal an off-chain watcher indexes to detect stuck
    //         intents, since intent addresses are otherwise unregistered ──────

    function testTouchEmitsIntentTouchedOnlyWhenArming() public {
        SukukZapEscrow.Intent memory i = _intent(user, 0, 1e6, 91);
        bytes32 salt = keccak256(abi.encode(i));
        address a = escrow.intentAddress(i);

        // Below minOut: touch() must not emit anything.
        usdc.mint(a, 0.5e6);
        vm.prank(address(0xBEEF));
        escrow.touch(i);
        require(escrow.firstTouchedAt(salt) == 0, "dust below minOut must not arm the clock");

        // Reaching minOut: touch() must emit IntentTouched with the observed amount.
        usdc.mint(a, 0.5e6); // total 1e6 = minOut
        vm.expectEmit(true, true, false, true);
        emit SukukZapEscrow.IntentTouched(salt, user, 0, 0, address(usdc), 1e6);
        vm.prank(address(0xBEEF));
        escrow.touch(i);
        require(escrow.firstTouchedAt(salt) != 0, "reaching minOut must arm the clock");

        // Already armed: firstTouchedAt[salt] != 0 short-circuits touch() before
        // it reaches the emit, by construction — a second call is a plain no-op.
        vm.prank(address(0xBEEF));
        escrow.touch(i);
    }

    // ── 19d. nonReentrant actually blocks a cross-function reentrant call —
    //         proves the transient-storage lock (contracts/SukukZapEscrow.sol)
    //         works end-to-end, not just that it compiles and costs less gas.
    //         A malicious vault reenters into userReclaim() for the SAME
    //         intent from inside operatorSettle()'s own requestDeposit call ──

    function testNonReentrantBlocksCrossFunctionReentrancy() public {
        MaliciousReentrantVault evilVault = new MaliciousReentrantVault(address(usdc), address(0));

        SukukZapEscrow evilEscrow = new SukukZapEscrow(
            operator,
            RECLAIM_DELAY,
            address(evilVault), // vaultId 0 — the malicious one
            address(vaultUsdt0),
            address(vaultHoney),
            address(honeyFactoryMock),
            address(honey),
            address(usdeToken)
        );
        evilVault.setEscrow(address(evilEscrow));

        SukukZapEscrow.Intent memory i = _intent(user, 0, 1e6, 200);
        address a = evilEscrow.intentAddress(i);
        usdc.mint(a, 5e6);

        evilVault.setReentryCalldata(abi.encodeWithSelector(evilEscrow.userReclaim.selector, i));

        vm.prank(operator);
        evilEscrow.operatorSettle(i);

        require(evilVault.reentryAttempted(), "malicious vault must have attempted the reentrant call");
        require(!evilVault.reentrySucceeded(), "reentrant userReclaim must be blocked by the lock, not silently succeed");
        require(
            keccak256(evilVault.reentryReturnData()) == keccak256(abi.encodeWithSignature("Error(string)", "reentrant call")),
            "must be blocked specifically by the reentrancy guard, not some unrelated revert"
        );

        // The outer settlement itself must still complete normally — the
        // guard blocks the attacker's nested call, not the legitimate one.
        require(evilVault.pendingDepositRequest(1, user) == 5e6, "legitimate outer settlement must still succeed");
    }

    // ── 20. USDe→HONEY→trUST (action 3): mints then hands HONEY to operator ──

    function testHoneyTrustHandoffHappyPath() public {
        SukukZapEscrow.Intent memory i = _intentA(3, user, escrow.HONEY_VAULT_ID(), 0, 23);
        address a = escrow.intentAddress(i);
        usdeToken.mint(a, 90e18);

        vm.prank(operator);
        escrow.operatorSettle(i);

        require(honey.balanceOf(operator) == 90e18, "minted HONEY must land on operator for the trUST leg");
        require(vaultHoney.pendingDepositRequest(1, user) == 0, "no vault should be touched for action 3");
    }

    // ── 21b. A technically-successful zero-value mint refunds USDe (the audit finding) ──

    function testHoneyZeroMintNoPullRefundsUsde() public {
        honeyFactoryMock.setForceZeroMintNoPull(true);
        SukukZapEscrow.Intent memory i = _intentA(2, user, escrow.HONEY_VAULT_ID(), 0, 25);
        address a = escrow.intentAddress(i);
        usdeToken.mint(a, 1);

        vm.prank(operator);
        escrow.operatorSettle(i);

        require(usdeToken.balanceOf(user) == 1, "if the factory never pulled the collateral, it must come back to the user");
        require(honey.balanceOf(user) == 0, "nothing was minted, so no HONEY to refund");
        require(vaultHoney.pendingDepositRequest(1, user) == 0, "vault must not be touched");
    }

    // ── 21b2. A zero-mint that DID consume the input cannot conjure a refund back — the fix must not revert or over-refund ──

    function testHoneyZeroMintPullsInputDoesNotRevertOrOverRefund() public {
        honeyFactoryMock.setForceZeroMintPullsInput(true);
        SukukZapEscrow.Intent memory i = _intentA(2, user, escrow.HONEY_VAULT_ID(), 0, 25);
        address a = escrow.intentAddress(i);
        usdeToken.mint(a, 1); // dust amount, plausibly rounds to 0 minted under a real factory

        vm.prank(operator);
        escrow.operatorSettle(i); // must complete without reverting even though the USDe is already gone

        require(usdeToken.balanceOf(user) == 0, "the collateral was already consumed by the factory; there is nothing left to refund");
        require(honey.balanceOf(user) == 0, "nothing was minted, so no HONEY either");
        require(usdeToken.balanceOf(address(escrow)) == 0, "the escrow must not be left holding a stray balance");
        require(vaultHoney.pendingDepositRequest(1, user) == 0, "vault must not be touched");
    }

    // ── 21c. Approvals are reset to zero after a successful mint and after a successful deposit ──

    function testApprovalsResetAfterSuccessfulSettlement() public {
        SukukZapEscrow.Intent memory duprtIntent = _intent(user, 0, 0, 26);
        address a1 = escrow.intentAddress(duprtIntent);
        usdc.mint(a1, 30e6);
        vm.prank(operator);
        escrow.operatorSettle(duprtIntent);
        require(usdc.allowance(address(escrow), address(vaultUsdc)) == 0, "vault allowance must be reset after a successful deposit");

        SukukZapEscrow.Intent memory honeyIntent = _intentA(2, user, escrow.HONEY_VAULT_ID(), 0, 27);
        address a2 = escrow.intentAddress(honeyIntent);
        usdeToken.mint(a2, 40e18);
        vm.prank(operator);
        escrow.operatorSettle(honeyIntent);
        require(usdeToken.allowance(address(escrow), address(honeyFactoryMock)) == 0, "HoneyFactory allowance must be reset after a successful mint");
        require(honey.allowance(address(escrow), address(vaultHoney)) == 0, "HONEY vault allowance must be reset after a successful deposit");
    }

    // ── 21. HONEY actions defensively reject any vaultId other than the HONEY slot ──

    function testHoneyActionWrongVaultIdReverts() public {
        SukukZapEscrow.Intent memory i = _intentA(2, user, 0, 0, 24); // vaultId 0 = USDC.e, invalid for action 2
        vm.prank(operator);
        vm.expectRevert(bytes("action requires HONEY vault"));
        escrow.operatorSettle(i);
    }

    // ── Fork sanity check: real vault interfaces match what this contract assumes ──

    function testForkVaultAssetsMatchRealTokens() public {
        vm.createSelectFork("https://rpc.berachain.com");
        require(
            IERC7540Vault(REAL_VAULT_USDC_E).asset() == REAL_ASSET_USDC_E,
            "live USDC.e vault asset() mismatch"
        );
        require(
            IERC7540Vault(REAL_VAULT_USDT0).asset() == REAL_ASSET_USDT0,
            "live USDT0 vault asset() mismatch"
        );
        require(
            IERC7540Vault(REAL_VAULT_HONEY).asset() == REAL_ASSET_HONEY,
            "live HONEY vault asset() mismatch"
        );
    }
}
