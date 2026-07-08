// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * @title  MockHoneyFactory
 * @notice Minimal test-double for the real HoneyFactory. Mirrors
 *         `mint(address,uint256,address,bool)` and `isBasketModeEnabled(bool)`.
 *         Pulls `amount` of the collateral asset via transferFrom (matching the
 *         real factory's behaviour, since SukukZapEscrow approves it first),
 *         then mints an equal amount of HONEY to `receiver`. `forceRevert`
 *         lets tests exercise the mint-failure refund path.
 *
 *         Three non-1:1-success modes, since the real factory's exact
 *         behavior here is unverified from this bundle and the escrow's fix
 *         needs to be safe under any of them:
 *         - `forceZeroMintPullsInput`: pulls the full collateral (ERC-4626
 *           `deposit()`-style — input consumed regardless of rounding) but
 *           mints 0 HONEY. The collateral is genuinely gone.
 *         - `forceZeroMintNoPull`: mints 0 HONEY and pulls nothing at all.
 *           The collateral never left the escrow.
 *         - `partialPullBps` (default 10_000 = 100%, i.e. off): a
 *           *successful* mint (nonzero HONEY out) that only pulls this
 *           fraction of the approved `amount`, leaving the rest as unswept
 *           collateral in the caller (the escrow) — models a sub-100%
 *           mint rate on the success path, as opposed to the two explicit
 *           zero-output edge cases above. Exists to reproduce the audit
 *           finding about cross-intent USDe dust misattribution: this is
 *           the mode that actually produces leftover dust after a
 *           *successful* mint, which the two zero-output modes don't.
 */
contract MockHoneyFactory {
    address public collateral;
    IMintableERC20 public honeyToken;
    bool public forceRevert;
    bool public forceZeroMintPullsInput;
    bool public forceZeroMintNoPull;
    uint256 public partialPullBps = 10_000;

    constructor(address _collateral, address _honeyToken) {
        collateral = _collateral;
        honeyToken = IMintableERC20(_honeyToken);
    }

    function setForceRevert(bool v) external {
        forceRevert = v;
    }

    function setForceZeroMintPullsInput(bool v) external {
        forceZeroMintPullsInput = v;
    }

    function setForceZeroMintNoPull(bool v) external {
        forceZeroMintNoPull = v;
    }

    function setPartialPullBps(uint256 v) external {
        partialPullBps = v;
    }

    function isBasketModeEnabled(bool) external pure returns (bool) {
        return false;
    }

    function mint(address asset, uint256 amount, address receiver, bool) external returns (uint256) {
        require(!forceRevert, "MockHoneyFactory: forced revert");
        require(asset == collateral, "MockHoneyFactory: wrong collateral");
        if (forceZeroMintNoPull) {
            return 0; // nothing pulled, nothing minted
        }
        uint256 toPull = (amount * partialPullBps) / 10_000;
        require(IMintableERC20(collateral).transferFrom(msg.sender, address(this), toPull), "MockHoneyFactory: pull failed");
        if (forceZeroMintPullsInput) {
            return 0; // collateral consumed, but nothing minted — the audit's edge case
        }
        if (toPull == 0) {
            return 0; // partialPullBps == 0: nothing pulled, nothing minted
        }
        honeyToken.mint(receiver, toPull); // 1:1 mint on whatever was actually pulled
        return toPull;
    }
}
