// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ISecurityToken
 * @notice Interface for Issura ERC-3643-compliant security tokens.
 *         Each STO deployment gets its own token contract.
 *         Extends ERC-20 with transfer compliance hooks, forced
 *         transfers, and lifecycle management.
 */
interface ISecurityToken {
    // ── Events ─────────────────────────────────────────────────────────────

    event TokensFrozen(address indexed investor, uint256 amount);
    event TokensUnfrozen(address indexed investor, uint256 amount);
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount, string reason);
    event TokensRecovered(address indexed lostWallet, address indexed newWallet, uint256 amount);
    event STOPaused(string reason);
    event STOResumed();
    event DistributionProcessed(uint256 totalAmount, uint256 perTokenAmount, uint48 timestamp);

    // ── Structs ────────────────────────────────────────────────────────────

    struct STOConfig {
        string name;
        string symbol;
        string assetType;       // "real_estate" | "energy" | "private_credit" | "sme" | "agribusiness"
        uint256 targetRaise;    // in USDC (6 decimals)
        uint256 tokenPrice;     // USDC per token (6 decimals)
        uint256 maxSupply;      // total tokens available
        uint256 minInvestment;  // minimum tokens per investor
        uint16[] allowedCountries;
        uint48 closingDate;
        address issuer;
        address treasury;       // where raise proceeds go
        uint16 feeBps;          // platform fee in basis points (150 = 1.5%)
    }

    // ── Read ───────────────────────────────────────────────────────────────

    function getConfig() external view returns (STOConfig memory);
    function isFrozen(address investor) external view returns (bool);
    function frozenBalance(address investor) external view returns (uint256);
    function totalRaised() external view returns (uint256);
    function investorCount() external view returns (uint256);
    function canTransfer(address from, address to, uint256 amount) external view returns (bool, string memory);

    // ── Compliance ─────────────────────────────────────────────────────────

    function forcedTransfer(address from, address to, uint256 amount, string calldata reason) external;
    function freezeTokens(address investor, uint256 amount) external;
    function unfreezeTokens(address investor, uint256 amount) external;
    function recoverTokens(address lostWallet, address newWallet) external;

    // ── Lifecycle ──────────────────────────────────────────────────────────

    function pause(string calldata reason) external;
    function unpause() external;
    function closeOffering() external;

    // ── Distributions ──────────────────────────────────────────────────────

    function processDistribution(uint256 totalUSDC) external;
    function claimDistribution() external;
    function pendingDistribution(address investor) external view returns (uint256);
}
