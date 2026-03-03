// test/Issura.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("Issura Contract Suite", function () {

  let usdc, identityRegistry, stoFactory, issToken;
  let admin, compliance, issuer, treasury, investor1, investor2, investor3, attacker;
  let stoId, stoToken;

  const SINGAPORE = 702;
  const MALAYSIA  = 458;
  const BLOCKED   = 999;

  beforeEach(async () => {
    [admin, compliance, issuer, treasury, investor1, investor2, investor3, attacker] =
      await ethers.getSigners();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    usdc = await MockUSDC.deploy(admin.address);

    await usdc.mint(investor1.address, ethers.parseUnits("500000", 6));
    await usdc.mint(investor2.address, ethers.parseUnits("500000", 6));
    await usdc.mint(investor3.address, ethers.parseUnits("500000", 6));
    await usdc.mint(issuer.address,    ethers.parseUnits("1000000", 6));
    await usdc.mint(attacker.address,  ethers.parseUnits("100000", 6));

    const IdentityRegistry = await ethers.getContractFactory("IdentityRegistry");
    identityRegistry = await IdentityRegistry.deploy(admin.address, compliance.address);

    const STOFactory = await ethers.getContractFactory("STOFactory");
    stoFactory = await STOFactory.deploy(
      await identityRegistry.getAddress(),
      await usdc.getAddress(),
      treasury.address,
      admin.address,
      admin.address
    );

    // ISS token: all wallets set to admin in tests so vesting claims work
    const ISSToken = await ethers.getContractFactory("ISSToken");
    issToken = await ISSToken.deploy(
      admin.address,
      admin.address,  // liquidity
      admin.address,  // ecosystem
      admin.address,  // team (vesting schedule — tokens stay in contract)
      admin.address   // partnerships (vesting schedule — tokens stay in contract)
    );
    await issToken.grantPlatformRole(await stoFactory.getAddress());
  });

  // ── Helpers ───────────────────────────────────────────────────────────────

  async function createTestSTO() {
    const now = await time.latest();
    const config = {
      name: "Test Real Estate Token", symbol: "TRET", assetType: "real_estate",
      targetRaise:   ethers.parseUnits("1000000", 6),
      tokenPrice:    ethers.parseUnits("100", 6),
      maxSupply:     ethers.parseUnits("10000", 18),
      minInvestment: ethers.parseUnits("10", 18),   // 10 tokens = $1,000 min
      allowedCountries: [SINGAPORE, MALAYSIA],
      closingDate: now + 180 * 24 * 3600,
      issuer:   issuer.address,
      treasury: treasury.address,
      feeBps:   150,
    };
    const tx = await stoFactory.connect(admin).createSTO(config, compliance.address);
    const receipt = await tx.wait();
    const event = receipt.logs
      .map(l => { try { return stoFactory.interface.parseLog(l); } catch { return null; } })
      .find(e => e && e.name === "STOCreated");
    expect(event, "STOCreated event not found").to.not.be.null;
    stoId = event.args.stoId;
    const IssuraSecurityToken = await ethers.getContractFactory("IssuraSecurityToken");
    stoToken = IssuraSecurityToken.attach(event.args.tokenAddress);
    return { stoId, stoToken };
  }

  async function registerInvestor(investor, country = SINGAPORE) {
    const kycHash = ethers.keccak256(ethers.toUtf8Bytes(`kyc_${investor.address}`));
    await identityRegistry.connect(compliance).registerIdentity(investor.address, country, 2, kycHash);
  }

  // ══════════════════════════════════════════════════════════════════════════
  // ── IdentityRegistry ─────────────────────────────────────────────────────

  describe("IdentityRegistry", () => {

    it("registers and verifies investor", async () => {
      await registerInvestor(investor1, SINGAPORE);
      expect(await identityRegistry.isVerified(investor1.address)).to.be.true;
    });

    it("rejects registration from non-compliance address", async () => {
      const h = ethers.keccak256(ethers.toUtf8Bytes("kyc"));
      await expect(identityRegistry.connect(attacker).registerIdentity(investor1.address, SINGAPORE, 2, h))
        .to.be.reverted;
    });

    it("rejects blocked country", async () => {
      const h = ethers.keccak256(ethers.toUtf8Bytes("kyc"));
      await expect(identityRegistry.connect(compliance).registerIdentity(investor1.address, BLOCKED, 2, h))
        .to.be.revertedWith("IR: country not allowed");
    });

    // BUG 2 REGRESSION: suspended INSTITUTIONAL investor must NOT pass isVerified
    it("(Bug 2 fix) suspended INSTITUTIONAL investor fails isVerified", async () => {
      // Register as institutional (tier 3)
      const h = ethers.keccak256(ethers.toUtf8Bytes("kyc_inst"));
      await identityRegistry.connect(compliance).registerIdentity(investor1.address, SINGAPORE, 3, h);
      expect(await identityRegistry.isVerified(investor1.address)).to.be.true;

      // Suspend them
      await identityRegistry.connect(compliance).suspendIdentity(investor1.address, "AML");
      // Must be false — before the fix the operator precedence bug made this true
      expect(await identityRegistry.isVerified(investor1.address)).to.be.false;
    });

    it("suspends investor and marks as unverified", async () => {
      await registerInvestor(investor1);
      await identityRegistry.connect(compliance).suspendIdentity(investor1.address, "AML flag");
      expect(await identityRegistry.isVerified(investor1.address)).to.be.false;
    });

    it("blocks canTransfer if suspended", async () => {
      await registerInvestor(investor1);
      await registerInvestor(investor2);
      await identityRegistry.connect(compliance).suspendIdentity(investor1.address, "AML");
      expect(await identityRegistry.canTransfer(investor1.address, investor2.address)).to.be.false;
    });

    it("expires identity after 365 days", async () => {
      await registerInvestor(investor1);
      await time.increase(366 * 24 * 3600);
      expect(await identityRegistry.isVerified(investor1.address)).to.be.false;
    });

    it("allows compliance to renew KYC expiry", async () => {
      await registerInvestor(investor1);
      await time.increase(366 * 24 * 3600);
      const newExpiry = (await time.latest()) + 400 * 24 * 3600;
      await identityRegistry.connect(compliance).updateKycExpiry(investor1.address, newExpiry);
      expect(await identityRegistry.isVerified(investor1.address)).to.be.true;
    });

    it("allows admin to block a country", async () => {
      await identityRegistry.connect(admin).setCountryAllowed(SINGAPORE, false);
      expect(await identityRegistry.isCountryAllowed(SINGAPORE)).to.be.false;
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // ── STOFactory ───────────────────────────────────────────────────────────

  describe("STOFactory", () => {

    it("creates STO and emits STOCreated", async () => {
      await expect(createTestSTO()).to.not.be.reverted;
      expect(await stoFactory.stoCount()).to.equal(1);
    });

    it("rejects creation from non-operator", async () => {
      const now = await time.latest();
      const config = {
        name: "Bad", symbol: "BAD", assetType: "real_estate",
        targetRaise: ethers.parseUnits("100000", 6), tokenPrice: ethers.parseUnits("100", 6),
        maxSupply: ethers.parseUnits("1000", 18), minInvestment: ethers.parseUnits("10", 18),
        allowedCountries: [SINGAPORE], closingDate: now + 90 * 24 * 3600,
        issuer: attacker.address, treasury: attacker.address, feeBps: 150,
      };
      await expect(stoFactory.connect(attacker).createSTO(config, compliance.address)).to.be.reverted;
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // ── Investment Flow ───────────────────────────────────────────────────────

  describe("Investment Flow", () => {

    beforeEach(async () => {
      await createTestSTO();
      await registerInvestor(investor1, SINGAPORE);
      await registerInvestor(investor2, MALAYSIA);
    });

    it("verified investor receives correct token amount", async () => {
      const investAmount = ethers.parseUnits("10000", 6); // $10,000 → 100 tokens
      await usdc.connect(investor1).approve(await stoFactory.getAddress(), investAmount);
      await stoFactory.connect(investor1).invest(stoId, investAmount);
      expect(await stoToken.balanceOf(investor1.address)).to.equal(ethers.parseUnits("100", 18));
    });

    // BUG 3 REGRESSION: investor must not be charged twice
    it("(Bug 3 fix) investor USDC balance decreases by exactly investAmount", async () => {
      const investAmount = ethers.parseUnits("10000", 6);
      const before = await usdc.balanceOf(investor1.address);
      await usdc.connect(investor1).approve(await stoFactory.getAddress(), investAmount);
      await stoFactory.connect(investor1).invest(stoId, investAmount);
      const after = await usdc.balanceOf(investor1.address);
      // Must be exactly investAmount deducted — not 2x
      expect(before - after).to.equal(investAmount);
    });

    it("platform fee flows to treasury, net proceeds to issuer", async () => {
      const investAmount = ethers.parseUnits("10000", 6);
      const expectedFee      = (investAmount * 150n) / 10000n; // 1.5% = $150
      const expectedProceeds = investAmount - expectedFee;

      const treasuryBefore = await usdc.balanceOf(treasury.address);
      const issuerBefore   = await usdc.balanceOf(issuer.address);

      await usdc.connect(investor1).approve(await stoFactory.getAddress(), investAmount);
      await stoFactory.connect(investor1).invest(stoId, investAmount);

      expect(await usdc.balanceOf(treasury.address) - treasuryBefore).to.equal(expectedFee);
      expect(await usdc.balanceOf(issuer.address)   - issuerBefore).to.equal(expectedProceeds);
    });

    // BUG 4 REGRESSION: factory approval must be reset to 0 after invest()
    it("(Bug 4 fix) factory USDC allowance to token is 0 after investment", async () => {
      const investAmount = ethers.parseUnits("10000", 6);
      await usdc.connect(investor1).approve(await stoFactory.getAddress(), investAmount);
      await stoFactory.connect(investor1).invest(stoId, investAmount);
      const factoryAllowance = await usdc.allowance(
        await stoFactory.getAddress(),
        await stoToken.getAddress()
      );
      expect(factoryAllowance).to.equal(0n);
    });

    it("rejects unverified investor", async () => {
      const investAmount = ethers.parseUnits("10000", 6);
      await usdc.connect(attacker).approve(await stoFactory.getAddress(), investAmount);
      await expect(stoFactory.connect(attacker).invest(stoId, investAmount)).to.be.reverted;
    });

    it("rejects below-minimum investment", async () => {
      const investAmount = ethers.parseUnits("500", 6); // < $1,000 min
      await usdc.connect(investor1).approve(await stoFactory.getAddress(), investAmount);
      await expect(stoFactory.connect(investor1).invest(stoId, investAmount)).to.be.reverted;
    });

    it("tracks totalRaised correctly across multiple investors", async () => {
      const inv1 = ethers.parseUnits("10000", 6);
      const inv2 = ethers.parseUnits("25000", 6);
      await usdc.connect(investor1).approve(await stoFactory.getAddress(), inv1);
      await stoFactory.connect(investor1).invest(stoId, inv1);
      await usdc.connect(investor2).approve(await stoFactory.getAddress(), inv2);
      await stoFactory.connect(investor2).invest(stoId, inv2);
      expect(await stoToken.totalRaised()).to.equal(inv1 + inv2);
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // ── Compliance Actions ────────────────────────────────────────────────────

  describe("Compliance Actions", () => {

    beforeEach(async () => {
      await createTestSTO();
      await registerInvestor(investor1, SINGAPORE);
      await registerInvestor(investor2, MALAYSIA);
      const inv = ethers.parseUnits("10000", 6); // 100 tokens
      await usdc.connect(investor1).approve(await stoFactory.getAddress(), inv);
      await stoFactory.connect(investor1).invest(stoId, inv);
    });

    it("compliance can freeze tokens", async () => {
      await stoToken.connect(compliance).freezeTokens(investor1.address, ethers.parseUnits("50", 18));
      expect(await stoToken.isFrozen(investor1.address)).to.be.true;
    });

    it("investor cannot transfer frozen tokens", async () => {
      await stoToken.connect(compliance).freezeTokens(investor1.address, ethers.parseUnits("100", 18));
      await expect(
        stoToken.connect(investor1).transfer(investor2.address, ethers.parseUnits("10", 18))
      ).to.be.revertedWith("ST: insufficient unfrozen balance");
    });

    it("compliance can force transfer", async () => {
      const amount = ethers.parseUnits("50", 18);
      await stoToken.connect(compliance).forcedTransfer(investor1.address, investor2.address, amount, "Court order");
      expect(await stoToken.balanceOf(investor2.address)).to.equal(amount);
    });

    it("compliance can recover tokens to verified wallet", async () => {
      await stoToken.connect(compliance).recoverTokens(investor1.address, investor2.address);
      expect(await stoToken.balanceOf(investor2.address)).to.equal(ethers.parseUnits("100", 18));
      expect(await stoToken.balanceOf(investor1.address)).to.equal(0);
    });

    it("pause blocks new investments", async () => {
      await stoToken.connect(compliance).pause("Regulatory hold");
      const inv2 = ethers.parseUnits("5000", 6);
      await usdc.connect(investor2).approve(await stoFactory.getAddress(), inv2);
      await expect(stoFactory.connect(investor2).invest(stoId, inv2)).to.be.reverted;
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // ── Distributions ─────────────────────────────────────────────────────────

  describe("Distributions", () => {

    beforeEach(async () => {
      await createTestSTO();
      await registerInvestor(investor1, SINGAPORE);
      await registerInvestor(investor2, MALAYSIA);

      // investor1: $10,000 → 100 tokens (20%)
      const inv1 = ethers.parseUnits("10000", 6);
      await usdc.connect(investor1).approve(await stoFactory.getAddress(), inv1);
      await stoFactory.connect(investor1).invest(stoId, inv1);

      // investor2: $40,000 → 400 tokens (80%)
      const inv2 = ethers.parseUnits("40000", 6);
      await usdc.connect(investor2).approve(await stoFactory.getAddress(), inv2);
      await stoFactory.connect(investor2).invest(stoId, inv2);
    });

    it("distributes USDC proportionally", async () => {
      const dist = ethers.parseUnits("10000", 6);
      await usdc.connect(issuer).approve(await stoToken.getAddress(), dist);
      await stoToken.connect(issuer).processDistribution(dist);

      const p1 = await stoToken.pendingDistribution(investor1.address);
      const p2 = await stoToken.pendingDistribution(investor2.address);

      expect(p1).to.be.closeTo(ethers.parseUnits("2000", 6), ethers.parseUnits("1", 6));
      expect(p2).to.be.closeTo(ethers.parseUnits("8000", 6), ethers.parseUnits("1", 6));
    });

    it("investor can claim distribution", async () => {
      const dist = ethers.parseUnits("10000", 6);
      await usdc.connect(issuer).approve(await stoToken.getAddress(), dist);
      await stoToken.connect(issuer).processDistribution(dist);

      const before = await usdc.balanceOf(investor1.address);
      await stoToken.connect(investor1).claimDistribution();
      const after = await usdc.balanceOf(investor1.address);
      expect(after - before).to.be.closeTo(ethers.parseUnits("2000", 6), ethers.parseUnits("1", 6));
    });

    it("accumulates multiple distributions correctly", async () => {
      const dist = ethers.parseUnits("5000", 6);
      await usdc.connect(issuer).approve(await stoToken.getAddress(), dist);
      await stoToken.connect(issuer).processDistribution(dist);
      await usdc.connect(issuer).approve(await stoToken.getAddress(), dist);
      await stoToken.connect(issuer).processDistribution(dist);

      // investor1 (20%) of $10K total = $2,000
      const p1 = await stoToken.pendingDistribution(investor1.address);
      expect(p1).to.be.closeTo(ethers.parseUnits("2000", 6), ethers.parseUnits("2", 6));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // ── ISSToken ──────────────────────────────────────────────────────────────

  describe("ISSToken", () => {

    it("mints exactly 100M total supply", async () => {
      expect(await issToken.totalSupply()).to.equal(ethers.parseUnits("100000000", 18));
    });

    it("distributes liquidity and ecosystem immediately; holds vesting in contract", async () => {
      // Admin (liquidity) got 50M, admin (ecosystem) got 25M
      // 25M should remain in the contract for vesting (team 15M + partnership 10M)
      const contractBalance = await issToken.balanceOf(await issToken.getAddress());
      expect(contractBalance).to.equal(ethers.parseUnits("25000000", 18));
    });

    // BUG 11 REGRESSION: team wallet must NOT have tokens before cliff
    it("(Bug 11 fix) team wallet balance is 0 before vesting cliff", async () => {
      // In test setup, admin == teamWallet. Admin received liquidity + ecosystem (75M total).
      // The 15M team allocation must stay in the contract — not be immediately transferable.
      // Admin's balance should be 75M (liquidity 50M + ecosystem 25M), NOT 90M
      const adminBalance = await issToken.balanceOf(admin.address);
      expect(adminBalance).to.equal(ethers.parseUnits("75000000", 18));
    });

    it("allows staking and returns correct discount tier", async () => {
      await issToken.connect(admin).transfer(investor1.address, ethers.parseUnits("10000", 18));
      await issToken.connect(investor1).stake(ethers.parseUnits("10000", 18), 180 * 24 * 3600);
      expect(await issToken.getFeeDiscount(investor1.address)).to.equal(5000); // 50%
    });

    it("applies early unstake penalty and burns 25%", async () => {
      await issToken.connect(admin).transfer(investor1.address, ethers.parseUnits("10000", 18));
      await issToken.connect(investor1).stake(ethers.parseUnits("10000", 18), 365 * 24 * 3600);
      const supplyBefore = await issToken.totalSupply();
      await issToken.connect(investor1).unstake();
      expect(supplyBefore - await issToken.totalSupply()).to.equal(ethers.parseUnits("2500", 18));
    });

    it("no penalty after lock period expires", async () => {
      await issToken.connect(admin).transfer(investor1.address, ethers.parseUnits("5000", 18));
      await issToken.connect(investor1).stake(ethers.parseUnits("5000", 18), 90 * 24 * 3600);
      await time.increase(91 * 24 * 3600);
      const supplyBefore = await issToken.totalSupply();
      await issToken.connect(investor1).unstake();
      expect(await issToken.totalSupply()).to.equal(supplyBefore);
    });

    it("burns 20% on fee payment", async () => {
      await issToken.connect(admin).transfer(investor1.address, ethers.parseUnits("1000", 18));
      const supplyBefore = await issToken.totalSupply();
      await issToken.connect(admin).processFeePayment(investor1.address, ethers.parseUnits("1000", 18));
      expect(supplyBefore - await issToken.totalSupply()).to.equal(ethers.parseUnits("200", 18));
    });

    it("team vesting: cliff enforced (cannot claim before 1 year)", async () => {
      await expect(issToken.connect(admin).claimVested()).to.be.revertedWith("ISS: cliff not reached");
    });

    it("team vesting: can claim after cliff", async () => {
      await time.increase(366 * 24 * 3600);
      await expect(issToken.connect(admin).claimVested()).to.not.be.reverted;
      // Some tokens should now be in admin wallet from vesting
      const claimed = await issToken.balanceOf(admin.address);
      expect(claimed).to.be.gt(ethers.parseUnits("75000000", 18));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // ── Transfer Compliance E2E ───────────────────────────────────────────────

  describe("Transfer Compliance (E2E)", () => {

    it("verified investors can transfer tokens", async () => {
      await createTestSTO();
      await registerInvestor(investor1, SINGAPORE);
      await registerInvestor(investor2, MALAYSIA);
      const inv = ethers.parseUnits("10000", 6);
      await usdc.connect(investor1).approve(await stoFactory.getAddress(), inv);
      await stoFactory.connect(investor1).invest(stoId, inv);
      await stoToken.connect(investor1).transfer(investor2.address, ethers.parseUnits("50", 18));
      expect(await stoToken.balanceOf(investor2.address)).to.equal(ethers.parseUnits("50", 18));
    });

    it("cannot transfer to unverified wallet", async () => {
      await createTestSTO();
      await registerInvestor(investor1, SINGAPORE);
      const inv = ethers.parseUnits("10000", 6);
      await usdc.connect(investor1).approve(await stoFactory.getAddress(), inv);
      await stoFactory.connect(investor1).invest(stoId, inv);
      await expect(
        stoToken.connect(investor1).transfer(attacker.address, ethers.parseUnits("10", 18))
      ).to.be.revertedWith("ST: transfer not compliant");
    });

    it("cannot transfer after suspension", async () => {
      await createTestSTO();
      await registerInvestor(investor1, SINGAPORE);
      await registerInvestor(investor2, MALAYSIA);
      const inv = ethers.parseUnits("10000", 6);
      await usdc.connect(investor1).approve(await stoFactory.getAddress(), inv);
      await stoFactory.connect(investor1).invest(stoId, inv);
      await identityRegistry.connect(compliance).suspendIdentity(investor1.address, "AML hold");
      await expect(
        stoToken.connect(investor1).transfer(investor2.address, ethers.parseUnits("10", 18))
      ).to.be.revertedWith("ST: transfer not compliant");
    });
  });
});
