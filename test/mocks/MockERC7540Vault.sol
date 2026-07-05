// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * @title  MockERC7540Vault
 * @notice Minimal test-double standing in for SukukFi's real duPRT vaults.
 *         Mirrors the real requestDeposit(assets, controller, owner) signature
 *         confirmed against abis/ERC7575VaultUpgradeable.json: pulls `assets`
 *         from `owner` via transferFrom (so the caller must have approved this
 *         vault first, matching the real vault's behaviour), and credits the
 *         request to `controller`. `forceRevert` lets tests exercise
 *         SukukZapEscrow's catch/refund path.
 */
contract MockERC7540Vault {
    address public asset;
    bool public forceRevert;

    // requestId => controller => pending assets, matching the real
    // pendingDepositRequest(uint256,address) view shape.
    mapping(uint256 => mapping(address => uint256)) public pendingDepositRequest;
    uint256 public nextRequestId = 1;

    constructor(address _asset) {
        asset = _asset;
    }

    function setForceRevert(bool v) external {
        forceRevert = v;
    }

    function requestDeposit(uint256 assets, address controller, address owner) external returns (uint256 requestId) {
        require(!forceRevert, "MockERC7540Vault: forced revert");
        require(IERC20Like(asset).transferFrom(owner, address(this), assets), "MockERC7540Vault: pull failed");
        requestId = nextRequestId++;
        pendingDepositRequest[requestId][controller] += assets;
    }
}
