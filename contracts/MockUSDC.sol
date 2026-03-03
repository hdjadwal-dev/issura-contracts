// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUSDC
 * @notice Test-only USDC with 6 decimals. Never deploy to mainnet.
 */
contract MockUSDC is ERC20, Ownable {
    constructor(address owner) ERC20("USD Coin", "USDC") Ownable(owner) {}

    function decimals() public pure override returns (uint8) { return 6; }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function faucet(uint256 amount) external {
        require(amount <= 100_000 * 1e6, "MockUSDC: max 100K per faucet");
        _mint(msg.sender, amount);
    }
}
