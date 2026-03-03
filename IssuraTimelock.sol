// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title IssuraTimelock
 * @notice 48-hour timelock for all critical Issura admin operations.
 *
 * Critical operations protected by this timelock:
 *   - Granting / revoking DEFAULT_ADMIN_ROLE on any contract
 *   - setCountryAllowed() on IdentityRegistry
 *   - pause() / unpause() on IdentityRegistry
 *   - upgrading or replacing any core contract address
 *
 * Operations that do NOT require timelock (immediate execution):
 *   - registerIdentity() — KYC approval must be fast
 *   - suspendIdentity() — compliance freeze must be immediate
 *   - forcedTransfer() — regulatory action must be immediate
 *   - freezeTokens() — compliance action must be immediate
 *   - processDistribution() — investor payments must not be delayed
 *
 * @dev Standard OZ TimelockController with 48-hour minimum delay.
 *      Proposers: platform multisig
 *      Executors: platform multisig (after delay)
 *      Cancellers: platform multisig (emergency cancel)
 */
contract IssuraTimelock is TimelockController {

    uint256 public constant MIN_DELAY = 48 hours;

    /**
     * @param proposers  Addresses that can schedule operations (multisig)
     * @param executors  Addresses that can execute after delay (multisig)
     * @param admin      Initial admin (set to address(0) after setup for full decentralisation)
     */
    constructor(
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(MIN_DELAY, proposers, executors, admin) {}
}
