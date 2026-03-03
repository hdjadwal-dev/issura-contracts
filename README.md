# Issura Smart Contracts
### ERC-3643 Compliant RWA Security Tokens on Arbitrum

---

## Architecture

```
contracts/
├── interfaces/
│   ├── IIdentityRegistry.sol   ← KYC/compliance interface
│   └── ISecurityToken.sol      ← Security token interface
├── registry/
│   └── IdentityRegistry.sol    ← On-chain KYC registry (ERC-3643 Identity)
├── tokens/
│   ├── IssuraSecurityToken.sol ← Per-STO security token (ERC-20 + compliance)
│   └── ISSToken.sol            ← Platform utility token (100M fixed supply)
├── STOFactory.sol              ← Deploys and manages all STO token contracts
└── MockUSDC.sol                ← Test-only USDC (never deploy to mainnet)
```

### Contract Relationships

```
[Admin/Compliance] ──controls──► IdentityRegistry
                                       │
                                  canTransfer()
                                       │
[STOFactory] ──deploys──► IssuraSecurityToken ◄── [Issuer processes distributions]
     │                           │
     │                     transfer hooks
     │                           │
[Investor] ──invest()──► receive security tokens
           ──claimDistribution()──► receive USDC yield

[ISSToken] ──stake()──► fee discounts + priority access
```

---

## Quick Start (Local)

### 1. Install dependencies

```bash
cd issura-contracts
npm install
```

### 2. Run tests

```bash
npx hardhat test
```

Expected output: all tests passing across 5 test suites (35+ assertions).

### 3. Deploy to local node

```bash
# Terminal 1: start local Arbitrum-compatible node
npx hardhat node

# Terminal 2: deploy
npx hardhat run scripts/deploy.js --network localhost
```

---

## Deploy to Arbitrum Sepolia (Testnet)

### Prerequisites

1. **Get testnet ETH** — bridge from Ethereum Sepolia at https://bridge.arbitrum.io (use Sepolia faucet first)
2. **Get testnet USDC** — use the Arbitrum Sepolia USDC faucet or the contract's `faucet()` method in tests
3. **Alchemy/Infura RPC** — free tier works fine

### Setup

```bash
cp .env.example .env
```

Edit `.env`:

```env
DEPLOYER_PRIVATE_KEY=0xYOUR_PRIVATE_KEY   # wallet with testnet ETH
ARBITRUM_SEPOLIA_RPC=https://arb-sepolia.g.alchemy.com/v2/YOUR_KEY
ARBISCAN_API_KEY=YOUR_ARBISCAN_KEY
PLATFORM_ADMIN=0xYOUR_ADMIN_ADDRESS
COMPLIANCE_OFFICER=0xYOUR_COMPLIANCE_ADDRESS
FEE_TREASURY=0xYOUR_TREASURY_ADDRESS
```

### Deploy

```bash
npx hardhat run scripts/deploy.js --network arbitrumSepolia
```

Output will show all deployed addresses and save a `deployments/deployment_*.json` file.

### Verify contracts on Arbiscan

```bash
# Copy the verify commands printed at the end of deployment
npx hardhat verify --network arbitrumSepolia IDENTITY_REGISTRY_ADDRESS "ADMIN" "COMPLIANCE"
npx hardhat verify --network arbitrumSepolia FACTORY_ADDRESS ...
npx hardhat verify --network arbitrumSepolia ISS_TOKEN_ADDRESS ...
```

---

## Key Addresses (Arbitrum Sepolia)

| Contract | Address |
|---|---|
| USDC (official) | `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` |
| IdentityRegistry | *(set after deploy)* |
| STOFactory | *(set after deploy)* |
| ISSToken | *(set after deploy)* |

---

## Roles & Access Control

| Role | Contract | Can Do |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | All | Grant/revoke roles, emergency controls |
| `COMPLIANCE_ROLE` | IdentityRegistry | Register, verify, suspend, remove investors |
| `COMPLIANCE_ROLE` | SecurityToken | Freeze, force transfer, pause STO |
| `OPERATOR_ROLE` | STOFactory | Create new STOs, deactivate STOs |
| `ISSUER_ROLE` | SecurityToken | Process distributions, close offering |
| `AGENT_ROLE` | SecurityToken | Mint tokens on investment |
| `PLATFORM_ROLE` | ISSToken | Process fee payments (burn/recycle ISS) |

---

## Creating a New STO (post-deploy)

```javascript
const { ethers } = require("hardhat");

const factory = await ethers.getContractAt("STOFactory", FACTORY_ADDRESS);

const config = {
  name:             "Bali Solar Farm Series A",
  symbol:           "BSFS",
  assetType:        "energy",
  targetRaise:      ethers.parseUnits("8000000", 6),    // $8M USDC
  tokenPrice:       ethers.parseUnits("100", 6),         // $100/token
  maxSupply:        ethers.parseUnits("80000", 18),      // 80,000 tokens
  minInvestment:    ethers.parseUnits("20", 18),          // 20 tokens = $2,000 min
  allowedCountries: [702, 458, 360, 764, 608],            // ASEAN
  closingDate:      Math.floor(Date.now()/1000) + 180 * 86400,
  issuer:           ISSUER_WALLET,
  treasury:         TREASURY_WALLET,
  feeBps:           150,                                  // 1.5%
};

const tx = await factory.createSTO(config, COMPLIANCE_OFFICER);
const receipt = await tx.wait();
// Parse STOCreated event for stoId and tokenAddress
```

---

## Investor Flow

```javascript
// 1. Compliance registers investor (after off-chain KYC approval)
const registry = await ethers.getContractAt("IdentityRegistry", REGISTRY_ADDRESS);
await registry.registerIdentity(
  investorWallet,
  702,           // Singapore (ISO 3166-1 numeric)
  2,             // ACCREDITED tier
  kycDocumentHash
);

// 2. Investor approves USDC spend
const usdc = await ethers.getContractAt("IERC20", USDC_ADDRESS);
await usdc.connect(investor).approve(FACTORY_ADDRESS, investmentAmount);

// 3. Investor calls invest via factory
await factory.connect(investor).invest(stoId, investmentAmount);

// 4. Check token balance
const token = await ethers.getContractAt("IssuraSecurityToken", TOKEN_ADDRESS);
const balance = await token.balanceOf(investor.address);

// 5. Claim distributions (after issuer calls processDistribution)
await token.connect(investor).claimDistribution();
```

---

## ERC-3643 Compliance Summary

| Requirement | Implementation |
|---|---|
| Identity binding | `IdentityRegistry` — every wallet has a verified identity |
| Transfer compliance | `_update()` hook calls `identityRegistry.canTransfer()` |
| Country restrictions | `isCountryAllowed()` checked on registration |
| Annual re-verification | `expiresAt` timestamp, `updateKycExpiry()` |
| Forced transfer | `forcedTransfer()` — compliance officer override |
| Token freezing | `freezeTokens()` / `unfreezeTokens()` |
| Wallet recovery | `recoverTokens()` — lost wallet → new verified wallet |
| Emergency pause | `pause()` / `unpause()` via AccessControl |

---

## Gas Estimates (Arbitrum One — very low)

| Operation | Estimated Gas | Est. Cost @ 0.1 gwei |
|---|---|---|
| Deploy IdentityRegistry | ~800,000 | ~$0.05 |
| Deploy STOFactory | ~1,200,000 | ~$0.08 |
| Deploy IssuraSecurityToken | ~2,000,000 | ~$0.13 |
| `registerIdentity()` | ~80,000 | <$0.01 |
| `invest()` | ~120,000 | <$0.01 |
| `transfer()` | ~85,000 | <$0.01 |
| `claimDistribution()` | ~60,000 | <$0.01 |

*Arbitrum gas costs are ~10-50x cheaper than Ethereum mainnet*

---

## Security Considerations

- **No upgradeable proxies** — contracts are immutable after deployment (simplicity for MVP)
- **ReentrancyGuard** on all USDC-handling functions
- **AccessControl** with role separation (compliance ≠ admin ≠ issuer)
- **No custody** — factory routes USDC directly to issuer + treasury
- Recommend **CertiK or PeckShield audit** before mainnet deployment
- Set up a **multi-sig wallet** (Gnosis Safe) as `DEFAULT_ADMIN_ROLE`

---

## Next Steps After Testnet

1. ✅ Deploy to Arbitrum Sepolia and test all flows end-to-end
2. ⏳ Integrate with backend API (Node.js — call `registerIdentity` post-KYC)
3. ⏳ Integrate Sumsub/Onfido webhooks → auto-register on KYC approval
4. ⏳ Professional smart contract audit (CertiK / PeckShield)
5. ⏳ Deploy to Arbitrum One mainnet
6. ⏳ List ISS on DEX (Uniswap v3 on Arbitrum)
