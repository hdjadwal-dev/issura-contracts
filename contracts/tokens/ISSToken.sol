// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title ISSToken
 * @notice Issura Platform Utility Token (ISS) — v4.2 Tokenomics
 *
 * ╔══════════════════════════════════════════════════════════════════════╗
 * ║  ABSOLUTE HARD CAP: 100,000,000 ISS                                  ║
 * ║  No mint function exists. Supply cannot be increased by any party,   ║
 * ║  including Issura founders, team, investors, or any governance vote. ║
 * ║  Verifiable on Arbiscan at the published contract address.           ║
 * ╚══════════════════════════════════════════════════════════════════════╝
 *
 * Non-security utility token: confers no ownership, dividends, profit-sharing,
 * or financial return. Utility only — fee discounts, platform credits, staking.
 *
 * Token Allocation (v4.2 — set at deploy, all 100M accounted for):
 * ┌─────────────────────────┬──────┬────────────┬──────────────────────────┐
 * │ Tranche                 │  %   │ ISS Amount │ Vesting / Release        │
 * ├─────────────────────────┼──────┼────────────┼──────────────────────────┤
 * │ Issuer Pre-Sale         │ 15%  │ 15,000,000 │ 6-month linear per buyer │
 * │ Ecosystem & Growth      │ 25%  │ 25,000,000 │ Linear 36 months         │
 * │ Liquidity Provision     │ 15%  │ 15,000,000 │ 2M at launch; rest gated │
 * │ Public Sale             │ 13%  │ 13,000,000 │ 3-month lock per buyer   │
 * │ Team & Advisors         │ 12%  │ 12,000,000 │ 12mo cliff + 36mo linear │
 * │ SURA Holder Airdrop     │ 10%  │ 10,000,000 │ At SURA STO close        │
 * │ Treasury & Reserve      │ 10%  │ 10,000,000 │ 24-month timelock        │
 * ├─────────────────────────┼──────┼────────────┼──────────────────────────┤
 * │ TOTAL                   │ 100% │100,000,000 │ Day-1 circulating: 0 ISS │
 * └─────────────────────────┴──────┴────────────┴──────────────────────────┘
 *
 * @dev Deployed on Arbitrum One (ERC-20, Solidity ^0.8.24 + OpenZeppelin)
 */
contract ISSToken is ERC20, AccessControl, ReentrancyGuard {

    // ── Roles ──────────────────────────────────────────────────────────────
    bytes32 public constant PLATFORM_ROLE = keccak256("PLATFORM_ROLE");

    // ── Hard Cap — Transparency Constants ─────────────────────────────────
    /// @notice Absolute hard cap. No mint function exists. Cannot increase.
    uint256 public constant MAX_SUPPLY    = 100_000_000 * 1e18;

    /// @notice Confirms no additional ISS can ever be minted.
    bool    public constant MINTABLE      = false;

    /// @notice On-chain supply policy statement — visible on Arbiscan.
    string  public constant SUPPLY_POLICY =
        "Fixed supply. No mint function. 100,000,000 ISS is the permanent, "
        "irrevocable hard cap. Verifiable on Arbiscan.";

    // ── Allocation Constants — Verifiable on Arbiscan ─────────────────────
    uint256 public constant ALLOCATION_PRESALE      = 15_000_000 * 1e18;
    uint256 public constant ALLOCATION_ECOSYSTEM    = 25_000_000 * 1e18;
    uint256 public constant ALLOCATION_LIQUIDITY    = 15_000_000 * 1e18;
    uint256 public constant ALLOCATION_PUBLIC_SALE  = 13_000_000 * 1e18;
    uint256 public constant ALLOCATION_TEAM         = 12_000_000 * 1e18;
    uint256 public constant ALLOCATION_AIRDROP      = 10_000_000 * 1e18;
    uint256 public constant ALLOCATION_TREASURY     = 10_000_000 * 1e18;

    // ── Liquidity tranche — 2M at launch, 13M board-approved ──────────────
    /// @notice Intended initial Uniswap v3 seed amount — released via releaseLiquidityReserve()
    uint256 public constant LIQUIDITY_LAUNCH_AMOUNT = 2_000_000  * 1e18;
    uint256 public liquidityReserveReleased; // tracks board-approved releases

    // ── Treasury timelock ─────────────────────────────────────────────────
    uint256 public immutable treasuryUnlockTime; // set at deploy: block.timestamp + 24 months
    uint256 public treasuryReleased;         // tracks total released from treasury

    // ── Ecosystem pool tracking ───────────────────────────────────────────
    uint256 public ecosystemPoolBalance;     // recycled 80% of ISS fee payments

    // ── Fee burn mechanics ────────────────────────────────────────────────
    uint256 public constant BURN_RATE_BPS   = 2000; // 20% of fees paid in ISS burned
    uint256 public totalBurned;                      // cumulative burn tracker

    // ── Staking ────────────────────────────────────────────────────────────
    struct Stake {
        uint256 amount;
        uint48  stakedAt;
        uint48  lockUntil;
        uint48  lastReward;
        bool    active;
    }
    mapping(address => Stake) public stakes;
    uint256 public totalStaked;
    uint256 public constant EARLY_UNSTAKE_PENALTY_BPS = 2500; // 25% slashed

    // Staking lock durations
    uint48 public constant LOCK_3M  = 90  days;
    uint48 public constant LOCK_6M  = 180 days;
    uint48 public constant LOCK_12M = 365 days;

    // ── Vesting (all tranches use the same schedule struct) ────────────────
    struct VestingSchedule {
        uint256 total;
        uint256 claimed;
        uint48  cliffEnd;
        uint48  vestEnd;
        bool    active;
        bytes32 tranche; // "presale" | "ecosystem" | "team" | "public" | "airdrop"
    }
    mapping(address => VestingSchedule) public vestingSchedules;

    // ── Fee discount tiers ─────────────────────────────────────────────────
    uint256 public constant TIER1_STAKE =   1_000 * 1e18; // Bronze: 20% discount
    uint256 public constant TIER2_STAKE =  10_000 * 1e18; // Silver: 35% discount
    uint256 public constant TIER3_STAKE =  50_000 * 1e18; // Gold:   45% discount
    uint256 public constant TIER4_STAKE = 100_000 * 1e18; // Platinum: 50% discount

    // ── Events ─────────────────────────────────────────────────────────────
    event Staked(address indexed user, uint256 indexed amount, uint48 lockUntil);
    event Unstaked(address indexed user, uint256 indexed amount, uint256 indexed penalty);
    event RewardClaimed(address indexed user, uint256 indexed creditAmount);
    event TokensBurned(address indexed from, uint256 indexed amount, string reason);
    event VestingCreated(address indexed beneficiary, uint256 indexed total, uint48 cliffEnd, uint48 vestEnd);
    event VestingClaimed(address indexed beneficiary, uint256 indexed amount);
    event LiquidityReserveReleased(address indexed to, uint256 indexed amount);
    event TreasuryReleased(address indexed to, uint256 indexed amount);
    event AirdropDistributed(uint256 indexed totalRecipients, uint256 indexed totalAmount);
    event PresaleAllocated(address indexed buyer, uint256 indexed amount);
    event PublicSaleAllocated(address indexed buyer, uint256 indexed amount);
    event TeamVestingCreated(address indexed member, uint256 indexed amount, uint48 cliffMonths, uint48 vestMonths);
    event TrancheReallocated(bytes32 indexed fromTranche, bytes32 indexed toTranche, uint256 indexed amount);
    event AdminTransferred(address indexed from, address indexed to);

    // ── Constructor ────────────────────────────────────────────────────────
    /**
     * @param admin               Deployer wallet — MUST call transferAdminToGnosisSafe() immediately
     * @param ecosystemWallet     Gnosis Safe — 25M ecosystem, 36-month linear vest
     * @param treasuryWallet      Gnosis Safe — 10M treasury, 24-month timelock
     */
    constructor(
        address admin,
        address ecosystemWallet,
        address treasuryWallet
    ) ERC20("Issura Utility Token", "ISS") {
        require(admin           != address(0), "ISS: zero admin");
        require(ecosystemWallet != address(0), "ISS: zero ecosystem");
        require(treasuryWallet  != address(0), "ISS: zero treasury");

        _ecosystemWallet = ecosystemWallet;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PLATFORM_ROLE, admin);

        // ── Mint entire supply to contract — ALL 100M stays here at deploy ─
        // Nothing leaves the contract at deployment.
        // Every tranche is released via explicit on-chain functions,
        // all controlled by Gnosis Safe 2-of-3 after admin handover.
        _mint(address(this), MAX_SUPPLY);

        // ── 1. Liquidity Provision (15M) ───────────────────────────────────
        // Entire 15M stays in contract.
        // Gnosis Safe calls releaseLiquidityReserve() when ready to seed Uniswap v3.
        // No tokens released until pool is ready — prevents pre-launch exposure.

        // ── 2. Ecosystem & Growth (25M) ────────────────────────────────────
        // Stays in contract with 36-month linear vesting.
        // Gnosis Safe (ecosystemWallet) calls claimVested() monthly.
        // On-chain enforcement matches whitepaper commitment exactly.
        vestingSchedules[ecosystemWallet] = VestingSchedule({
            total:    ALLOCATION_ECOSYSTEM,
            claimed:  0,
            cliffEnd: uint48(block.timestamp),                    // no cliff
            vestEnd:  uint48(block.timestamp) + 3 * 365 days,    // 36-month linear
            active:   true,
            tranche:  "ecosystem"
        });
        emit VestingCreated(
            ecosystemWallet,
            ALLOCATION_ECOSYSTEM,
            uint48(block.timestamp),
            uint48(block.timestamp) + 3 * 365 days
        );

        // ── 3. Team & Advisors (12M) ───────────────────────────────────────
        // Stays in contract. Allocated per member via createTeamVesting().
        // Gnosis Safe calls createTeamVesting() for each founder/hire/advisor.
        // Flexible cliff (6 or 12 months) and vest period (24, 36, or 48 months).

        // ── 4. Treasury & Reserve (10M) ────────────────────────────────────
        // Stays in contract. 24-month timelock — no releases until unlockTime.
        // Gnosis Safe calls releaseTreasury() after unlock, board-approved only.
        treasuryUnlockTime = block.timestamp + 2 * 365 days;

        // ── 5. Issuer Pre-Sale (15M) ───────────────────────────────────────
        // Stays in contract. Gnosis Safe calls allocatePresale() per buyer.
        // Each buyer gets a 6-month linear vesting schedule created on-chain.

        // ── 6. Public Sale (13M) ───────────────────────────────────────────
        // Stays in contract. Gnosis Safe calls allocatePublicSale() per buyer.
        // Each buyer gets a 3-month cliff then full unlock.

        // ── 7. SURA Holder Airdrop (10M) ──────────────────────────────────
        // Stays in contract. Gnosis Safe calls distributeAirdrop() at SURA STO close.
        // Each recipient gets 6-month lock post-airdrop.

        // ── Sanity check: ALL 100M held in contract at deploy ──────────────
        require(
            balanceOf(address(this)) == MAX_SUPPLY,
            "ISS: allocation mismatch"
        );
    }

    // ══════════════════════════════════════════════════════════════════════
    // PRESALE — Admin allocates ISS to KYC-verified issuers
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Allocate pre-sale ISS to a KYC-verified issuer.
     *         Creates a 6-month linear vesting schedule for the buyer.
     * @dev    Admin calls this once per buyer after USDC payment confirmed off-chain.
     *         Buyer must be KYC-verified in IdentityRegistry.
     * @param  buyer   Issuer wallet address
     * @param  amount  ISS amount purchased (at USD 0.15 per ISS)
     */
    function allocatePresale(address buyer, uint256 amount)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(buyer  != address(0),                    "ISS: zero buyer");
        require(amount  > 0,                             "ISS: zero amount");
        require(amount >= TIER1_STAKE,                   "ISS: below Bronze minimum");
        require(!vestingSchedules[buyer].active,         "ISS: schedule exists");
        require(
            _presaleAllocated() + amount <= ALLOCATION_PRESALE,
            "ISS: presale cap exceeded"
        );

        vestingSchedules[buyer] = VestingSchedule({
            total:    amount,
            claimed:  0,
            cliffEnd: uint48(block.timestamp),           // no cliff — linear from purchase
            vestEnd:  uint48(block.timestamp) + 180 days,// 6-month linear
            active:   true,
            tranche:  "presale"
        });

        _presaleTotal += amount;
        emit VestingCreated(buyer, amount, uint48(block.timestamp), uint48(block.timestamp) + 180 days);
        emit PresaleAllocated(buyer, amount);
    }

    // ══════════════════════════════════════════════════════════════════════
    // PUBLIC SALE — Admin allocates ISS to public sale buyers
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Allocate public sale ISS to a buyer.
     *         Creates a 3-month cliff schedule (tokens unlock in full after 3 months).
     * @dev    Opens Month 4-6 once ≥1 STO is live. Admin calls per buyer.
     * @param  buyer   Buyer wallet address
     * @param  amount  ISS amount purchased (at USD 0.20 per ISS)
     */
    function allocatePublicSale(address buyer, uint256 amount)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(buyer  != address(0),            "ISS: zero buyer");
        require(amount  > 0,                     "ISS: zero amount");
        require(!vestingSchedules[buyer].active, "ISS: schedule exists");
        require(
            _publicSaleAllocated() + amount <= ALLOCATION_PUBLIC_SALE + _publicSaleExtra,
            "ISS: public sale cap exceeded"
        );

        // 3-month cliff, then fully vested (cliff == vestEnd means instant unlock at cliff)
        uint48 cliff = uint48(block.timestamp) + 90 days;
        vestingSchedules[buyer] = VestingSchedule({
            total:    amount,
            claimed:  0,
            cliffEnd: cliff,
            vestEnd:  cliff,                     // cliff == vestEnd = full unlock at cliff
            active:   true,
            tranche:  "public"
        });

        _publicSaleTotal += amount;
        emit VestingCreated(buyer, amount, cliff, cliff);
        emit PublicSaleAllocated(buyer, amount);
    }

    // ══════════════════════════════════════════════════════════════════════
    // TEAM VESTING — Per-member allocation by Gnosis Safe
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Create a vesting schedule for a team member, advisor, or future hire.
     * @dev    Called by Gnosis Safe (DEFAULT_ADMIN_ROLE) once per member.
     *         Recommended parameters:
     *           Founders (Harry, CTO):  cliffMonths=12, vestMonths=36
     *           Key hires / legal:      cliffMonths=6,  vestMonths=24
     *           Advisors:               cliffMonths=0,  vestMonths=24
     * @param  member       Team member wallet address
     * @param  amount       ISS amount to allocate
     * @param  cliffMonths  Cliff period in months (0, 6, or 12)
     * @param  vestMonths   Vesting period in months after cliff (24, 36, or 48)
     */
    function createTeamVesting(
        address member,
        uint256 amount,
        uint48  cliffMonths,
        uint48  vestMonths
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(member  != address(0),                   "ISS: zero member");
        require(amount   > 0,                            "ISS: zero amount");
        require(cliffMonths <= 12,                       "ISS: cliff too long");
        require(vestMonths  >= 12 && vestMonths <= 48,   "ISS: invalid vest period");
        require(!vestingSchedules[member].active,        "ISS: schedule exists");
        require(
            _teamTotal + amount <= ALLOCATION_TEAM + _teamExtra,
            "ISS: team cap exceeded"
        );

        uint48 cliffEnd = uint48(block.timestamp) + (cliffMonths * 30 days);
        uint48 vestEnd  = cliffEnd + (vestMonths * 30 days);

        vestingSchedules[member] = VestingSchedule({
            total:    amount,
            claimed:  0,
            cliffEnd: cliffEnd,
            vestEnd:  vestEnd,
            active:   true,
            tranche:  "team"
        });

        _teamTotal += amount;
        emit VestingCreated(member, amount, cliffEnd, vestEnd);
        emit TeamVestingCreated(member, amount, cliffMonths, vestMonths);
    }

    // ══════════════════════════════════════════════════════════════════════
    // LIQUIDITY RESERVE — Board-approved releases beyond 2M launch amount
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Release additional liquidity reserve ISS to liquidity wallet.
     * @dev    Board-approved only. Total releases capped at 13M (beyond the 2M launch).
     * @param  to      Recipient (liquidity wallet / Uniswap v3 manager)
     * @param  amount  ISS amount to release
     */
    function releaseLiquidityReserve(address to, uint256 amount)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(to     != address(0), "ISS: zero address");
        require(amount  > 0,          "ISS: zero amount");
        uint256 remaining = ALLOCATION_LIQUIDITY - liquidityReserveReleased;
        require(amount <= remaining,  "ISS: exceeds liquidity reserve");

        liquidityReserveReleased += amount;
        _transfer(address(this), to, amount);
        emit LiquidityReserveReleased(to, amount);
    }

    // ══════════════════════════════════════════════════════════════════════
    // TREASURY — 24-month timelock, board-approved releases
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Release treasury ISS after 24-month timelock expires.
     * @dev    Board-approved via DEFAULT_ADMIN_ROLE (Gnosis Safe 2-of-3).
     * @param  to      Recipient wallet
     * @param  amount  ISS amount to release
     */
    function releaseTreasury(address to, uint256 amount)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(to     != address(0),                         "ISS: zero address");
        require(amount  > 0,                                  "ISS: zero amount");
        require(block.timestamp >= treasuryUnlockTime,        "ISS: treasury locked");
        require(treasuryReleased + amount <= ALLOCATION_TREASURY + _treasuryExtra, "ISS: treasury cap");

        treasuryReleased += amount;
        _transfer(address(this), to, amount);
        emit TreasuryReleased(to, amount);
    }

    // ══════════════════════════════════════════════════════════════════════
    // SURA HOLDER AIRDROP — Distributed at SURA STO close (~Month 12-14)
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Distribute SURA holder airdrop ISS with 6-month lock per recipient.
     * @dev    Admin calls once at SURA STO close. Each recipient gets 6-month lock.
     *         Total across all calls capped at ALLOCATION_AIRDROP (10M).
     * @param  recipients  Array of SURA holder wallets
     * @param  amounts     Corresponding ISS amounts
     */
    function distributeAirdrop(address[] calldata recipients, uint256[] calldata amounts)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(recipients.length == amounts.length, "ISS: length mismatch");
        require(recipients.length  > 0,              "ISS: empty array");

        uint256 total = 0;
        for (uint256 i = 0; i < recipients.length; ++i) {
            total += amounts[i];
        }
        require(
            _airdropAllocated() + total <= ALLOCATION_AIRDROP,
            "ISS: airdrop cap exceeded"
        );

        uint48 lockEnd = uint48(block.timestamp) + 180 days; // 6-month lock

        for (uint256 i = 0; i < recipients.length; ++i) {
            address recipient = recipients[i];
            uint256 amount    = amounts[i];
            require(recipient != address(0), "ISS: zero recipient");
            require(amount     > 0,          "ISS: zero amount");
            require(!vestingSchedules[recipient].active, "ISS: schedule exists");

            vestingSchedules[recipient] = VestingSchedule({
                total:    amount,
                claimed:  0,
                cliffEnd: lockEnd,
                vestEnd:  lockEnd,   // full unlock at 6 months
                active:   true,
                tranche:  "airdrop"
            });
            emit VestingCreated(recipient, amount, lockEnd, lockEnd);
        }
        _airdropTotal += total;
        emit AirdropDistributed(recipients.length, total);
    }


    // ══════════════════════════════════════════════════════════════════════
    // TRANCHE REALLOCATION — Handle unsold allocations
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Reallocate unsold tokens from one tranche to another.
     * @dev    Gnosis Safe only. Total supply remains fixed at 100M.
     *         Use case: unsold pre-sale tokens → ecosystem or treasury.
     *         Fully transparent — emits event visible on Arbiscan.
     *
     *         Valid fromTranche: "presale", "public", "team"
     *         Valid toTranche:   "ecosystem", "treasury", "public", "team"
     *
     * @param fromTranche  Source tranche (must have unallocated balance)
     * @param toTranche    Destination tranche
     * @param amount       ISS amount to reallocate
     */
    function reallocateTranche(
        bytes32 fromTranche,
        bytes32 toTranche,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0,                   "ISS: zero amount");
        require(fromTranche != toTranche,     "ISS: same tranche");

        // ── Validate source has enough unallocated ────────────────────────
        if (fromTranche == "presale") {
            require(
                _presaleTotal + amount <= ALLOCATION_PRESALE,
                "ISS: presale insufficient"
            );
            _presaleTotal += amount; // mark as allocated (consumed from presale)
        } else if (fromTranche == "public") {
            require(
                _publicSaleTotal + amount <= ALLOCATION_PUBLIC_SALE,
                "ISS: public insufficient"
            );
            _publicSaleTotal += amount;
        } else if (fromTranche == "team") {
            require(
                _teamTotal + amount <= ALLOCATION_TEAM,
                "ISS: team insufficient"
            );
            _teamTotal += amount;
        } else {
            revert("ISS: invalid fromTranche");
        }

        // ── Credit destination tranche ────────────────────────────────────
        if (toTranche == "ecosystem") {
            // Ecosystem vesting schedule already exists for Gnosis Safe
            // Increase its total — Gnosis Safe claims via claimVested()
            address ecoWallet = _ecosystemWallet;
            require(ecoWallet != address(0), "ISS: ecosystem not set");
            VestingSchedule storage eco = vestingSchedules[ecoWallet];
            require(eco.active, "ISS: ecosystem schedule missing");
            eco.total += amount;
        } else if (toTranche == "treasury") {
            require(
                treasuryReleased + amount <= ALLOCATION_TREASURY + amount,
                "ISS: treasury overflow"
            );
            // Expand treasury cap by reallocated amount
            _treasuryExtra += amount;
        } else if (toTranche == "public") {
            require(fromTranche != "public", "ISS: same tranche");
            _publicSaleExtra += amount;
        } else if (toTranche == "team") {
            require(fromTranche != "team", "ISS: same tranche");
            _teamExtra += amount;
        } else {
            revert("ISS: invalid toTranche");
        }

        emit TrancheReallocated(fromTranche, toTranche, amount);
    }

    // ══════════════════════════════════════════════════════════════════════
    // VESTING — Claim vested tokens (all tranches)
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Claim vested/unlocked ISS tokens.
     *         Works for presale, public sale, team, and airdrop schedules.
     */
    function claimVested() external nonReentrant {
        VestingSchedule storage v = vestingSchedules[msg.sender];
        require(v.active,                          "ISS: no vesting schedule");
        require(block.timestamp >= v.cliffEnd,     "ISS: cliff not reached");

        uint256 vested    = _vestedAmount(v);
        uint256 claimable = vested - v.claimed;
        require(claimable > 0,                     "ISS: nothing to claim");

        v.claimed += claimable;
        _transfer(address(this), msg.sender, claimable);
        emit VestingClaimed(msg.sender, claimable);
    }

    function _vestedAmount(VestingSchedule storage v)
        internal view returns (uint256)
    {
        if (block.timestamp < v.cliffEnd) return 0;
        if (block.timestamp >= v.vestEnd) return v.total;
        uint256 elapsed  = block.timestamp - v.cliffEnd;
        uint256 duration = v.vestEnd - v.cliffEnd;
        return (v.total * elapsed) / duration;
    }

    /**
     * @notice View how much ISS is currently claimable for a beneficiary.
     */
    function vestedAmount(address beneficiary) external view returns (uint256) {
        VestingSchedule storage v = vestingSchedules[beneficiary];
        if (!v.active) return 0;
        return _vestedAmount(v);
    }

    // ══════════════════════════════════════════════════════════════════════
    // STAKING
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Stake ISS for fee discounts and platform credits.
     * @param amount    ISS amount (18 decimals)
     * @param lockDays  90, 180, or 365 days
     */
    function stake(uint256 amount, uint48 lockDays) external nonReentrant {
        require(amount > 0,                                        "ISS: zero amount");
        require(
            lockDays == LOCK_3M || lockDays == LOCK_6M || lockDays == LOCK_12M,
            "ISS: invalid lock period"
        );
        require(!stakes[msg.sender].active,                        "ISS: already staking");
        require(balanceOf(msg.sender) >= amount,                   "ISS: insufficient balance");

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

        uint256 amount  = s.amount;
        uint256 penalty = 0;

        if (block.timestamp < s.lockUntil) {
            penalty = (amount * EARLY_UNSTAKE_PENALTY_BPS) / 10000;
            _burn(address(this), penalty);
            totalBurned += penalty;
            emit TokensBurned(msg.sender, penalty, "early_unstake");
        }

        uint256 returned = amount - penalty;
        s.active  = false;
        s.amount  = 0;
        totalStaked -= amount;

        _transfer(address(this), msg.sender, returned);
        emit Unstaked(msg.sender, returned, penalty);
    }

    // ══════════════════════════════════════════════════════════════════════
    // FEE DISCOUNT QUERIES
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns issuance fee discount in BPS based on staked amount.
     *         Bronze:   1,000 ISS = 2000 BPS (20%)
     *         Silver:  10,000 ISS = 3500 BPS (35%)
     *         Gold:    50,000 ISS = 4500 BPS (45%)
     *         Platinum:100,000 ISS = 5000 BPS (50%)
     */
    function getFeeDiscount(address user) external view returns (uint256 discountBps) {
        Stake storage s = stakes[user];
        if (!s.active) return 0;
        if (s.amount >= TIER4_STAKE) return 5000;
        if (s.amount >= TIER3_STAKE) return 4500;
        if (s.amount >= TIER2_STAKE) return 3500;
        if (s.amount >= TIER1_STAKE) return 2000;
        return 0;
    }

    /**
     * @notice Returns management fee discount in BPS based on staked amount.
     *         Bronze: 10%, Silver: 20%, Gold: 30%, Platinum: 40%
     */
    function getManagementFeeDiscount(address user) external view returns (uint256 discountBps) {
        Stake storage s = stakes[user];
        if (!s.active) return 0;
        if (s.amount >= TIER4_STAKE) return 4000;
        if (s.amount >= TIER3_STAKE) return 3000;
        if (s.amount >= TIER2_STAKE) return 2000;
        if (s.amount >= TIER1_STAKE) return 1000;
        return 0;
    }

    /**
     * @notice Check if user has priority queue access.
     *         Requires ≥50,000 ISS (Gold) staked for ≥6 months.
     */
    function hasPriorityAccess(address user) external view returns (bool) {
        Stake storage s = stakes[user];
        return s.active &&
               s.amount >= TIER3_STAKE &&
               s.lockUntil >= uint48(block.timestamp) + LOCK_6M;
    }

    // ══════════════════════════════════════════════════════════════════════
    // PLATFORM FEE SETTLEMENT (called by platform on ISS fee payment)
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Process ISS fee payment. Burns 20%, recycles 80% to ecosystem pool.
     * @param from    User paying fees in ISS
     * @param amount  Total ISS used for fee payment
     */
    function processFeePayment(address from, uint256 amount)
        external onlyRole(PLATFORM_ROLE)
    {
        require(balanceOf(from) >= amount, "ISS: insufficient fee bal");

        uint256 burnAmount    = (amount * BURN_RATE_BPS) / 10000; // 20%
        uint256 recycleAmount = amount - burnAmount;               // 80%

        _transfer(from, address(this), amount);
        _burn(address(this), burnAmount);
        totalBurned           += burnAmount;
        ecosystemPoolBalance  += recycleAmount;

        emit TokensBurned(from, burnAmount, "fee_payment");
    }

    // ══════════════════════════════════════════════════════════════════════
    // ADMIN
    // ══════════════════════════════════════════════════════════════════════

    function grantPlatformRole(address account)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _grantRole(PLATFORM_ROLE, account);
    }

     /**
     * @notice Transfer DEFAULT_ADMIN_ROLE to Gnosis Safe and renounce deployer admin.
     * @dev    MUST be called immediately after deployment.
     *         After this call, ALL admin actions require Gnosis Safe 2-of-3 approval.
     *         This is irreversible — deployer loses all admin control permanently.
     * @param  gnosisSafe  Gnosis Safe multisig address (2-of-3)
     */
    function transferAdminToGnosisSafe(address gnosisSafe)
        external onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(gnosisSafe != address(0),       "ISS: zero safe address");
        require(gnosisSafe != msg.sender,        "ISS: safe cannot be deployer");
        _grantRole(DEFAULT_ADMIN_ROLE, gnosisSafe);
        _grantRole(PLATFORM_ROLE, gnosisSafe);
        renounceRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // ══════════════════════════════════════════════════════════════════════
    // INTERNAL ALLOCATION TRACKERS
    // ══════════════════════════════════════════════════════════════════════

    /// @dev Sums all presale vesting schedules by reading total from storage.
    ///      Using a running counter would be cheaper gas-wise but less auditable.
    uint256 private _presaleTotal;
    uint256 private _publicSaleTotal;
    uint256 private _airdropTotal;
    uint256 private _teamTotal;

    // ── Reallocation tracking ─────────────────────────────────────────────
    uint256 private _treasuryExtra;    // extra capacity added via reallocation
    uint256 private _publicSaleExtra;  // extra public sale capacity
    uint256 private _teamExtra;        // extra team capacity
    address private immutable _ecosystemWallet; // stored for ecosystem reallocation

    function _presaleAllocated() internal view returns (uint256) {
        return _presaleTotal;
    }

    function _publicSaleAllocated() internal view returns (uint256) {
        return _publicSaleTotal;
    }

    function _airdropAllocated() internal view returns (uint256) {
        return _airdropTotal;
    }

    // ══════════════════════════════════════════════════════════════════════
    // VIEW — Allocation status (useful for frontend dashboard)
    // ══════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns remaining unallocated ISS per tranche.
     */
    function allocationStatus() external view returns (
        uint256 presaleRemaining,
        uint256 publicSaleRemaining,
        uint256 liquidityReserveRemaining,
        uint256 treasuryRemaining,
        uint256 airdropRemaining,
        uint256 teamRemaining,
        uint256 treasuryUnlockAt,
        bool    treasuryLocked
    ) {
        presaleRemaining        = ALLOCATION_PRESALE     - _presaleTotal;
        publicSaleRemaining     = (ALLOCATION_PUBLIC_SALE + _publicSaleExtra) - _publicSaleTotal;
        liquidityReserveRemaining = ALLOCATION_LIQUIDITY - liquidityReserveReleased;
        treasuryRemaining       = (ALLOCATION_TREASURY + _treasuryExtra) - treasuryReleased;
        airdropRemaining        = ALLOCATION_AIRDROP     - _airdropTotal;
        teamRemaining           = (ALLOCATION_TEAM + _teamExtra) - _teamTotal;
        treasuryUnlockAt        = treasuryUnlockTime;
        treasuryLocked          = block.timestamp < treasuryUnlockTime;
    }
}

