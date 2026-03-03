// scripts/deploy.js
// Deploys the full Issura contract suite to Arbitrum Sepolia (or local node)
// Run: npx hardhat run scripts/deploy.js --network arbitrumSepolia

const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

// ── Arbitrum Sepolia USDC address ──────────────────────────────────────────
// For local testing we deploy a mock. On Arbitrum Sepolia use real address.
const ARBITRUM_SEPOLIA_USDC = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d";

async function main() {
  const [deployer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();

  console.log("═══════════════════════════════════════════════════");
  console.log("  Issura Contract Suite — Deployment");
  console.log("═══════════════════════════════════════════════════");
  console.log(`  Network:   ${network.name} (chainId: ${network.chainId})`);
  console.log(`  Deployer:  ${deployer.address}`);
  console.log(`  Balance:   ${ethers.formatEther(await ethers.provider.getBalance(deployer.address))} ETH`);
  console.log("═══════════════════════════════════════════════════\n");

  const isLocal = network.chainId === 31337n;

  // ── Addresses ──────────────────────────────────────────────────────────
  const adminAddress      = process.env.PLATFORM_ADMIN      || deployer.address;
  const complianceAddress = process.env.COMPLIANCE_OFFICER  || deployer.address;
  const treasuryAddress   = process.env.FEE_TREASURY        || deployer.address;

  let usdcAddress;

  // ── 1. Mock USDC (local only) ──────────────────────────────────────────
  if (isLocal) {
    console.log("📦 [1/5] Deploying MockUSDC (local only)...");
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const mockUsdc = await MockUSDC.deploy(deployer.address);
    await mockUsdc.waitForDeployment();
    usdcAddress = await mockUsdc.getAddress();
    console.log(`  ✓ MockUSDC deployed: ${usdcAddress}`);

    // Mint 1M USDC to deployer for testing
    await mockUsdc.mint(deployer.address, ethers.parseUnits("1000000", 6));
    console.log(`  ✓ Minted 1,000,000 USDC to deployer`);
  } else {
    usdcAddress = ARBITRUM_SEPOLIA_USDC;
    console.log(`📦 [1/5] Using real USDC: ${usdcAddress}`);
  }

  // ── 2. IdentityRegistry ────────────────────────────────────────────────
  console.log("\n📦 [2/5] Deploying IdentityRegistry...");
  const IdentityRegistry = await ethers.getContractFactory("IdentityRegistry");
  const identityRegistry = await IdentityRegistry.deploy(adminAddress, complianceAddress);
  await identityRegistry.waitForDeployment();
  const identityRegistryAddress = await identityRegistry.getAddress();
  console.log(`  ✓ IdentityRegistry: ${identityRegistryAddress}`);

  // ── 3. STOFactory ──────────────────────────────────────────────────────
  console.log("\n📦 [3/5] Deploying STOFactory...");
  const STOFactory = await ethers.getContractFactory("STOFactory");
  const stoFactory = await STOFactory.deploy(
    identityRegistryAddress,
    usdcAddress,
    treasuryAddress,
    adminAddress,
    deployer.address  // operator
  );
  await stoFactory.waitForDeployment();
  const stoFactoryAddress = await stoFactory.getAddress();
  console.log(`  ✓ STOFactory: ${stoFactoryAddress}`);

  // ── 4. ISS Token ───────────────────────────────────────────────────────
  console.log("\n📦 [4/5] Deploying ISSToken...");
  // For testnet, all wallets default to deployer
  const ISSToken = await ethers.getContractFactory("ISSToken");
  const issToken = await ISSToken.deploy(
    adminAddress,         // admin
    deployer.address,     // liquidityWallet (50M)
    deployer.address,     // ecosystemWallet (25M)
    deployer.address,     // teamWallet (15M — vested)
    deployer.address      // partnershipWallet (10M — locked)
  );
  await issToken.waitForDeployment();
  const issTokenAddress = await issToken.getAddress();
  console.log(`  ✓ ISSToken: ${issTokenAddress}`);

  // Grant factory PLATFORM_ROLE on ISS token
  await issToken.grantPlatformRole(stoFactoryAddress);
  console.log(`  ✓ Granted PLATFORM_ROLE to STOFactory`);

  // ── 5. IssuraTimelock ─────────────────────────────────────────────────
  console.log("\n📦 [5/6] Deploying IssuraTimelock (48-hour delay)...");
  const IssuraTimelock = await ethers.getContractFactory("IssuraTimelock");

  // Proposers and executors: platform admin wallet (replace with multisig in mainnet)
  const proposers = [adminAddress];
  const executors = [adminAddress];

  const timelock = await IssuraTimelock.deploy(proposers, executors, adminAddress);
  await timelock.waitForDeployment();
  const timelockAddress = await timelock.getAddress();
  console.log(`  ✓ IssuraTimelock: ${timelockAddress}`);
  console.log(`  ✓ Min delay: 48 hours`);

  // ── Wire Timelock as admin of all contracts ────────────────────────────
  console.log("\n🔐 Wiring timelock as DEFAULT_ADMIN_ROLE...");

  const DEFAULT_ADMIN_ROLE = ethers.ZeroHash;

  // IdentityRegistry — grant timelock admin, keep deployer as compliance
  await identityRegistry.grantRole(DEFAULT_ADMIN_ROLE, timelockAddress);
  console.log(`  ✓ IdentityRegistry: granted DEFAULT_ADMIN_ROLE to timelock`);

  // STOFactory — grant timelock admin
  await stoFactory.grantRole(DEFAULT_ADMIN_ROLE, timelockAddress);
  console.log(`  ✓ STOFactory: granted DEFAULT_ADMIN_ROLE to timelock`);

  // ISSToken — grant timelock admin
  await issToken.grantRole(DEFAULT_ADMIN_ROLE, timelockAddress);
  console.log(`  ✓ ISSToken: granted DEFAULT_ADMIN_ROLE to timelock`);

  // NOTE: We intentionally keep deployer as DEFAULT_ADMIN_ROLE during testnet.
  // On mainnet: revoke deployer's DEFAULT_ADMIN_ROLE from all contracts after
  // confirming timelock is working correctly.
  console.log(`  ⚠  Deployer retains DEFAULT_ADMIN_ROLE on testnet (revoke on mainnet)`);

  // ── 6. Demo STO (local/testnet only) ──────────────────────────────────
  let stoId, stoTokenAddress;
  if (isLocal) {
    console.log("\n📦 [5/5] Creating demo STO (Marina Bay Tower III)...");

    // Register deployer as verified investor first
    const kycHash = ethers.keccak256(ethers.toUtf8Bytes("demo_kyc_tan_wei_ming"));
    await identityRegistry.registerIdentity(
      deployer.address,
      702,  // Singapore
      2,    // ACCREDITED
      kycHash
    );
    console.log(`  ✓ Registered deployer as Accredited Investor (SGP)`);

    const now = Math.floor(Date.now() / 1000);
    const config = {
      name:             "Marina Bay Tower III Security Token",
      symbol:           "MBTS3",
      assetType:        "real_estate",
      targetRaise:      ethers.parseUnits("12000000", 6),   // $12M USDC
      tokenPrice:       ethers.parseUnits("100", 6),        // $100 per token
      maxSupply:        ethers.parseUnits("120000", 18),     // 120,000 tokens
      minInvestment:    ethers.parseUnits("50", 18),         // 50 tokens = $5,000 min
      allowedCountries: [702, 458, 360, 764, 608],           // ASEAN + core markets
      closingDate:      now + 180 * 24 * 3600,               // 6 months
      issuer:           deployer.address,
      treasury:         treasuryAddress,
      feeBps:           150,                                  // 1.5%
    };

    const tx = await stoFactory.createSTO(config, complianceAddress);
    const receipt = await tx.wait();

    // Parse STOCreated event
    const event = receipt.logs
      .map(log => { try { return stoFactory.interface.parseLog(log); } catch { return null; } })
      .find(e => e && e.name === "STOCreated");

    stoId = event.args.stoId;
    stoTokenAddress = event.args.tokenAddress;
    console.log(`  ✓ STO created`);
    console.log(`  ✓ STO ID:    ${stoId}`);
    console.log(`  ✓ Token:     ${stoTokenAddress}`);
  } else {
    console.log("\n⏭  [6/6] Skipping demo STO on testnet (create via admin dashboard)");
  }

  // ── Summary ────────────────────────────────────────────────────────────
  const deploymentData = {
    network:          network.name,
    chainId:          network.chainId.toString(),
    deployedAt:       new Date().toISOString(),
    deployer:         deployer.address,
    contracts: {
      usdc:             usdcAddress,
      identityRegistry: identityRegistryAddress,
      stoFactory:       stoFactoryAddress,
      issToken:         issTokenAddress,
      timelock:         timelockAddress,
      ...(stoTokenAddress && { demoSTOToken: stoTokenAddress }),
      ...(stoId && { demoSTOId: stoId }),
    }
  };

  const outPath = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(outPath)) fs.mkdirSync(outPath);
  const fileName = `deployment_${network.name}_${Date.now()}.json`;
  fs.writeFileSync(path.join(outPath, fileName), JSON.stringify(deploymentData, null, 2));

  console.log("\n═══════════════════════════════════════════════════");
  console.log("  ✅ DEPLOYMENT COMPLETE");
  console.log("═══════════════════════════════════════════════════");
  console.log(`  USDC:              ${usdcAddress}`);
  console.log(`  IdentityRegistry:  ${identityRegistryAddress}`);
  console.log(`  STOFactory:        ${stoFactoryAddress}`);
  console.log(`  ISSToken:          ${issTokenAddress}`);
  console.log(`  Timelock (48hr):   ${timelockAddress}`);
  if (stoTokenAddress) console.log(`  Demo STO Token:    ${stoTokenAddress}`);
  console.log(`\n  📄 Saved to: deployments/${fileName}`);

  if (!isLocal) {
    console.log("\n  🔍 Verify on Arbiscan:");
    console.log(`  npx hardhat verify --network arbitrumSepolia ${identityRegistryAddress} "${adminAddress}" "${complianceAddress}"`);
    console.log(`  npx hardhat verify --network arbitrumSepolia ${stoFactoryAddress} "${identityRegistryAddress}" "${usdcAddress}" "${treasuryAddress}" "${adminAddress}" "${deployer.address}"`);
    console.log(`  npx hardhat verify --network arbitrumSepolia ${timelockAddress} '["' + adminAddress + '"]' '["' + adminAddress + '"]' "${adminAddress}"`);
  console.log(`  npx hardhat verify --network arbitrumSepolia ${issTokenAddress} "${adminAddress}" "${deployer.address}" "${deployer.address}" "${deployer.address}" "${deployer.address}"`);
  }
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("\n❌ Deployment failed:", err);
    process.exit(1);
  });
