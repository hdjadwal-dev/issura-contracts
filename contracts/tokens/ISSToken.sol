// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ISSToken
 * @notice Issura Platform Utility Token (ISS)
 *
 *   Fixed supply: 100,000,000 ISS (no mint after deployment)
 *   Non-security: confers no ownership, dividends, or governance rights
 *   over platform revenues. Utility only — fee discounts and staking.
 *
 *   Utility functions:
 *   1. Fee discounts: pay issuance fees in ISS → 20-50% discount
 *   2. Staking: lock ISS → earn platform credits, priority queue access
 *   3. Burn: 20% of ISS used for fees is burned (deflationary)
 *
 *   Token allocation (set at deploy, distributed by admin):
 *   - 50% Liquidity provision (50M)
 *   - 25% Ecosystem & growth fund (25M)
 *   - 15% Team & advisors — vested (15M)
 *   - 10% Strategic partnerships & reserve (10M)
 */
contract ISSToken is ERC20, AccessControl, ReentrancyGuard {

    // ── Roles ──────────────────────────────────────────────────────────────
    bytes32 public constant PLATFORM_ROLE = keccak256("PLATFORM_ROLE");

    // ── Constants ──────────────────────────────────────────────────────────
    uint256 public constant MAX_SUPPLY     = 100_000_000 * 1e18;
    uint256 public constant BURN_RATE_BPS  = 2000; // 20% of fees paid in ISS

    // ── Staking ────────────────────────────────────────────────────────────
    struct Stake {
        uint256 amount;
        uint48  stakedAt;
        uint48  lockUntil;   // 3, 6, or 12 month options
        uint48  lastReward;
        bool    active;
    }

    mapping(address => Stake) public stakes;
    uint256 public totalStaked;
    uint256 public constant EARLY_UNSTAKE_PENALTY_BPS = 2500; // 25% slashed to burn

    // Staking lock durations
    uint48 public constant LOCK_3M  = 90  days;
    uint48 public constant LOCK_6M  = 180 days;
    uint48 public constant LOCK_12M = 365 days;

    // ── Vesting (team/advisor allocation) ─────────────────────────────────
    struct VestingSchedule {
        uint256 total;
        uint256 claimed;
        uint48  cliffEnd;
        uint48  vestEnd;
        bool    active;
    }
    mapping(address => VestingSchedule) public vestingSchedules;

    // ── Fee discount tiers ─────────────────────────────────────────────────
    // Staked amount thresholds for fee discount tiers
    uint256 public constant TIER1_STAKE =  1_000 * 1e18; // 20% discount
    uint256 public constant TIER2_STAKE =  5_000 * 1e18; // 35% discount
    uint256 public constant TIER3_STAKE = 10_000 * 1e18; // 50% discount

    // ── Events ─────────────────────────────────────────────────────────────
    event Staked(address indexed user, uint256 amount, uint48 lockUntil);
    event Unstaked(address indexed user, uint256 amount, uint256 penalty);
    event RewardClaimed(address indexed user, uint256 creditAmount);
    event TokensBurned(address indexed from, uint256 amount, string reason);
    event VestingCreated(address indexed beneficiary, uint256 total, uint48 cliffEnd, uint48 vestEnd);
    event VestingClaimed(address indexed beneficiary, uint256 amount);

    // ── Constructor ────────────────────────────────────────────────────────
    constructor(
        address admin,
        address liquidityWallet,    // 50M — immediate
        address ecosystemWallet,    // 25M — linear 36 months
        address teamWallet,         // 15M — 12mo cliff + 36mo vest (held in contract)
        address partnershipWallet   // 10M — locked 24 months (held in contract)
    ) ERC20("Issura Utility Token", "ISS") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PLATFORM_ROLE, admin);

        // Mint total supply to this contract first — distribute from here
        _mint(address(this), MAX_SUPPLY);

        // 1. Liquidity (50M) — transfer immediately to liquidity wallet
        _transfer(address(this), liquidityWallet, 50_000_000 * 1e18);

        // 2. Ecosystem fund (25M) — transfer immediately; managed off-chain with multi-sig
        _transfer(address(this), ecosystemWallet, 25_000_000 * 1e18);

        // 3. Team (15M) — stays in contract; 12 month cliff, then 36 month linear vest
        // Do NOT transfer to teamWallet — claimVested() releases from contract
        vestingSchedules[teamWallet] = VestingSchedule({
            total:    15_000_000 * 1e18,
            claimed:  0,
            cliffEnd: uint48(block.timestamp) + 365 days,
            vestEnd:  uint48(block.timestamp) + 365 days + 3 * 365 days,
            active:   true
        });
        emit VestingCreated(teamWallet, 15_000_000 * 1e18,
            uint48(block.timestamp) + 365 days,
            uint48(block.timestamp) + 4 * 365 days);

        // 4. Partnerships & reserve (10M) — stays in contract; locked 24 months then linear 24 months
        // Do NOT transfer to partnershipWallet — claimVested() releases from contract
        vestingSchedules[partnershipWallet] = VestingSchedule({
            total:    10_000_000 * 1e18,
            claimed:  0,
            cliffEnd: uint48(block.timestamp) + 2 * 365 days,
            vestEnd:  uint48(block.timestamp) + 4 * 365 days,
            active:   true
        });
        emit VestingCreated(partnershipWallet, 10_000_000 * 1e18,
            uint48(block.timestamp) + 2 * 365 days,
            uint48(block.timestamp) + 4 * 365 days);

        // Sanity check: contract holds exactly vested portion (25M)
        // 50M liquidity + 25M ecosystem already sent out; 25M remains for vesting
        require(
            balanceOf(address(this)) == 25_000_000 * 1e18,
            "ISS: vesting balance mismatch"
        );
    }

    // ── Staking ────────────────────────────────────────────────────────────

    /**
     * @notice Stake ISS tokens for platform benefits.
     * @param amount    ISS amount to stake (18 decimals)
     * @param lockDays  Lock period: 90, 180, or 365 days
     */
    function stake(uint256 amount, uint48 lockDays) external nonReentrant {
        require(amount > 0, "ISS: zero amount");
        require(
            lockDays == LOCK_3M || lockDays == LOCK_6M || lockDays == LOCK_12M,
            "ISS: invalid lock period"
        );
        require(!stakes[msg.sender].active, "ISS: already staking (unstake first)");
        require(balanceOf(msg.sender) >= amount, "ISS: insufficient balance");

        _transfer(msg.sender, address(this), amount);
        stakes[msg.sender] = Stake({
            amount:     amount,
            stakedAt:   uint48(block.timestamp),
            lockUntil:  uint48(block.timestamp) + lockDays,
            lastReward: uint48(block.timestamp),
            active:     true
        });
        totalStaked += amount;

        emit Staked(msg.sender, amount, uint48(block.timestamp) + lockDays);
    }

    /**
     * @notice Unstake ISS. Early unstake incurs 25% penalty burned.
     */
    function unstake() external nonReentrant {
        Stake storage s = stakes[msg.sender];
        require(s.active, "ISS: no active stake");

        uint256 amount = s.amount;
        uint256 penalty = 0;

        if (block.timestamp < s.lockUntil) {
            // Early unstake: 25% slashed
            penalty = (amount * EARLY_UNSTAKE_PENALTY_BPS) / 10000;
            _burn(address(this), penalty);
            emit TokensBurned(msg.sender, penalty, "early_unstake_penalty");
        }

        uint256 returned = amount - penalty;
        s.active = false;
        s.amount = 0;
        totalStaked -= amount;

        _transfer(address(this), msg.sender, returned);
        emit Unstaked(msg.sender, returned, penalty);
    }

    // ── Fee discount query ─────────────────────────────────────────────────

    /**
     * @notice Returns the fee discount (in BPS) for a given address based on stake.
     * @return discountBps  0 = no discount, 2000 = 20%, 3500 = 35%, 5000 = 50%
     */
    function getFeeDiscount(address user) external view returns (uint256 discountBps) {
        Stake storage s = stakes[user];
        if (!s.active) return 0;
        if (s.amount >= TIER3_STAKE) return 5000;
        if (s.amount >= TIER2_STAKE) return 3500;
        if (s.amount >= TIER1_STAKE) return 2000;
        return 0;
    }

    /**
     * @notice Check if user has priority queue access (≥10,000 ISS staked for ≥6 months)
     */
    function hasPriorityAccess(address user) external view returns (bool) {
        Stake storage s = stakes[user];
        return s.active &&
               s.amount >= TIER3_STAKE &&
               s.lockUntil >= uint48(block.timestamp) + LOCK_6M;
    }

    // ── Platform fee burn (called by platform on fee settlement in ISS) ────

    /**
     * @notice Platform calls this when a user pays fees in ISS.
     *         Burns 20% of the ISS used; remaining 80% goes to ecosystem pool.
     * @param from    User paying fees in ISS
     * @param amount  Total ISS used for fee payment
     */
    function processFeePayment(address from, uint256 amount)
        external onlyRole(PLATFORM_ROLE)
    {
        require(balanceOf(from) >= amount, "ISS: insufficient balance for fee");

        uint256 burnAmount = (amount * BURN_RATE_BPS) / 10000; // 20%
        uint256 recycleAmount = amount - burnAmount;            // 80%

        // Pull from user
        _transfer(from, address(this), amount);

        // Burn 20%
        _burn(address(this), burnAmount);
        emit TokensBurned(from, burnAmount, "fee_payment");

        // Recycle 80% stays in contract as ecosystem/staking pool
        // (distributed via off-chain snapshot + airdrop for simplicity at MVP)
    }

    // ── Vesting ────────────────────────────────────────────────────────────

    /**
     * @notice Claim vested tokens (team/advisor/partnership wallets).
     */
    function claimVested() external nonReentrant {
        VestingSchedule storage v = vestingSchedules[msg.sender];
        require(v.active, "ISS: no vesting schedule");
        require(block.timestamp >= v.cliffEnd, "ISS: cliff not reached");

        uint256 vested = _vestedAmount(v);
        uint256 claimable = vested - v.claimed;
        require(claimable > 0, "ISS: nothing to claim");

        v.claimed += claimable;
        _transfer(address(this), msg.sender, claimable);
        emit VestingClaimed(msg.sender, claimable);
    }

    function _vestedAmount(VestingSchedule storage v)
        internal view returns (uint256)
    {
        if (block.timestamp < v.cliffEnd) return 0;
        if (block.timestamp >= v.vestEnd) return v.total;
        uint256 elapsed = block.timestamp - v.cliffEnd;
        uint256 duration = v.vestEnd - v.cliffEnd;
        return (v.total * elapsed) / duration;
    }

    function vestedAmount(address beneficiary) external view returns (uint256) {
        VestingSchedule storage v = vestingSchedules[beneficiary];
        if (!v.active) return 0;
        return _vestedAmount(v);
    }

    // ── Admin ──────────────────────────────────────────────────────────────

    function grantPlatformRole(address account)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _grantRole(PLATFORM_ROLE, account);
    }
}
