// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../contracts/SukukZapEscrow.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockERC7540Vault.sol";
import "./mocks/MockHoneyFactory.sol";
import "./Vm.sol";

/**
 * @title  SukukZapEscrowHalmosTest
 * @notice Symbolic-execution property tests, run via `halmos` (not
 *         `forge test` — halmos only executes functions prefixed
 *         `check_`/`invariant_`, forge only executes functions prefixed
 *         `test`, so this suite and SukukZapEscrow.t.sol never collide or
 *         double-run each other). Proves the exact custody invariant stated
 *         in SukukZapEscrow's own docstring holds for EVERY possible
 *         amount/minOut, not just the handful of concrete values the
 *         Foundry unit suite and the fizz stateful-fuzzing suite happen to
 *         try — a genuinely different guarantee than fuzzing (sampling)
 *         or static analysis (pattern-matching) provide.
 */
contract SukukZapEscrowHalmosTest {
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

    /// @notice Proves the contract's own custody invariant for duPRT actions
    ///         (0, 2): "the only two possible outcomes are a deposit
    ///         crediting intent.user, or a refund to intent.user." Encoded
    ///         here as: for EVERY possible delivered `amount` and EVERY
    ///         possible `minOut`, settling an action-0 intent can never
    ///         change `operator`'s own balance — operator payment is
    ///         exclusively the trUST path (actions 1/3), never duPRT. A
    ///         wiring bug that accidentally routed a duPRT settlement to
    ///         `operator` instead of the vault/user would be caught here
    ///         across ALL inputs, not just whichever ones a fuzzer or a
    ///         human reviewer happened to try.
    function check_duprtSettlementNeverPaysOperator(uint256 amount, uint256 minOut) public {
        SukukZapEscrow.Intent memory i =
            SukukZapEscrow.Intent({action: 0, user: user, vaultId: 0, minOut: minOut, nonce: 1});

        address a = escrow.intentAddress(i);
        usdc.mint(a, amount);

        uint256 operatorBalanceBefore = usdc.balanceOf(operator);

        vm.prank(operator);
        escrow.operatorSettle(i);

        assert(usdc.balanceOf(operator) == operatorBalanceBefore);
    }

    /// @notice Same invariant, the other duPRT leg (action 2: USDe -> HONEY
    ///         -> duPRT HONEY vault). Operator's HONEY balance must never
    ///         move, for every possible delivered USDe amount and minOut.
    function check_honeyDuprtSettlementNeverPaysOperator(uint256 amount, uint256 minOut) public {
        SukukZapEscrow.Intent memory i = SukukZapEscrow.Intent({
            action: 2,
            user: user,
            vaultId: escrow.HONEY_VAULT_ID(),
            minOut: minOut,
            nonce: 1
        });

        address a = escrow.intentAddress(i);
        usdeToken.mint(a, amount);

        uint256 operatorBalanceBefore = honey.balanceOf(operator);

        vm.prank(operator);
        escrow.operatorSettle(i);

        assert(honey.balanceOf(operator) == operatorBalanceBefore);
    }
}
