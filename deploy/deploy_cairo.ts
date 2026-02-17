import { Account, json, RpcProvider, Contract, CallData } from "starknet";
import fs from "fs";
import dotenv from "dotenv";
import path from "path";

const envPath = path.join(__dirname, ".env");
dotenv.config({ path: envPath });

const provider = new RpcProvider({ nodeUrl: process.env.SEPOLIA_RPC as string });

const owner_private_key = process.env.PRIVATE_KEY as string;
const owner_account_address = process.env.ACCOUNT_ADDRESS as string;

// v8 uses object-based constructor
const myAccount = new Account({
  provider: provider,
  address: owner_account_address,
  signer: owner_private_key,
});

// Path to compiled contracts (at project root, not in a "contracts" subdirectory)
const DEV_DIR = path.join(__dirname, "..", "target", "dev");
const DEPLOYMENT_PATH = path.join(__dirname, "deployment.json");

interface ContractArtifacts {
  sierra: any;
  casm: any | null;
  sierraFile: string;
  casmFile: string | null;
}

function loadContractArtifacts(contractName: string, allowTestContracts = false): ContractArtifacts {
  if (!fs.existsSync(DEV_DIR)) {
    throw new Error(`Missing target/dev directory: ${DEV_DIR}`);
  }

  const files = fs.readdirSync(DEV_DIR);

  let sierraFile = files.find(
    (f) => f.endsWith(".contract_class.json") && f.includes(contractName) && !f.includes(".test.")
  );

  if (!sierraFile && allowTestContracts) {
    sierraFile = files.find(
      (f) => f.endsWith(".test.contract_class.json") && f.includes(contractName)
    );
  }

  if (!sierraFile) {
    throw new Error(`Missing Sierra file for ${contractName} in ${DEV_DIR}`);
  }

  let casmFile = files.find(
    (f) => f.endsWith(".compiled_contract_class.json") && f.includes(contractName) && !f.includes(".test.")
  );

  if (!casmFile && allowTestContracts) {
    casmFile = files.find(
      (f) => f.endsWith(".test.compiled_contract_class.json") && f.includes(contractName)
    );
  }

  const sierraPath = path.join(DEV_DIR, sierraFile);
  const casmPath = casmFile ? path.join(DEV_DIR, casmFile) : null;

  console.log(`Loading ${contractName}:`);
  console.log(`  Sierra: ${sierraFile}`);
  console.log(`  CASM: ${casmFile || "NOT FOUND (will need to compile)"}`);

  return {
    sierra: json.parse(fs.readFileSync(sierraPath, "utf8")),
    casm: casmPath ? json.parse(fs.readFileSync(casmPath, "utf8")) : null,
    sierraFile,
    casmFile: casmFile || null,
  };
}

async function declareAndDeploy(
  contractName: string,
  constructorCalldata: any,
  allowTestContracts = false
): Promise<Contract> {
  const artifacts = loadContractArtifacts(contractName, allowTestContracts);

  if (!artifacts.casm) {
    console.error(`\n❌ CASM file not found for ${contractName}`);
    console.error(`\nTo generate CASM files, add casm = true to Scarb.toml:`);
    console.error(`   [[target.starknet-contract]]`);
    console.error(`   sierra = true`);
    console.error(`   casm = true`);
    throw new Error(`Missing CASM file for ${contractName}`);
  }

  console.log(`\nDeclaring and deploying ${contractName}...`);

  const myContract = await Contract.factory({
    contract: artifacts.sierra,
    casm: artifacts.casm,
    account: myAccount,
    constructorCalldata,
  });

  console.log(`${contractName} deployed at: ${myContract.address}`);
  console.log(`${contractName} class hash: ${myContract.classHash}`);

  return myContract;
}

// =====================================================================
// Individual deploy functions
// =====================================================================

async function deployAccessRegistry(admin: string): Promise<Contract> {
  return declareAndDeploy("AccessRegistry", { owner: admin }, false);
}

async function deployMockOracle(
  name: string,
  initialRateBps: bigint,
  initialTimestamp: bigint
): Promise<Contract> {
  // MockOracle constructor: (name: ByteArray, initial_rate: u256, initial_timestamp: u64)
  // starknet.js v8 auto-serializes strings to ByteArray
  return declareAndDeploy(
    "MockOracle",
    {
      name,
      initial_rate: { low: initialRateBps, high: 0n },
      initial_timestamp: initialTimestamp,
    },
    false
  );
}

async function deployMockERC20(decimals: number): Promise<Contract> {
  return declareAndDeploy("MockERC20", { decimals: decimals }, false);
}

async function deployAsceswap(
  accessRegistryAddress: string,
  treasuryAddress: string
): Promise<Contract> {
  return declareAndDeploy(
    "Asceswap",
    {
      access_registry: accessRegistryAddress,
      treasury: treasuryAddress,
    },
    false
  );
}

async function deployAnalytics(asceswapAddress: string): Promise<Contract> {
  return declareAndDeploy(
    "Analytics",
    { asce_swap: asceswapAddress },
    false
  );
}

// =====================================================================
// Market params & helpers
// =====================================================================

// Convert a JSON market params object to calldata format (u256 as {low, high})
function toCallDataParams(p: MarketParamsJson) {
  return {
    liquidation_threshold_bps: { low: BigInt(p.liquidation_threshold_bps), high: 0n },
    initial_margin_multiplier_bps: { low: BigInt(p.initial_margin_multiplier_bps), high: 0n },
    min_margin_floor_bps: { low: BigInt(p.min_margin_floor_bps), high: 0n },
    min_swap_term_seconds: BigInt(p.min_swap_term_seconds),
    max_swap_term_seconds: BigInt(p.max_swap_term_seconds),
    min_hold_period_seconds: BigInt(p.min_hold_period_seconds),
    swap_fee_bps: { low: BigInt(p.swap_fee_bps), high: 0n },
    early_exit_fee_bps: { low: BigInt(p.early_exit_fee_bps), high: 0n },
    liquidation_bonus_bps: { low: BigInt(p.liquidation_bonus_bps), high: 0n },
    fee_spread_bps: { low: BigInt(p.fee_spread_bps), high: 0n },
    max_imbalance_adjustment_bps: { low: BigInt(p.max_imbalance_adjustment_bps), high: 0n },
    max_utilization_bps: { low: BigInt(p.max_utilization_bps), high: 0n },
    min_notional: { low: BigInt(p.min_notional), high: 0n },
    max_notional_per_swap: { low: BigInt(p.max_notional_per_swap), high: 0n },
    max_oracle_staleness_seconds: BigInt(p.max_oracle_staleness_seconds),
    max_rate_change_per_update_bps: { low: BigInt(p.max_rate_change_per_update_bps), high: 0n },
    min_rate_bps: { low: BigInt(p.min_rate_bps), high: 0n },
    max_rate_bps: { low: BigInt(p.max_rate_bps), high: 0n },
    is_lp_permissioned: p.is_lp_permissioned,
  };
}

// Track the next expected pair_id (contract increments from 1)
let nextExpectedPairId = 1;

async function createMarket(
  asceswapContract: Contract,
  erc20Contract: Contract,
  oracleAddress: string,
  collateralTokenAddress: string,
  curatorAddress: string,
  initialLiquidity: bigint,
  marketParams: MarketParamsJson
): Promise<{ pairId: number; shares: string }> {
  const params = toCallDataParams(marketParams);

  console.log(`\nCreating market pair with initial liquidity...`);
  console.log(`  Oracle: ${oracleAddress}`);
  console.log(`  Collateral Token: ${collateralTokenAddress}`);
  console.log(`  Curator: ${curatorAddress}`);
  console.log(`  Initial Liquidity: ${initialLiquidity}`);
  console.log(`  Term: ${marketParams.min_swap_term_seconds}-${marketParams.max_swap_term_seconds}s | Liq Threshold: ${marketParams.liquidation_threshold_bps} bps | Swap Fee: ${marketParams.swap_fee_bps} bps`);

  // Approve the Asceswap contract to spend collateral tokens for initial liquidity
  console.log(`  Approving tokens for initial liquidity...`);
  const approveTx = await erc20Contract.approve(asceswapContract.address, {
    low: initialLiquidity,
    high: 0n,
  });
  await provider.waitForTransaction(approveTx.transaction_hash);
  console.log(`  Approval confirmed`);

  // Call create_market_pair (includes initial_liquidity_amount)
  const tx = await asceswapContract.create_market_pair(
    oracleAddress,
    collateralTokenAddress,
    curatorAddress,
    params,
    { low: initialLiquidity, high: 0n }
  );

  console.log(`  Market creation tx hash: ${tx.transaction_hash}`);

  await provider.waitForTransaction(tx.transaction_hash);
  console.log(`  Transaction confirmed`);

  // pair_id is incremental (1, 2, 3, ...) — contract assigns next_pair_id++
  // shares for first deposit = initial_liquidity - burned_shares (1000)
  const pairId = nextExpectedPairId++;
  const shares = (initialLiquidity - 1000n).toString();

  console.log(`  Market created with pair_id: ${pairId}, shares: ${shares}`);

  return { pairId, shares };
}

async function mintTokens(
  erc20Contract: Contract,
  recipient: string,
  amount: bigint
): Promise<void> {
  console.log(`\nMinting ${amount} tokens to ${recipient}...`);

  const tx = await erc20Contract.mint(recipient, { low: amount, high: 0n });
  console.log(`Mint tx hash: ${tx.transaction_hash}`);

  await provider.waitForTransaction(tx.transaction_hash);
  console.log(`Tokens minted successfully`);
}

// =====================================================================
// Markets config loader
// =====================================================================

interface MarketParamsJson {
  liquidation_threshold_bps: number;
  initial_margin_multiplier_bps: number;
  min_margin_floor_bps: number;
  min_swap_term_seconds: number;
  max_swap_term_seconds: number;
  min_hold_period_seconds: number;
  swap_fee_bps: number;
  early_exit_fee_bps: number;
  liquidation_bonus_bps: number;
  fee_spread_bps: number;
  max_imbalance_adjustment_bps: number;
  max_utilization_bps: number;
  min_notional: number;
  max_notional_per_swap: number;
  max_oracle_staleness_seconds: number;
  max_rate_change_per_update_bps: number;
  min_rate_bps: number;
  max_rate_bps: number;
  is_lp_permissioned: boolean;
}

interface MarketConfig {
  _comment: string;
  oracle_name: string;
  initial_rate_bps: number;
  initial_liquidity: number;
  params: MarketParamsJson;
}

function loadMarketsConfig(): MarketConfig[] {
  const configPath = path.join(__dirname, "markets.json");
  if (!fs.existsSync(configPath)) {
    throw new Error(`markets.json not found at ${configPath}`);
  }
  const config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  return config.markets;
}

function loadDeployment(): any {
  if (!fs.existsSync(DEPLOYMENT_PATH)) {
    throw new Error(
      `deployment.json not found at ${DEPLOYMENT_PATH}. Run 'deploy-contracts' first.`
    );
  }
  return JSON.parse(fs.readFileSync(DEPLOYMENT_PATH, "utf8"));
}

function saveDeployment(deployment: any): void {
  fs.writeFileSync(DEPLOYMENT_PATH, JSON.stringify(deployment, null, 2));
  console.log(`\nDeployment info saved to: ${DEPLOYMENT_PATH}`);
}

// Helper to get a Contract instance from deployment.json + compiled ABI
function getContractFromDeployment(contractName: string, address: string): Contract {
  const artifacts = loadContractArtifacts(contractName, false);
  return new Contract({
    abi: artifacts.sierra.abi,
    address,
    providerOrAccount: myAccount,
  });
}

// =====================================================================
// Commands
// =====================================================================

// --- ALREADY COMPLETED (Steps 1-5) ---
// The following contracts are already deployed on Sepolia:
//   AccessRegistry: 0x54441a2c3986e4c1864bc85b0c074a18b71236833ee371e922ab1ba67c69d6c
//   MockERC20:      0x1d9aa998223404ef2e0366def09bc152c05f506607291aaf0648bc114b464b5
//   Asceswap:       0x20398118dd1652e09ea7b79844f6108be92799d71b642c4b32a5a8894f37986
//   Analytics:      0x48a8ab2718889215f961350f7686e9a732525cc368750abe0a61fb4afa21139
//   Tokens minted:  610,000,000,000 (610B smallest unit = 600K + 10K buffer USDC)
// These addresses are stored in deployment.json.

// Deploy all core contracts from scratch (only needed for a fresh deployment)
async function deployContracts() {
  console.log("=== Deploy Core Contracts ===\n");

  const admin = owner_account_address;
  const treasury = owner_account_address;

  console.log("\n--- Step 1: Deploy AccessRegistry ---");
  const accessRegistry = await deployAccessRegistry(admin);

  console.log("\n--- Step 2: Deploy MockERC20 (6 decimals) ---");
  const mockERC20 = await deployMockERC20(6);

  console.log("\n--- Step 3: Deploy Asceswap ---");
  const asceswap = await deployAsceswap(accessRegistry.address, treasury);

  console.log("\n--- Step 4: Deploy Analytics ---");
  const analytics = await deployAnalytics(asceswap.address);

  // Mint tokens for 6 markets' initial liquidity + buffer
  const marketsConfig = loadMarketsConfig();
  const totalLiquidity = marketsConfig.reduce((sum, m) => sum + BigInt(m.initial_liquidity), 0n);
  const mintAmount = totalLiquidity + 10000000000n; // +10K USDC buffer
  console.log(`\n--- Step 5: Mint ${mintAmount} tokens to admin ---`);
  await mintTokens(mockERC20, admin, mintAmount);

  console.log("\n=== Core Contracts Deployed ===");
  console.log(`AccessRegistry: ${accessRegistry.address}`);
  console.log(`MockERC20:      ${mockERC20.address}`);
  console.log(`Asceswap:       ${asceswap.address}`);
  console.log(`Analytics:      ${analytics.address}`);

  const deployment = {
    network: process.env.SEPOLIA_RPC,
    timestamp: new Date().toISOString(),
    deployer: admin,
    contracts: {
      accessRegistry: accessRegistry.address,
      mockERC20: mockERC20.address,
      asceswap: asceswap.address,
      analytics: analytics.address,
    },
    tokensMinted: mintAmount.toString(),
    markets: [] as any[],
  };

  saveDeployment(deployment);
  return deployment;
}

// Deploy 6 oracles + create 6 markets using already-deployed contracts from deployment.json
async function createMarkets() {
  const deployment = loadDeployment();

  console.log("=== Create Markets on Existing Deployment ===\n");
  console.log(`Asceswap:  ${deployment.contracts.asceswap}`);
  console.log(`MockERC20: ${deployment.contracts.mockERC20}`);
  console.log(`Analytics: ${deployment.contracts.analytics}`);

  // Connect to already-deployed contracts
  const asceswap = getContractFromDeployment("Asceswap", deployment.contracts.asceswap);
  const mockERC20 = getContractFromDeployment("MockERC20", deployment.contracts.mockERC20);

  const marketsConfig = loadMarketsConfig();
  const initialTimestamp = BigInt(Math.floor(Date.now() / 1000));
  const curator = owner_account_address;

  // Skip minting — 610B tokens already minted to admin in previous run
  console.log(`\nSkipping mint — tokens already minted (${deployment.tokensMinted || "610000000000"})`);

  // Query the contract's next_swap_id to determine the starting pair_id
  // (in case markets were already created previously)
  try {
    const nextSwapId = await asceswap.get_next_swap_id();
    console.log(`Contract next_swap_id: ${nextSwapId}`);
  } catch {
    // Non-critical — just informational
  }

  console.log(`\n--- Deploying ${marketsConfig.length} Oracles & Creating Markets ---`);
  const markets: Array<{
    pairId: number;
    oracleName: string;
    oracleAddress: string;
    initialRateBps: number;
    initialLiquidity: string;
    shares: string;
  }> = [];

  for (let i = 0; i < marketsConfig.length; i++) {
    const mc = marketsConfig[i];
    console.log(`\n--- Market ${i + 1}/${marketsConfig.length}: ${mc.oracle_name} (${mc.initial_rate_bps} bps) ---`);

    // Deploy oracle with name
    const oracle = await deployMockOracle(
      mc.oracle_name,
      BigInt(mc.initial_rate_bps),
      initialTimestamp
    );

    // Create market with initial liquidity (approve + create_market_pair in one flow)
    const { pairId, shares } = await createMarket(
      asceswap,
      mockERC20,
      oracle.address,
      deployment.contracts.mockERC20,
      curator,
      BigInt(mc.initial_liquidity),
      mc.params
    );

    markets.push({
      pairId,
      oracleName: mc.oracle_name,
      oracleAddress: oracle.address,
      initialRateBps: mc.initial_rate_bps,
      initialLiquidity: mc.initial_liquidity.toString(),
      shares,
    });
  }

  // Summary
  console.log("\n\n=== Markets Created ===");
  for (const m of markets) {
    console.log(`  ${m.oracleName} (${m.initialRateBps} bps)`);
    console.log(`    Oracle:  ${m.oracleAddress}`);
    console.log(`    Pair ID: ${m.pairId}`);
    console.log(`    Shares:  ${m.shares}`);
  }

  // Update deployment.json with market data
  deployment.markets = markets;
  deployment.marketsCreatedAt = new Date().toISOString();
  saveDeployment(deployment);

  return markets;
}

// Deploy a single MockOracle: npx ts-node deploy_cairo.ts mock-oracle "ETH Rate" 350
async function deployMockOracleOnly() {
  console.log("=== Deploying MockOracle only ===\n");

  const name = process.argv[3] || "Default Rate";
  const rateBps = BigInt(process.argv[4] || "500");
  const initialTimestamp = BigInt(Math.floor(Date.now() / 1000));
  const mockOracle = await deployMockOracle(name, rateBps, initialTimestamp);

  console.log("\n=== Deployment Summary ===");
  console.log(`MockOracle: ${mockOracle.address}`);
  console.log(`Name: ${name}`);
  console.log(`Rate: ${rateBps} bps`);

  return mockOracle;
}

// =====================================================================
// Main
// =====================================================================

async function main() {
  const args = process.argv.slice(2);
  const command = args[0] || "create-markets";

  switch (command) {
    case "create-markets":
      // Deploy 6 oracles + create 6 markets (uses deployment.json + markets.json)
      // This is the current focus — core contracts are already deployed
      await createMarkets();
      break;
    case "deploy-contracts":
      // Fresh deploy of all core contracts (AccessRegistry, MockERC20, Asceswap, Analytics)
      // Already completed — only run this for a completely fresh deployment
      await deployContracts();
      break;
    case "mock-oracle":
      await deployMockOracleOnly();
      break;
    case "access-registry":
      await deployAccessRegistry(owner_account_address);
      break;
    case "mock-erc20":
      await deployMockERC20(6);
      break;
    default:
      console.log("Usage: npx ts-node deploy_cairo.ts [command]");
      console.log("\nCommands:");
      console.log(
        "  create-markets    - Deploy 6 oracles + create 6 markets (default, uses deployment.json)"
      );
      console.log(
        "  deploy-contracts  - Fresh deploy of all core contracts (already done)"
      );
      console.log(
        '  mock-oracle       - Deploy single MockOracle: mock-oracle "Name" 500'
      );
      console.log("  access-registry   - Deploy AccessRegistry only");
      console.log("  mock-erc20        - Deploy MockERC20 only");
      process.exit(1);
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
