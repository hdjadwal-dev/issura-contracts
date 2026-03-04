// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IIdentityRegistry.sol";

/**
 * @title SURAToken
 * @notice SURA — Issura Platform Security Token (ERC-1400 / ERC-3643 compliant)
 *
 * ERC-1400 Features:
 *   - Partitions: LOCKED (primary lockup), VESTING, TRADEABLE
 *   - Transfer restrictions with ERC-1066 reason codes
 *   - Operator authorisation
 *   - Document management (prospectus, legal agreements)
 *   - Forced transfers for regulatory compliance
 *   - Issuance / redemption lifecycle
 *
 * MAS SFA Compliance:
 *   - Identity registry check on every transfer
 *   - ASEAN geo-fencing via country allow-list
 *   - 6-month lock-up on primary issuance
 *   - Accredited investor tier checks
 */
contract SURAToken is ERC20, ERC20Pausable, AccessControl, ReentrancyGuard {

    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant ISSUER_ROLE     = keccak256("ISSUER_ROLE");
    bytes32 public constant AGENT_ROLE      = keccak256("AGENT_ROLE");

    // ERC-1400 Partitions
    bytes32 public constant PARTITION_LOCKED    = keccak256("LOCKED");
    bytes32 public constant PARTITION_VESTING   = keccak256("VESTING");
    bytes32 public constant PARTITION_TRADEABLE = keccak256("TRADEABLE");

    // ERC-1066 Transfer Reason Codes
    bytes1 public constant CODE_SUCCESS         = 0x51;
    bytes1 public constant CODE_COMPLIANCE_FAIL = 0x50;
    bytes1 public constant CODE_NOT_VERIFIED    = 0x56;
    bytes1 public constant CODE_TOKENS_LOCKED   = 0x55;
    bytes1 public constant CODE_INSUFFICIENT    = 0x52;
    bytes1 public constant CODE_PAUSED          = 0x54;

    struct Document {
        bytes32 docHash;
        string  uri;
        uint48  updatedAt;
    }
    mapping(bytes32 => Document) private _documents;
    bytes32[] private _documentNames;

    struct STOConfig {
        string  name;
        string  symbol;
        string  assetType;
        string  assetDescription;
        uint256 targetRaise;
        uint256 tokenPrice;
        uint256 maxSupply;
        uint256 minInvestment;
        uint16[] allowedCountries;
        uint48  closingDate;
        uint48  lockupPeriod;
        address issuer;
        address treasury;
        uint16  feeBps;
    }

    STOConfig private _config;
    bool public offeringClosed;
    bool public redemptionEnabled;
    string public pauseReason;

    IIdentityRegistry public immutable identityRegistry;
    IERC20 public immutable usdc;

    mapping(address => mapping(bytes32 => uint256)) private _partitionBalances;
    mapping(bytes32 => uint256) private _partitionTotalSupply;
    mapping(address => uint48)  private _lockupExpiry;
    mapping(address => uint256) private _frozenTokens;
    mapping(address => bool)    private _isInvestor;
    address[] private _investorList;
    uint256 private _investorCount;
    uint256 private _totalRaised;

    mapping(address => mapping(address => bool)) private _operators;
    mapping(bytes32 => mapping(address => mapping(address => bool))) private _partitionOperators;

    uint256 private _distributionIndex;
    mapping(address => uint256) private _investorIndex;
    mapping(address => uint256) private _pendingClaims;

    event Issued(address indexed operator, address indexed to, uint256 value, bytes data);
    event Redeemed(address indexed operator, address indexed from, uint256 value, bytes data);
    event IssuedByPartition(bytes32 indexed partition, address indexed to, uint256 value);
    event TransferByPartition(bytes32 indexed fromPartition, address indexed from, address indexed to, uint256 value);
    event TokensLocked(address indexed investor, uint256 amount, uint48 until);
    event TokensUnlocked(address indexed investor, uint256 amount);
    event TokensFrozen(address indexed investor, uint256 amount);
    event TokensUnfrozen(address indexed investor, uint256 amount);
    event ForcedTransfer(address indexed from, address indexed to, uint256 amount, string reason);
    event TokensRecovered(address indexed lostWallet, address indexed newWallet, uint256 amount);
    event DocumentUpdated(bytes32 indexed name, string uri, bytes32 docHash);
    event OfferingClosed(uint256 totalRaised, uint256 totalTokens);
    event RedemptionEnabled();
    event DistributionProcessed(uint256 totalAmount, uint256 perToken, uint48 timestamp);
    event Investment(address indexed investor, uint256 usdcAmount, uint256 tokens);
    event OperatorAuthorised(address indexed operator, address indexed tokenHolder);
    event OperatorRevoked(address indexed operator, address indexed tokenHolder);
    event STOPaused(string reason);
    event STOResumed();

    constructor(
        STOConfig memory config,
        address identityRegistry_,
        address usdc_,
        address admin,
        address complianceOfficer
    ) ERC20(config.name, config.symbol) {
        _config = config;
        identityRegistry = IIdentityRegistry(identityRegistry_);
        usdc = IERC20(usdc_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, complianceOfficer);
        _grantRole(ISSUER_ROLE, config.issuer);
        _grantRole(AGENT_ROLE, admin);
    }

    // Document Management (ERC-1400)
    function setDocument(bytes32 name, string calldata uri, bytes32 docHash)
        external onlyRole(ISSUER_ROLE)
    {
        if (_documents[name].updatedAt == 0) _documentNames.push(name);
        _documents[name] = Document({ docHash: docHash, uri: uri, updatedAt: uint48(block.timestamp) });
        emit DocumentUpdated(name, uri, docHash);
    }

    function getDocument(bytes32 name)
        external view returns (string memory uri, bytes32 docHash, uint48 updatedAt)
    {
        Document storage d = _documents[name];
        return (d.uri, d.docHash, d.updatedAt);
    }

    function getAllDocuments() external view returns (bytes32[] memory) {
        return _documentNames;
    }

    // Partition Balances
    function balanceOfByPartition(bytes32 partition, address tokenHolder) external view returns (uint256) {
        return _partitionBalances[tokenHolder][partition];
    }

    function partitionsOf(address tokenHolder)
        external view returns (bytes32[] memory partitions, uint256[] memory amounts)
    {
        partitions = new bytes32[](3);
        amounts    = new uint256[](3);
        partitions[0] = PARTITION_LOCKED;    amounts[0] = _partitionBalances[tokenHolder][PARTITION_LOCKED];
        partitions[1] = PARTITION_VESTING;   amounts[1] = _partitionBalances[tokenHolder][PARTITION_VESTING];
        partitions[2] = PARTITION_TRADEABLE; amounts[2] = _partitionBalances[tokenHolder][PARTITION_TRADEABLE];
    }

    function totalSupplyByPartition(bytes32 partition) external view returns (uint256) {
        return _partitionTotalSupply[partition];
    }

    // Operator Management
    function authoriseOperator(address operator) external {
        _operators[msg.sender][operator] = true;
        emit OperatorAuthorised(operator, msg.sender);
    }

    function revokeOperator(address operator) external {
        _operators[msg.sender][operator] = false;
        emit OperatorRevoked(operator, msg.sender);
    }

    function isOperator(address operator, address tokenHolder) public view returns (bool) {
        return _operators[tokenHolder][operator] || hasRole(AGENT_ROLE, operator);
    }

    function authoriseOperatorByPartition(bytes32 partition, address operator) external {
        _partitionOperators[partition][msg.sender][operator] = true;
    }

    function isOperatorForPartition(bytes32 partition, address operator, address tokenHolder)
        public view returns (bool)
    {
        return _partitionOperators[partition][tokenHolder][operator] || isOperator(operator, tokenHolder);
    }

    // Investment (primary issuance into LOCKED partition)
    function invest(address investor, uint256 usdcAmount)
        external onlyRole(AGENT_ROLE) whenNotPaused nonReentrant
    {
        require(!offeringClosed, "SURA: offering closed");
        require(block.timestamp <= _config.closingDate, "SURA: offering expired");
        require(identityRegistry.canTransfer(address(0), investor), "SURA: investor not verified");

        uint256 tokens = (usdcAmount * 1e18) / _config.tokenPrice;
        require(tokens >= _config.minInvestment, "SURA: below minimum");
        require(totalSupply() + tokens <= _config.maxSupply, "SURA: exceeds max supply");

        uint256 fee        = (usdcAmount * _config.feeBps) / 10000;
        uint256 netProceeds = usdcAmount - fee;

        require(usdc.transferFrom(msg.sender, address(this), usdcAmount), "SURA: USDC pull failed");
        require(usdc.transfer(_config.treasury, fee), "SURA: fee transfer failed");
        require(usdc.transfer(_config.issuer, netProceeds), "SURA: proceeds transfer failed");

        _updateInvestorIndex(investor);
        _mintByPartition(PARTITION_LOCKED, investor, tokens);

        uint48 expiry = uint48(block.timestamp) + _config.lockupPeriod;
        if (_lockupExpiry[investor] < expiry) _lockupExpiry[investor] = expiry;

        _totalRaised += usdcAmount;
        if (!_isInvestor[investor]) {
            _isInvestor[investor] = true;
            _investorList.push(investor);
            _investorCount++;
        }

        emit Investment(investor, usdcAmount, tokens);
        emit IssuedByPartition(PARTITION_LOCKED, investor, tokens);
        emit TokensLocked(investor, tokens, expiry);
    }

    // Unlock tokens after lockup period expires
    function unlockTokens(address investor) external {
        require(block.timestamp >= _lockupExpiry[investor], "SURA: lockup not expired");
        uint256 locked = _partitionBalances[investor][PARTITION_LOCKED];
        require(locked > 0, "SURA: no locked tokens");
        _partitionBalances[investor][PARTITION_LOCKED]    -= locked;
        _partitionTotalSupply[PARTITION_LOCKED]           -= locked;
        _partitionBalances[investor][PARTITION_TRADEABLE] += locked;
        _partitionTotalSupply[PARTITION_TRADEABLE]        += locked;
        emit TokensUnlocked(investor, locked);
        emit TransferByPartition(PARTITION_LOCKED, investor, investor, locked);
    }

    function lockupExpiry(address investor) external view returns (uint48) {
        return _lockupExpiry[investor];
    }

    // Transfer By Partition (only TRADEABLE)
    function transferByPartition(bytes32 partition, address to, uint256 value, bytes calldata data)
        external whenNotPaused nonReentrant returns (bytes32)
    {
        require(partition == PARTITION_TRADEABLE, "SURA: only TRADEABLE transferable");
        (bytes1 code, string memory reason) = _checkTransfer(msg.sender, to, value);
        require(code == CODE_SUCCESS, reason);
        _updateInvestorIndex(msg.sender);
        _updateInvestorIndex(to);
        _transferByPartition(partition, msg.sender, to, value);
        emit TransferByPartition(partition, msg.sender, to, value);
        return partition;
    }

    function operatorTransferByPartition(
        bytes32 partition, address from, address to, uint256 value,
        bytes calldata data, bytes calldata operatorData
    ) external whenNotPaused nonReentrant returns (bytes32) {
        require(isOperatorForPartition(partition, msg.sender, from), "SURA: not authorised operator");
        require(partition == PARTITION_TRADEABLE, "SURA: only TRADEABLE transferable");
        (bytes1 code, string memory reason) = _checkTransfer(from, to, value);
        require(code == CODE_SUCCESS, reason);
        _updateInvestorIndex(from);
        _updateInvestorIndex(to);
        _transferByPartition(partition, from, to, value);
        emit TransferByPartition(partition, from, to, value);
        return partition;
    }

    function canTransferByPartition(bytes32 partition, address from, address to, uint256 value, bytes calldata data)
        external view returns (bytes1 code, bytes32, string memory reason)
    {
        if (paused()) return (CODE_PAUSED, partition, "STO is paused");
        if (partition != PARTITION_TRADEABLE) return (CODE_TOKENS_LOCKED, partition, "Not in TRADEABLE partition");
        (bytes1 c, string memory r) = _checkTransfer(from, to, value);
        return (c, partition, r);
    }

    function _checkTransfer(address from, address to, uint256 value)
        internal view returns (bytes1, string memory)
    {
        if (!identityRegistry.isVerified(to)) return (CODE_NOT_VERIFIED, "Receiver not KYC verified");
        if (from != address(0) && !identityRegistry.isVerified(from)) return (CODE_NOT_VERIFIED, "Sender not KYC verified");
        if (_partitionBalances[from][PARTITION_TRADEABLE] < value + _frozenTokens[from])
            return (CODE_INSUFFICIENT, "Insufficient tradeable balance");
        return (CODE_SUCCESS, "");
    }

    // Compliance
    function freezeTokens(address investor, uint256 amount) external onlyRole(COMPLIANCE_ROLE) {
        require(balanceOf(investor) >= _frozenTokens[investor] + amount, "SURA: insufficient balance");
        _frozenTokens[investor] += amount;
        emit TokensFrozen(investor, amount);
    }

    function unfreezeTokens(address investor, uint256 amount) external onlyRole(COMPLIANCE_ROLE) {
        require(_frozenTokens[investor] >= amount, "SURA: insufficient frozen");
        _frozenTokens[investor] -= amount;
        emit TokensUnfrozen(investor, amount);
    }

    function forcedTransfer(address from, address to, uint256 amount, string calldata reason)
        external onlyRole(COMPLIANCE_ROLE)
    {
        require(balanceOf(from) >= amount, "SURA: insufficient balance");
        _updateInvestorIndex(from);
        _updateInvestorIndex(to);
        uint256 locked = _partitionBalances[from][PARTITION_LOCKED];
        if (locked >= amount) {
            _transferByPartition(PARTITION_LOCKED, from, to, amount);
        } else if (locked > 0) {
            _transferByPartition(PARTITION_LOCKED, from, to, locked);
            _transferByPartition(PARTITION_TRADEABLE, from, to, amount - locked);
        } else {
            _transferByPartition(PARTITION_TRADEABLE, from, to, amount);
        }
        emit ForcedTransfer(from, to, amount, reason);
    }

    function recoverTokens(address lostWallet, address newWallet) external onlyRole(COMPLIANCE_ROLE) {
        require(identityRegistry.isVerified(newWallet), "SURA: new wallet not verified");
        uint256 amount = balanceOf(lostWallet);
        require(amount > 0, "SURA: no tokens to recover");
        _updateInvestorIndex(lostWallet);
        _updateInvestorIndex(newWallet);
        uint256 locked    = _partitionBalances[lostWallet][PARTITION_LOCKED];
        uint256 vesting   = _partitionBalances[lostWallet][PARTITION_VESTING];
        uint256 tradeable = _partitionBalances[lostWallet][PARTITION_TRADEABLE];
        if (locked > 0)    _transferByPartition(PARTITION_LOCKED, lostWallet, newWallet, locked);
        if (vesting > 0)   _transferByPartition(PARTITION_VESTING, lostWallet, newWallet, vesting);
        if (tradeable > 0) _transferByPartition(PARTITION_TRADEABLE, lostWallet, newWallet, tradeable);
        if (_lockupExpiry[newWallet] < _lockupExpiry[lostWallet])
            _lockupExpiry[newWallet] = _lockupExpiry[lostWallet];
        _pendingClaims[newWallet] += _pendingClaims[lostWallet];
        _pendingClaims[lostWallet] = 0;
        emit TokensRecovered(lostWallet, newWallet, amount);
    }

    // Lifecycle
    function pause(string calldata reason) external onlyRole(COMPLIANCE_ROLE) {
        pauseReason = reason;
        _pause();
        emit STOPaused(reason);
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        pauseReason = "";
        _unpause();
        emit STOResumed();
    }

    function closeOffering() external onlyRole(ISSUER_ROLE) {
        require(!offeringClosed, "SURA: already closed");
        offeringClosed = true;
        emit OfferingClosed(_totalRaised, totalSupply());
    }

    function enableRedemption() external onlyRole(DEFAULT_ADMIN_ROLE) {
        redemptionEnabled = true;
        emit RedemptionEnabled();
    }

    function redeem(uint256 amount) external nonReentrant whenNotPaused {
        require(redemptionEnabled, "SURA: redemption not enabled");
        require(_partitionBalances[msg.sender][PARTITION_TRADEABLE] >= amount, "SURA: insufficient tradeable balance");
        require(identityRegistry.isVerified(msg.sender), "SURA: not verified");
        uint256 usdcAmount = (amount * _config.tokenPrice) / 1e18;
        require(usdc.balanceOf(address(this)) >= usdcAmount, "SURA: insufficient USDC");
        _updateInvestorIndex(msg.sender);
        _burnByPartition(PARTITION_TRADEABLE, msg.sender, amount);
        require(usdc.transfer(msg.sender, usdcAmount), "SURA: USDC transfer failed");
        emit Redeemed(msg.sender, msg.sender, amount, "");
    }

    // Distributions
    function processDistribution(uint256 totalUSDC) external onlyRole(ISSUER_ROLE) nonReentrant {
        require(totalSupply() > 0, "SURA: no tokens outstanding");
        require(totalUSDC > 0, "SURA: zero distribution");
        require(usdc.transferFrom(msg.sender, address(this), totalUSDC), "SURA: USDC transfer failed");
        uint256 increment = (totalUSDC * 1e18) / totalSupply();
        _distributionIndex += increment;
        emit DistributionProcessed(totalUSDC, increment, uint48(block.timestamp));
    }

    function claimDistribution() external nonReentrant whenNotPaused {
        _updateInvestorIndex(msg.sender);
        uint256 amount = _pendingClaims[msg.sender];
        require(amount > 0, "SURA: nothing to claim");
        _pendingClaims[msg.sender] = 0;
        require(usdc.transfer(msg.sender, amount), "SURA: claim transfer failed");
    }

    function pendingDistribution(address investor) external view returns (uint256) {
        uint256 delta = _distributionIndex - _investorIndex[investor];
        return _pendingClaims[investor] + (balanceOf(investor) * delta) / 1e18;
    }

    // ERC-20 override — enforce compliance
    function _update(address from, address to, uint256 amount)
        internal override(ERC20, ERC20Pausable)
    {
        if (from != address(0) && to != address(0)) {
            require(identityRegistry.canTransfer(from, to), "SURA: transfer not compliant");
            require(balanceOf(from) - _frozenTokens[from] >= amount, "SURA: insufficient unfrozen balance");
            _updateInvestorIndex(from);
            _updateInvestorIndex(to);
        }
        super._update(from, to, amount);
    }

    // Internal helpers
    function _mintByPartition(bytes32 partition, address to, uint256 amount) internal {
        _mint(to, amount);
        _partitionBalances[to][partition]  += amount;
        _partitionTotalSupply[partition]   += amount;
    }

    function _burnByPartition(bytes32 partition, address from, uint256 amount) internal {
        _burn(from, amount);
        _partitionBalances[from][partition] -= amount;
        _partitionTotalSupply[partition]    -= amount;
    }

    function _transferByPartition(bytes32 partition, address from, address to, uint256 amount) internal {
        _transfer(from, to, amount);
        _partitionBalances[from][partition] -= amount;
        _partitionBalances[to][partition]   += amount;
    }

    function _updateInvestorIndex(address investor) internal {
        uint256 delta = _distributionIndex - _investorIndex[investor];
        if (delta > 0 && balanceOf(investor) > 0)
            _pendingClaims[investor] += (balanceOf(investor) * delta) / 1e18;
        _investorIndex[investor] = _distributionIndex;
    }

    // Read functions
    function getConfig()                  external view returns (STOConfig memory) { return _config; }
    function frozenBalance(address i)     external view returns (uint256) { return _frozenTokens[i]; }
    function isFrozen(address i)          external view returns (bool)    { return _frozenTokens[i] > 0; }
    function totalRaised()                external view returns (uint256) { return _totalRaised; }
    function investorCount()              external view returns (uint256) { return _investorCount; }
    function getInvestorAt(uint256 index) external view returns (address) { return _investorList[index]; }
    function decimals() public pure override returns (uint8) { return 18; }
}
