// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IIdentityRegistry
 * @notice Interface for the Issura identity and compliance registry.
 *         Every investor must be registered and verified before they can
 *         receive or transfer security tokens. Implements core ERC-3643
 *         compliance hooks.
 */
interface IIdentityRegistry {
    // ── Events ─────────────────────────────────────────────────────────────

    event IdentityRegistered(address indexed investor, uint16 country, uint8 tier);
    event IdentityRemoved(address indexed investor);
    event IdentityVerified(address indexed investor);
    event IdentitySuspended(address indexed investor, string reason);
    event CountryAllowed(uint16 indexed country);
    event CountryBlocked(uint16 indexed country);

    // ── Enums ──────────────────────────────────────────────────────────────

    enum VerificationTier {
        NONE,           // 0 — not registered
        PENDING,        // 1 — submitted, awaiting review
        ACCREDITED,     // 2 — verified accredited investor
        INSTITUTIONAL,  // 3 — institutional / qualified buyer
        SUSPENDED       // 4 — suspended (AML/compliance hold)
    }

    // ── Structs ────────────────────────────────────────────────────────────

    struct Identity {
        address wallet;
        uint16 country;         // ISO 3166-1 numeric (702 = SGP, 458 = MYS, 360 = IDN)
        VerificationTier tier;
        uint48 verifiedAt;      // unix timestamp
        uint48 expiresAt;       // annual re-verification deadline
        bytes32 kycHash;        // hash of off-chain KYC data (privacy-preserving)
        bool amlClear;
    }

    // ── Read ───────────────────────────────────────────────────────────────

    function isVerified(address investor) external view returns (bool);
    function getIdentity(address investor) external view returns (Identity memory);
    function isCountryAllowed(uint16 country) external view returns (bool);
    function canTransfer(address from, address to) external view returns (bool);

    // ── Write ──────────────────────────────────────────────────────────────

    function registerIdentity(
        address investor,
        uint16 country,
        VerificationTier tier,
        bytes32 kycHash
    ) external;

    function verifyIdentity(address investor) external;
    function suspendIdentity(address investor, string calldata reason) external;
    function removeIdentity(address investor) external;
    function setCountryAllowed(uint16 country, bool allowed) external;
    function updateKycExpiry(address investor, uint48 newExpiry) external;
}
