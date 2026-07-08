// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  MockBlacklistableERC20
 * @notice Test-double for a USDC.e-style token with a real blacklist: any
 *         transfer TO a blacklisted address reverts, matching Circle's own
 *         USDC blacklist semantics (blacklisting blocks receiving, not just
 *         sending). Exists to prove SukukZapEscrow's owed/withdrawOwed
 *         pull-payment fallback actually engages when a refund/reclaim
 *         recipient can't receive, instead of permanently stranding funds.
 */
contract MockBlacklistableERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public isBlacklisted;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function setBlacklisted(address account, bool blacklisted) external {
        isBlacklisted[account] = blacklisted;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "MockBlacklistableERC20: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(!isBlacklisted[to], "MockBlacklistableERC20: recipient blacklisted");
        require(balanceOf[from] >= amount, "MockBlacklistableERC20: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
