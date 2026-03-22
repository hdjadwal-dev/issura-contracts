// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/IIdentityRegistry.sol";

/**
 * @title IdentityRegistry
 * @notice On-chain KYC/AML registry for Issura platform.
 *
 *   - Compliance officers register and verify investor identities
 *   - Each identity stores country, tier, KYC hash, and expiry
 *   - Transfer compliance checks query this registry
 *   - Country allow-list enforces ASEAN geo-fencing
 *   - Supports annual re-verification (MAS requirement)
 *
 * @dev Role hierarchy:
 *   DEFAULT_ADMIN_ROLE  — platform deployer, can grant/revoke roles
 *   COMPLIANCE_ROLE     — KYC officers, can register/verify/suspend
 *   AGENT_ROLE          — token contracts, can call canTransfer()
 */
contract IdentityRegistry is IIdentityRegistry, AccessControl, Pausable {

    // ── Roles ──────────────────────────────────────────────────────────────
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    bytes32 public constant AGENT_ROLE      = keccak256("AGENT_ROLE");

    // ── Storage ────────────────────────────────────────────────────────────
    mapping(address => Identity) private _identities;
    mapping(uint16 => bool) private _allowedCountries;
    address[] private _investors;              // ordered list for enumeration
    mapping(address => uint256) private _investorIndex; // investor => index in _investors

    // ── Constructor ────────────────────────────────────────────────────────
    constructor(address admin, address complianceOfficer) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, complianceOfficer);

        // Pre-allow core ASEAN countries (ISO 3166-1 numeric)
        _allowedCountries[702] = true; // Singapore
        _allowedCountries[458] = true; // Malaysia
        _allowedCountries[360] = true; // Indonesia
        _allowedCountries[764] = true; // Thailand
        _allowedCountries[608] = true; // Philippines
        _allowedCountries[704] = true; // Vietnam
        _allowedCountries[784] = true; // UAE (common HNWI source)
        _allowedCountries[826] = true; // UK
        _allowedCountries[344] = true; // Hong Kong

        emit CountryAllowed(702);
        emit CountryAllowed(458);
        emit CountryAllowed(360);
        emit CountryAllowed(764);
        emit CountryAllowed(608);
        emit CountryAllowed(704); // Vietnam
        emit CountryAllowed(784); // UAE
        emit CountryAllowed(826); // UK
        emit CountryAllowed(344); // Hong Kong
    }

    // ── Compliance officer functions ───────────────────────────────────────

    /**
     * @notice Register a new investor identity (post-KYC approval off-chain)
     * @param investor  Wallet address
     * @param country   ISO 3166-1 numeric country code
     * @param tier      Verification tier (ACCREDITED / INSTITUTIONAL)
     * @param kycHash   keccak256 of off-chain KYC document bundle (privacy-preserving audit trail)
     */
    function registerIdentity(
        address investor,
        uint16 country,
        VerificationTier tier,
        bytes32 kycHash
    ) external override onlyRole(COMPLIANCE_ROLE) whenNotPaused {
        require(investor != address(0), "IR: zero address");
        require(_allowedCountries[country], "IR: country not allowed");
        require(tier != VerificationTier.NONE && tier != VerificationTier.PENDING, "IR: invalid tier");
        require(_identities[investor].wallet == address(0), "IR: already registered");

        uint48 now48 = uint48(block.timestamp);
        _identities[investor] = Identity({
            wallet:     investor,
            country:    country,
            tier:       tier,
            verifiedAt: now48,
            expiresAt:  now48 + 365 days,   // annual re-verification
            kycHash:    kycHash,
            amlClear:   true
        });
        _investorIndex[investor] = _investors.length;
        _investors.push(investor);

        emit IdentityRegistered(investor, country, uint8(tier));
        emit IdentityVerified(investor);
    }

    /**
     * @notice Mark an existing identity as verified (ACCREDITED tier).
     */
    function verifyIdentity(address investor)
        external override onlyRole(COMPLIANCE_ROLE) whenNotPaused
    {
        Identity storage id = _identities[investor];
        require(id.wallet != address(0), "IR: not registered");
        id.tier = VerificationTier.ACCREDITED;
        id.verifiedAt = uint48(block.timestamp);
        id.expiresAt  = uint48(block.timestamp) + 365 days;
        emit IdentityVerified(investor);
    }

    /**
     * @notice Upgrade investor to INSTITUTIONAL tier.
     * @dev    Separate function to avoid accidental tier downgrade.
     */
    function upgradeToInstitutional(address investor)
        external onlyRole(COMPLIANCE_ROLE) whenNotPaused
    {
        Identity storage id = _identities[investor];
        require(id.wallet != address(0),                      "IR: not registered");
        require(id.tier == VerificationTier.ACCREDITED,       "IR: not accredited");
        id.tier = VerificationTier.INSTITUTIONAL;
        emit IdentityVerified(investor);
    }

    /**
     * @notice Set AML clear status for an investor.
     * @dev    Setting to false immediately blocks all transfers for this investor.
     */
    function setAmlClear(address investor, bool clear)
        external onlyRole(COMPLIANCE_ROLE)
    {
        require(_identities[investor].wallet != address(0), "IR: not registered");
        _identities[investor].amlClear = clear;
        if (!clear) emit IdentitySuspended(investor, "AML flag raised");
    }

    /**
     * @notice Suspend investor — freezes all transfer capability
     * @param reason  Human-readable reason (stored in event for audit trail)
     */
    function suspendIdentity(address investor, string calldata reason)
        external override onlyRole(COMPLIANCE_ROLE)
    {
        Identity storage id = _identities[investor];
        require(id.wallet != address(0), "IR: not registered");
        id.tier = VerificationTier.SUSPENDED;
        emit IdentitySuspended(investor, reason);
    }

    /**
     * @notice Remove identity entirely (GDPR right-to-erasure — removes on-chain pointer, off-chain data purged separately)
     */
    function removeIdentity(address investor)
        external override onlyRole(COMPLIANCE_ROLE)
    {
        require(_identities[investor].wallet != address(0), "IR: not registered");

        // Swap-and-pop to remove from _investors array — O(1)
        uint256 idx  = _investorIndex[investor];
        uint256 last = _investors.length - 1;
        if (idx != last) {
            address lastInvestor    = _investors[last];
            _investors[idx]         = lastInvestor;
            _investorIndex[lastInvestor] = idx;
        }
        _investors.pop();
        delete _investorIndex[investor];
        delete _identities[investor];

        emit IdentityRemoved(investor);
    }

    /**
     * @notice Update KYC expiry after annual re-verification
     */
    function updateKycExpiry(address investor, uint48 newExpiry)
        external override onlyRole(COMPLIANCE_ROLE)
    {
        require(_identities[investor].wallet != address(0), "IR: not registered");
        require(newExpiry > block.timestamp, "IR: expiry in past");
        _identities[investor].expiresAt = newExpiry;
    }

    /**
     * @notice Toggle country allow-list
     */
    function setCountryAllowed(uint16 country, bool allowed)
        external override onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _allowedCountries[country] = allowed;
        if (allowed) emit CountryAllowed(country);
        else emit CountryBlocked(country);
    }

    // ── Read functions ─────────────────────────────────────────────────────

    function isVerified(address investor) public view override returns (bool) {
        Identity storage id = _identities[investor];
        return
            id.wallet != address(0) &&
            (id.tier == VerificationTier.ACCREDITED || id.tier == VerificationTier.INSTITUTIONAL) &&
            id.amlClear &&
            id.expiresAt > block.timestamp;
    }

    function getIdentity(address investor)
        external view override returns (Identity memory)
    {
        return _identities[investor];
    }

    function isCountryAllowed(uint16 country)
        external view override returns (bool)
    {
        return _allowedCountries[country];
    }

    /**
     * @notice Core compliance check called by token contracts before every transfer
     * @return bool  Whether transfer is permitted
     */
    function canTransfer(address from, address to)
        external view override returns (bool)
    {
        // Minting (from == 0) only requires receiver to be verified
        if (from == address(0)) return isVerified(to);
        // Burning (to == 0) always allowed for compliance-triggered burns
        if (to == address(0)) return true;
        return isVerified(from) && isVerified(to);
    }

    // ── Admin ──────────────────────────────────────────────────────────────


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
        require(gnosisSafe != address(0),    "IR: zero safe");
        require(gnosisSafe != msg.sender,     "IR: same address");
        _grantRole(DEFAULT_ADMIN_ROLE, gnosisSafe);
        renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    function investorCount() external view returns (uint256) {
        return _investors.length;
    }

    function getInvestorAt(uint256 index) external view returns (address) {
        return _investors[index];
    }
}
