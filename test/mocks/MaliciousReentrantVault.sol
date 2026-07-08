// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20Like } from "./MockERC7540Vault.sol";

/**
 * @title  MaliciousReentrantVault
 * @notice Test-only attacker: a duPRT vault stand-in that, during its own
 *         requestDeposit() call (i.e. from inside SukukZapEscrow's
 *         nonReentrant-guarded operatorSettle), attempts an arbitrary
 *         cross-function reentrant call back into the escrow. Exists solely
 *         to prove SukukZapEscrow.nonReentrant's transient-storage lock
 *         actually blocks reentrancy end-to-end, not just that it compiles
 *         and costs less gas.
 */
contract MaliciousReentrantVault {
    address public asset;
    address public escrow;
    bytes public reentryCalldata;
    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryReturnData;

    mapping(uint256 => mapping(address => uint256)) public pendingDepositRequest;
    uint256 public nextRequestId = 1;

    constructor(address _asset, address _escrow) {
        asset = _asset;
        escrow = _escrow;
    }

    // Deploying SukukZapEscrow requires this vault's address up front (it's a
    // constructor arg), so the escrow doesn't exist yet when this vault is
    // deployed — set it after the fact instead of trying to break that cycle.
    function setEscrow(address _escrow) external {
        escrow = _escrow;
    }

    function setReentryCalldata(bytes calldata data) external {
        reentryCalldata = data;
    }

    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId) {
        require(IERC20Like(asset).transferFrom(owner, address(this), assets), "MaliciousReentrantVault: pull failed");

        if (reentryCalldata.length > 0) {
            reentryAttempted = true;
            (bool ok, bytes memory returnData) = escrow.call(reentryCalldata);
            reentrySucceeded = ok;
            reentryReturnData = returnData;
        }

        requestId = nextRequestId++;
        pendingDepositRequest[requestId][controller] += assets;
    }
}
