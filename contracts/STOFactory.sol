// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./tokens/IssuraSecurityToken.sol";

/**
 * @title STOFactory
 * @notice Platform-level factory that deploys a new IssuraSecurityToken
 *         for each approved STO. Acts as the single entry point for
 *         issuer onboarding and token lifecycle management.
 *
 *   Flow:
 *     1. Admin approves issuer application (off-chain KYC complete)
 *     2. Admin calls createSTO() with config approved in review
 *     3. New IssuraSecurityToken (ERC-1400) deployed and registered
 *     4. Investors call invest() via the factory (AGENT_ROLE)
 *     5. Issuer calls processDistribution() directly on token contract
 *
 * @dev Only ADMIN_ROLE can create STOs (gated — no permissionless issuance)
 */
contract STOFactory is AccessControl, ReentrancyGuard {

    // ── Roles ──────────────────────────────────────────────────────────────
    bytes32 public constant OPERATOR_ROLE   = keccak256("OPERATOR_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    // ── State ──────────────────────────────────────────────────────────────
    address public immutable identityRegistry;
    address public immutable usdc;
    address public feeTreasury;
    uint16  public defaultFeeBps = 150; // 1.5% platform fee

    struct STORecord {
        address tokenAddress;
        address issuer;
        string  name;
        string  assetType;
        uint256 targetRaise;
        uint48  createdAt;
        bool    active;
    }

    mapping(bytes32 => STORecord) public stoRecords;  // stoId => record
    mapping(address => bytes32[]) public issuerSTOs;  // issuer => stoIds
    bytes32[] public allSTOIds;

    uint256 public stoCount;

    // ── Events ─────────────────────────────────────────────────────────────
    event STOCreated(
        bytes32 indexed stoId,
        address indexed tokenAddress,
        address indexed issuer,
        string name,
        string assetType,
        uint256 targetRaise
    );
    event STODeactivated(bytes32 indexed stoId, string reason);
    event InvestmentProcessed(
        bytes32 indexed stoId,
        address indexed investor,
        uint256 usdcAmount,
        uint256 tokens
    );
    event FeeTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event DefaultFeeUpdated(uint16 indexed oldBps, uint16 indexed newBps);

    // ── Constructor ────────────────────────────────────────────────────────
    constructor(
        address identityRegistry_,
        address usdc_,
        address feeTreasury_,
        address admin,
        address operator
    ) {
        identityRegistry = identityRegistry_;
        usdc = usdc_;
        feeTreasury = feeTreasury_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(COMPLIANCE_ROLE, admin);
    }

    // ── STO Creation (admin/operator only — gated platform) ────────────────

    /**
     * @notice Deploy a new security token for an approved STO.
     * @param config  Full STO configuration (reviewed and approved off-chain)
     * @param complianceOfficer  Address authorized to freeze/force-transfer
     * @return stoId         Unique identifier for this STO
     * @return tokenAddress  Deployed token contract address
     */
    function createSTO(
        IssuraSecurityToken.STOConfig calldata config,
        address complianceOfficer
    )
        external
        onlyRole(OPERATOR_ROLE)
        returns (bytes32 stoId, address tokenAddress)
    {
        require(config.issuer != address(0), "Factory: zero issuer");
        require(config.treasury != address(0), "Factory: zero treasury");
        require(config.targetRaise > 0, "Factory: zero target");
        require(config.tokenPrice > 0, "Factory: zero price");
        require(config.maxSupply > 0, "Factory: zero supply");
        require(config.closingDate > block.timestamp, "Factory: closing date in past");
        require(config.allowedCountries.length > 0, "Factory: no countries");

        // Generate unique STO ID
        stoId = keccak256(abi.encodePacked(
            config.issuer,
            config.name,
            block.timestamp,
            stoCount
        ));

        // Deploy token contract
        IssuraSecurityToken token = new IssuraSecurityToken(
            config,
            identityRegistry,
            usdc,
            address(this),       // factory is admin
            complianceOfficer
        );

        tokenAddress = address(token);

        // Record
        stoRecords[stoId] = STORecord({
            tokenAddress: tokenAddress,
            issuer:       config.issuer,
            name:         config.name,
            assetType:    config.assetType,
            targetRaise:  config.targetRaise,
            createdAt:    uint48(block.timestamp),
            active:       true
        });

        issuerSTOs[config.issuer].push(stoId);
        allSTOIds.push(stoId);
        ++stoCount;

        emit STOCreated(stoId, tokenAddress, config.issuer, config.name, config.assetType, config.targetRaise);
    }

    // ── Investment routing ─────────────────────────────────────────────────

    /**
     * @notice Route an investor's USDC into a specific STO.
     *         Factory acts as AGENT — verifies everything then calls invest().
     *
     *         Investor must have:
     *           1. Approved USDC allowance to this factory
     *           2. Verified identity in IdentityRegistry
     *
     * @param stoId      Target STO
     * @param usdcAmount USDC amount (6 decimals)
     */
    function invest(bytes32 stoId, uint256 usdcAmount)
        external
        nonReentrant
    {
        STORecord storage rec = stoRecords[stoId];
        require(rec.active, "Factory: STO not active");
        require(rec.tokenAddress != address(0), "Factory: STO not found");

        IssuraSecurityToken token = IssuraSecurityToken(rec.tokenAddress);

        // Transfer USDC from investor to factory first
        IERC20 usdcToken = IERC20(usdc);
        require(
            usdcToken.transferFrom(msg.sender, address(this), usdcAmount),
            "Factory: USDC transfer failed"
        );

        // Approve token contract to pull exactly usdcAmount from factory
        // Using forceApprove pattern: reset to 0 first (some tokens require this)
        usdcToken.approve(rec.tokenAddress, 0);
        usdcToken.approve(rec.tokenAddress, usdcAmount);

        // Delegate to token contract — it will pull from this factory
        token.invest(msg.sender, usdcAmount);

        // Reset approval to 0 after call — prevents stale allowance exploit
        usdcToken.approve(rec.tokenAddress, 0);

        emit InvestmentProcessed(stoId, msg.sender, usdcAmount, 0);
    }

    // ── Admin ──────────────────────────────────────────────────────────────

    function deactivateSTO(bytes32 stoId, string calldata reason)
        external onlyRole(COMPLIANCE_ROLE)
    {
        stoRecords[stoId].active = false;
        emit STODeactivated(stoId, reason);
    }

    function setFeeTreasury(address newTreasury)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        emit FeeTreasuryUpdated(feeTreasury, newTreasury);
        feeTreasury = newTreasury;
    }

    function setDefaultFeeBps(uint16 newBps)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(newBps <= 500, "Factory: fee too high"); // max 5%
        emit DefaultFeeUpdated(defaultFeeBps, newBps);
        defaultFeeBps = newBps;
    }

    // ── Views ──────────────────────────────────────────────────────────────

    function getSTORecord(bytes32 stoId)
        external view returns (STORecord memory)
    {
        return stoRecords[stoId];
    }

    function getIssuerSTOs(address issuer)
        external view returns (bytes32[] memory)
    {
        return issuerSTOs[issuer];
    }

    function getAllSTOIds() external view returns (bytes32[] memory) {
        return allSTOIds;
    }
}


