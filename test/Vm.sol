// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  Vm
 * @notice Minimal declaration of the subset of Foundry's built-in cheatcode
 *         precompile this test suite uses. Not a dependency — `forge` ships
 *         this precompile at a fixed address regardless of any library; this
 *         interface just declares the handful of signatures we call, instead
 *         of pulling in forge-std for ~5 cheatcodes.
 */
interface Vm {
    function prank(address sender) external;
    function warp(uint256 newTimestamp) external;
    function expectRevert(bytes calldata revertData) external;
    function expectRevert() external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
    function createSelectFork(string calldata urlOrAlias) external returns (uint256 forkId);
}

address constant VM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;
