// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IIdentityRegistry.sol";
import "../interfaces/ISecurityToken.sol";
import "../interfaces/ISURAInvestable.sol";

/**
 * @title IssuraSecurityToken
 * @notice ERC-3643 compliant security token for a single STO.
 *
 *   Each STO on the Issura platform deploys its own instance of this
 *   contract via the STOFactory. Tokens represent fractional ownership
 *   of the underlying real-world asset.
 *
 *   Key compliance features:
 *   - Every transfer validated against IdentityRegistry
 *   - Geo-fencing: only investors in allowed countries
 *   - Forced transfer / freeze for regulatory compliance
 *   - USDC-based distribution with per-token claim model
 *   - Pausable for emergency or regulatory holds
 *
 * @dev Roles:
 *   DEFAULT_ADMIN_ROLE — platform admin
 *   COMPLIANCE_ROLE    — compliance officers (freeze, force transfer)
 *   ISSUER_ROLE        — issuer (process distributions)
 *   AGENT_ROLE         — platform agent (mint during investment)
 */
contract IssuraSecurityToken is
    ERC20,
    ERC20Pausable,
    AccessControl,
    ReentrancyGuard,
    ISecurityToken,
    ISURAInvestable
{
    // ── Roles ──────────────────────────────────────────────────────────────
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant ISSUER_ROLE     = keccak256("ISSUER_ROLE");
    bytes32 public constant AGENT_ROLE      = keccak256("AGENT_ROLE");

    // ── Interfaces ─────────────────────────────────────────────────────────
    IIdentityRegistry public immutable identityRegistry;
    IERC20 public immutable usdc; // USDC on Arbitrum: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831

    // ── STO Config ─────────────────────────────────────────────────────────
    STOConfig private _config;
    bool public offeringClosed;
    string public pauseReason;

    // ── Investor tracking ──────────────────────────────────────────────────
    mapping(address => uint256) private _frozenTokens;
    mapping(address => bool) private _isInvestor;
    address[] private _investorList;
    uint256 private _investorCount;
    uint256 private _totalRaised; // in USDC (6 decimals)

    // ── Distribution state ─────────────────────────────────────────────────
    // Uses a "dividend per share" accumulator pattern — O(1) claims
    uint256 private _distributionIndex;           // scaled by 1e18
    mapping(address => uint256) private _investorIndex;
    mapping(address => uint256) private _pendingClaims;

    // ── Events (additional to interface) ───────────────────────────────────
    event Investment(address indexed investor, uint256 usdcAmount, uint256 tokens);
    event OfferingClosed(uint256 totalRaised, uint256 totalTokens);

    // ── Constructor ────────────────────────────────────────────────────────
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

    // ── Investment ─────────────────────────────────────────────────────────

    /**
     * @notice Investor purchases tokens during the offering period.
     * @param investor   Verified investor wallet (for token minting and compliance checks)
     * @param usdcAmount Amount of USDC to invest (6 decimals)
     *
     * Flow (called by STOFactory which already holds the USDC):
     *   1. Compliance check (identity registry)
     *   2. Calculate tokens from USDC / tokenPrice
     *   3. Pull USDC from msg.sender (factory) — factory already received it from investor
     *   4. Deduct platform fee → fee treasury
     *   5. Forward net proceeds → issuer treasury
     *   6. Mint security tokens to investor
     */
    function invest(address investor, uint256 usdcAmount)
        external
        onlyRole(AGENT_ROLE)
        whenNotPaused
        nonReentrant
    {
        require(!offeringClosed, "ST: offering closed");
        require(block.timestamp <= _config.closingDate, "ST: offering expired");
        require(
            identityRegistry.canTransfer(address(0), investor),
            "ST: investor not verified"
        );

        uint256 tokens = (usdcAmount * 1e18) / _config.tokenPrice;
        require(tokens >= _config.minInvestment, "ST: below minimum investment");
        require(totalSupply() + tokens <= _config.maxSupply, "ST: exceeds max supply");

        // Platform fee deduction
        uint256 fee        = (usdcAmount * _config.feeBps) / 10000;
        uint256 netProceeds = usdcAmount - fee;

        // Pull total USDC from factory (factory already received it from investor)
        // Factory approves this contract before calling invest()
        require(
            usdc.transferFrom(msg.sender, address(this), usdcAmount),
            "ST: USDC pull failed"
        );

        // Forward fee to platform treasury
        require(
            usdc.transfer(_config.treasury, fee),
            "ST: fee transfer failed"
        );

        // Forward net proceeds to issuer treasury
        require(
            usdc.transfer(_config.issuer, netProceeds),
            "ST: proceeds transfer failed"
        );

        // Update distribution index for new investor before minting
        _updateInvestorIndex(investor);

        // Mint tokens
        _mint(investor, tokens);
        _totalRaised += usdcAmount;

        // Track investor
        if (!_isInvestor[investor]) {
            _isInvestor[investor] = true;
            _investorList.push(investor);
            _investorCount++;
        }

        emit Investment(investor, usdcAmount, tokens);
    }

    // ── Compliance Transfer Hooks ──────────────────────────────────────────

    /**
     * @dev Override ERC20 _update to enforce compliance on every transfer.
     *      Called by transfer(), transferFrom(), mint(), burn().
     */
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Pausable)
    {
        // Skip compliance checks for minting/burning (handled at call site)
        if (from != address(0) && to != address(0)) {
            require(
                identityRegistry.canTransfer(from, to),
                "ST: transfer not compliant"
            );
            // Respect frozen balances
            require(
                balanceOf(from) - _frozenTokens[from] >= amount,
                "ST: insufficient unfrozen balance"
            );
            // Update distribution indices before balance changes
            _updateInvestorIndex(from);
            _updateInvestorIndex(to);
        }
        super._update(from, to, amount);
    }

    // ── Compliance Functions ───────────────────────────────────────────────

    function forcedTransfer(
        address from,
        address to,
        uint256 amount,
        string calldata reason
    ) external override onlyRole(COMPLIANCE_ROLE) {
        require(balanceOf(from) >= amount, "ST: insufficient balance");
        _updateInvestorIndex(from);
        _updateInvestorIndex(to);
        _transfer(from, to, amount);
        emit ForcedTransfer(from, to, amount, reason);
    }

    function freezeTokens(address investor, uint256 amount)
        external override onlyRole(COMPLIANCE_ROLE)
    {
        require(balanceOf(investor) >= _frozenTokens[investor] + amount, "ST: insufficient balance");
        _frozenTokens[investor] += amount;
        emit TokensFrozen(investor, amount);
    }

    function unfreezeTokens(address investor, uint256 amount)
        external override onlyRole(COMPLIANCE_ROLE)
    {
        require(_frozenTokens[investor] >= amount, "ST: insufficient frozen");
        _frozenTokens[investor] -= amount;
        emit TokensUnfrozen(investor, amount);
    }

    /**
     * @notice Recover tokens from a lost/compromised wallet to a new verified wallet.
     *         Requires both old wallet suspension and new wallet verification.
     */
    function recoverTokens(address lostWallet, address newWallet)
        external override onlyRole(COMPLIANCE_ROLE)
    {
        require(identityRegistry.isVerified(newWallet), "ST: new wallet not verified");
        uint256 amount = balanceOf(lostWallet);
        require(amount > 0, "ST: no tokens to recover");
        _updateInvestorIndex(lostWallet);
        _updateInvestorIndex(newWallet);
        _transfer(lostWallet, newWallet, amount);
        // Transfer any pending distributions
        _pendingClaims[newWallet] += _pendingClaims[lostWallet];
        _pendingClaims[lostWallet] = 0;
        emit TokensRecovered(lostWallet, newWallet, amount);
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────

    function pause(string calldata reason) external override onlyRole(COMPLIANCE_ROLE) {
        pauseReason = reason;
        _pause();
        emit STOPaused(reason);
    }

    function unpause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        pauseReason = "";
        _unpause();
        emit STOResumed();
    }

    function closeOffering() external override onlyRole(ISSUER_ROLE) {
        require(!offeringClosed, "ST: already closed");
        offeringClosed = true;
        emit OfferingClosed(_totalRaised, totalSupply());
    }

    /**
     * @notice Admin override to force-close offering.
     * @dev    Used if issuer wallet is compromised or non-cooperative.
     *         Requires DEFAULT_ADMIN_ROLE (Gnosis Safe 2-of-3).
     */
    function adminCloseOffering()
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(!offeringClosed, "ST: already closed");
        offeringClosed = true;
        emit OfferingClosed(_totalRaised, totalSupply());
    }

    // ── Distributions ──────────────────────────────────────────────────────

    /**
     * @notice Issuer deposits USDC yield/rent/dividends for all token holders.
     *         Uses accumulator pattern: O(1) deposit, O(1) claim per investor.
     * @param totalUSDC  Total USDC to distribute (must be pre-approved)
     */
    function processDistribution(uint256 totalUSDC)
        external override onlyRole(ISSUER_ROLE) nonReentrant
    {
        require(totalSupply() > 0, "ST: no tokens outstanding");
        require(totalUSDC > 0, "ST: zero distribution");

        require(
            usdc.transferFrom(msg.sender, address(this), totalUSDC),
            "ST: USDC transfer failed"
        );

        // Increment global index: how much USDC per token (scaled 1e18)
        uint256 increment = (totalUSDC * 1e18) / totalSupply();
        _distributionIndex += increment;

        // perToken for event: scale totalUSDC by 1e18, divide by totalSupply (18-decimal tokens)
        // Result is in USDC base units (6 decimals) per full token
        uint256 perToken = (totalUSDC * 1e18) / totalSupply();
        emit DistributionProcessed(totalUSDC, perToken, uint48(block.timestamp));
    }

    /**
     * @notice Investor claims their share of accumulated distributions.
     */
    function claimDistribution() external override nonReentrant whenNotPaused {
        _updateInvestorIndex(msg.sender);
        uint256 amount = _pendingClaims[msg.sender];
        require(amount > 0, "ST: nothing to claim");
        _pendingClaims[msg.sender] = 0;
        require(usdc.transfer(msg.sender, amount), "ST: claim transfer failed");
    }

    /**
     * @notice View pending unclaimed distributions for an investor.
     */
    function pendingDistribution(address investor)
        external view override returns (uint256)
    {
        uint256 delta = _distributionIndex - _investorIndex[investor];
        uint256 accrued = (balanceOf(investor) * delta) / 1e18;
        return _pendingClaims[investor] + accrued;
    }

    // ── Internal ───────────────────────────────────────────────────────────

    function _updateInvestorIndex(address investor) internal {
        uint256 delta = _distributionIndex - _investorIndex[investor];
        if (delta > 0 && balanceOf(investor) > 0) {
            _pendingClaims[investor] += (balanceOf(investor) * delta) / 1e18;
        }
        _investorIndex[investor] = _distributionIndex;
    }

    // ── Read ───────────────────────────────────────────────────────────────

    function getConfig() external view override returns (STOConfig memory) {
        return _config;
    }

    function isFrozen(address investor) external view override returns (bool) {
        return _frozenTokens[investor] > 0;
    }

    function frozenBalance(address investor) external view override returns (uint256) {
        return _frozenTokens[investor];
    }

    function totalRaised() external view override returns (uint256) {
        return _totalRaised;
    }

    function investorCount() external view override returns (uint256) {
        return _investorCount;
    }

    function canTransfer(address from, address to, uint256 amount)
        external view override returns (bool, string memory)
    {
        if (paused()) return (false, "STO is paused");
        if (!identityRegistry.canTransfer(from, to)) return (false, "Compliance check failed");
        if (balanceOf(from) - _frozenTokens[from] < amount) return (false, "Insufficient unfrozen balance");
        return (true, "");
    }


    /**
     * @notice Transfer DEFAULT_ADMIN_ROLE to Gnosis Safe and renounce deployer admin.
     * @dev    MUST be called immediately after deployment.
     *         After this call ALL admin actions require Gnosis Safe 2-of-3 approval.
     *         This is irreversible — deployer loses all admin control permanently.
     * @param  gnosisSafe  Gnosis Safe multisig address (2-of-3)
     */
    function transferAdminToGnosisSafe(address gnosisSafe)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(gnosisSafe != address(0),    "ST: zero safe");
        require(gnosisSafe != msg.sender,     "ST: same address");
        _grantRole(DEFAULT_ADMIN_ROLE, gnosisSafe);
        renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }
}

