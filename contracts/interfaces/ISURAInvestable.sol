// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISURAInvestable {
    function invest(address investor, uint256 usdcAmount) external;
}