// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  MockFeeOnTransferERC20
 * @notice Test-double for a deflationary/fee-on-transfer token: every
 *         transfer deducts `feeBps` and the recipient receives less than the
 *         sender sent. Exists to prove IntentExecutor.sweep() reports the
 *         recipient's actual received delta, not its own pre-transfer
 *         balance — the amount every downstream caller in SukukZapEscrow
 *         treats as ground truth.
 */
contract MockFeeOnTransferERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public feeBps; // e.g. 200 = 2%

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals, uint256 _feeBps) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        feeBps = _feeBps;
    }

    function setFeeBps(uint256 _feeBps) external {
        feeBps = _feeBps;
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
        require(allowed >= amount, "MockFeeOnTransferERC20: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "MockFeeOnTransferERC20: insufficient balance");
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 received = amount - fee;
        balanceOf[from] -= amount;
        balanceOf[to] += received;
        // Fee is simply burned (not credited anywhere) — matches the common
        // deflationary-token shape and is the simplest model that still
        // exercises "recipient receives less than sender sent."
    }
}
