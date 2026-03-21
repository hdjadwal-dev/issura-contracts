// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./tokens/IssuraSecurityToken.sol";
import "./interfaces/ISURAInvestable.sol";


contract STOFactory is AccessControl, ReentrancyGuard {

    error ZeroAddress();
    error ZeroValue();
    error ClosingDateInPast();
    error NoCountries();
    error STONotActive();
    error STONotFound();
    error USDCTransferFailed();
    error FeeTooHigh();

    bytes32 public constant OPERATOR_ROLE   = keccak256("OPERATOR_ROLE");
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    address public immutable identityRegistry;
    address public immutable usdc;
    address public feeTreasury;
    uint16  public defaultFeeBps = 150;

    struct STORecord {
        address tokenAddress;
        address issuer;
        string  name;
        string  assetType;
        uint256 targetRaise;
        uint48  createdAt;
        bool    active;
    }

    mapping(bytes32 => STORecord) public stoRecords;
    mapping(address => bytes32[]) public issuerSTOs;
    bytes32[] public allSTOIds;
    uint256 public stoCount;

    event STOCreated(bytes32 indexed stoId, address indexed tokenAddress, address indexed issuer, string name, string assetType, uint256 targetRaise);
    event STODeactivated(bytes32 indexed stoId, string reason);
    event InvestmentProcessed(bytes32 indexed stoId, address indexed investor, uint256 usdcAmount);
    event FeeTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event DefaultFeeUpdated(uint16 oldBps, uint16 newBps);

    constructor(address identityRegistry_, address usdc_, address feeTreasury_, address admin, address operator) { 
        require(identityRegistry_ != address(0), "Factory: zero registry");require(usdc_ != address(0), "Factory: zero usdc");require(feeTreasury_ != address(0), "Factory: zero treasury");
	identityRegistry = identityRegistry_;
        usdc = usdc_;
        feeTreasury = feeTreasury_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(OPERATOR_ROLE, admin);
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(COMPLIANCE_ROLE, admin);
    }

    function createSTO(IssuraSecurityToken.STOConfig calldata config, address complianceOfficer)
        external onlyRole(OPERATOR_ROLE)
        returns (bytes32 stoId, address tokenAddress)
    {
        if (config.issuer == address(0))          revert ZeroAddress();
        if (config.treasury == address(0))        revert ZeroAddress();
        if (complianceOfficer == address(0))      revert ZeroAddress();
        if (config.targetRaise == 0)              revert ZeroValue();
        if (config.tokenPrice == 0)               revert ZeroValue();
        if (config.maxSupply == 0)                revert ZeroValue();
        if (config.closingDate <= block.timestamp) revert ClosingDateInPast();
        if (config.allowedCountries.length == 0)  revert NoCountries();

        stoId = keccak256(abi.encodePacked(config.issuer, config.name, block.timestamp, stoCount));

        IssuraSecurityToken token = new IssuraSecurityToken(config, identityRegistry, usdc, address(this), complianceOfficer);
        tokenAddress = address(token);

        stoRecords[stoId] = STORecord({ tokenAddress: tokenAddress, issuer: config.issuer, name: config.name, assetType: config.assetType, targetRaise: config.targetRaise, createdAt: uint48(block.timestamp), active: true });

        issuerSTOs[config.issuer].push(stoId);
        allSTOIds.push(stoId);
        stoCount++;

        emit STOCreated(stoId, tokenAddress, config.issuer, config.name, config.assetType, config.targetRaise);
    }

    function invest(bytes32 stoId, uint256 usdcAmount) external nonReentrant {
        STORecord storage rec = stoRecords[stoId];
        if (!rec.active)                    revert STONotActive();
        if (rec.tokenAddress == address(0)) revert STONotFound();

        IERC20 usdcToken = IERC20(usdc);
        if (!usdcToken.transferFrom(msg.sender, address(this), usdcAmount)) revert USDCTransferFailed();

        bool s1 = usdcToken.approve(rec.tokenAddress, 0);
        bool s2 = usdcToken.approve(rec.tokenAddress, usdcAmount);
        ISURAInvestable(rec.tokenAddress).invest(msg.sender, usdcAmount);
        bool s3 = usdcToken.approve(rec.tokenAddress, 0);

        emit InvestmentProcessed(stoId, msg.sender, usdcAmount);
    }

    function deactivateSTO(bytes32 stoId, string calldata reason) external onlyRole(COMPLIANCE_ROLE) {
        stoRecords[stoId].active = false;
        emit STODeactivated(stoId, reason);
    }

    function setFeeTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "Factory: zero address"); emit FeeTreasuryUpdated(feeTreasury, 	newTreasury); feeTreasury = newTreasury;
    }

    function setDefaultFeeBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > 500) revert FeeTooHigh();
        emit DefaultFeeUpdated(defaultFeeBps, newBps);
        defaultFeeBps = newBps;
    }

    function getSTORecord(bytes32 stoId) external view returns (STORecord memory) { return stoRecords[stoId]; }
    function getIssuerSTOs(address issuer) external view returns (bytes32[] memory) { return issuerSTOs[issuer]; }
    function getAllSTOIds() external view returns (bytes32[] memory) { return allSTOIds; }
}


