import { Account, json, RpcProvider, Contract } from "starknet";
import fs from "fs";
import dotenv from "dotenv";
import path from "path";

const envPath = path.join(__dirname, ".env");
dotenv.config({ path: envPath });

const provider = new RpcProvider({ nodeUrl: process.env.SEPOLIA_RPC as string });

const owner_private_key = process.env.PRIVATE_KEY as string;
const owner_account_address = process.env.ACCOUNT_ADDRESS as string;

const myAccount = new Account({
  provider: provider,
  address: owner_account_address,
  signer: owner_private_key,
});

const DEV_DIR = path.join(__dirname, "..", "target", "dev");
const DEPLOYMENT_PATH = path.join(__dirname, "testnet_deployment.json");
const MARKETS_CONFIG_PATH = path.join(__dirname, "testnet_markets.json");

// =====================================================================
// Artifact loading & deploy helpers (reused from deploy_cairo.ts)
// =====================================================================

interface ContractArtifacts {
  sierra: any;
  casm: any | null;
  sierraFile: string;
  casmFile: string | null;
}

function loadContractArtifacts(contractName: string): ContractArtifacts {
  if (!fs.existsSync(DEV_DIR)) {
    throw new Error(`Missing target/dev directory: ${DEV_DIR}. Run 'scarb build' first.`);
  }

  const files = fs.readdirSync(DEV_DIR);

  const sierraFile = files.find(
    (f) => f.endsWith(".contract_class.json") && f.includes(contractName) && !f.includes(".test.")
  );

  if (!sierraFile) {
    throw new Error(`Missing Sierra file for ${contractName} in ${DEV_DIR}`);
  }

  const casmFile = files.find(
    (f) => f.endsWith(".compiled_contract_class.json") && f.includes(contractName) && !f.includes(".test.")
  );

  const sierraPath = path.join(DEV_DIR, sierraFile);
  const casmPath = casmFile ? path.join(DEV_DIR, casmFile) : null;

  console.log(`  Loading ${contractName}: ${sierraFile}`);

  return {
    sierra: json.parse(fs.readFileSync(sierraPath, "utf8")),
    casm: casmPath ? json.parse(fs.readFileSync(casmPath, "utf8")) : null,
    sierraFile,
    casmFile: casmFile || null,
  };
}

async function declareAndDeploy(contractName: string, constructorCalldata: any): Promise<Contract> {
  const artifacts = loadContractArtifacts(contractName);

  if (!artifacts.casm) {
    throw new Error(`Missing CASM file for ${contractName}. Ensure casm = true in Scarb.toml and run 'scarb build'.`);
  }

  console.log(`  Declaring and deploying ${contractName}...`);

  const myContract = await Contract.factory({
    contract: artifacts.sierra,
    casm: artifacts.casm,
    account: myAccount,
    constructorCalldata,
  });

  console.log(`  ${contractName} deployed at: ${myContract.address}`);
  return myContract;
}

function getContractInstance(contractName: string, address: string): Contract {
  const artifacts = loadContractArtifacts(contractName);
  return new Contract({
    abi: artifacts.sierra.abi,
    address,
    providerOrAccount: myAccount,
  });
}

// =====================================================================
// Config types & loader
// =====================================================================

interface MarketParamsJson {
  liquidation_threshold_bps: number;
  initial_margin_multiplier_bps: number;
  min_margin_floor_bps: number;
  swap_term_seconds: number;
  min_hold_period_seconds: number;
  swap_fee_bps: number;
  early_exit_fee_bps: number;
  liquidation_bonus_bps: number;
  fee_spread_bps: number;
  max_imbalance_adjustment_bps: number;
  max_utilization_bps: number;
  min_notional: number | string;
  max_notional_per_swap: number | string;
  max_oracle_staleness_seconds: number;
  max_rate_change_per_update_bps: number;
  min_rate_bps: number;
  max_rate_bps: number;
  is_lp_permissioned: boolean;
}

interface TokenConfig {
  symbol: string;
  name: string;
  decimals: number;
  mint_amount: number | string;
  mint_cooldown: number;
}

interface TestnetMarketConfig {
  _comment?: string;
  oracle_name: string;
  collateral: string; // symbol referencing a token in the tokens array
  initial_rate_bps: number;
  params: MarketParamsJson;
}

interface TestnetConfig {
  tokens: TokenConfig[];
  markets: TestnetMarketConfig[];
}

function loadTestnetConfig(): TestnetConfig {
  if (!fs.existsSync(MARKETS_CONFIG_PATH)) {
    throw new Error(`testnet_markets.json not found at ${MARKETS_CONFIG_PATH}`);
  }
  return JSON.parse(fs.readFileSync(MARKETS_CONFIG_PATH, "utf8"));
}

function toCallDataParams(p: MarketParamsJson) {
  return {
    liquidation_threshold_bps: { low: BigInt(p.liquidation_threshold_bps), high: 0n },
    initial_margin_multiplier_bps: { low: BigInt(p.initial_margin_multiplier_bps), high: 0n },
    min_margin_floor_bps: { low: BigInt(p.min_margin_floor_bps), high: 0n },
    swap_term_seconds: BigInt(p.swap_term_seconds),
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

// =====================================================================
// Deploy functions for new mock contracts
// =====================================================================

async function deployMockToken(owner: string, token: TokenConfig): Promise<Contract> {
  // MockToken constructor: (owner: ContractAddress, name: ByteArray, symbol: ByteArray, decimals: u8, mint_amount: u256, mint_cooldown_seconds: u64)
  return declareAndDeploy("MockToken", {
    owner,
    name: token.name,
    symbol: token.symbol,
    decimals: token.decimals,
    mint_amount: { low: BigInt(token.mint_amount), high: 0n },
    mint_cooldown_seconds: BigInt(token.mint_cooldown),
  });
}

async function deployMockRateOracle(
  owner: string,
  name: string,
  initialRateBps: bigint,
  initialTimestamp: bigint
): Promise<Contract> {
  // MockRateOracle constructor: (owner: ContractAddress, name: ByteArray, initial_rate: u256, initial_timestamp: u64)
  return declareAndDeploy("MockRateOracle", {
    owner,
    name,
    initial_rate: { low: initialRateBps, high: 0n },
    initial_timestamp: initialTimestamp,
  });
}

async function deployAccessRegistry(admin: string): Promise<Contract> {
  return declareAndDeploy("AccessRegistry", { owner: admin });
}

async function deployAsceswap(accessRegistryAddress: string, treasuryAddress: string): Promise<Contract> {
  return declareAndDeploy("Asceswap", {
    access_registry: accessRegistryAddress,
    treasury: treasuryAddress,
  });
}

async function deployAnalytics(asceswapAddress: string): Promise<Contract> {
  return declareAndDeploy("Analytics", { asce_swap: asceswapAddress });
}

// =====================================================================
// Persistence
// =====================================================================

function saveDeployment(deployment: any): void {
  fs.writeFileSync(DEPLOYMENT_PATH, JSON.stringify(deployment, null, 2));
  console.log(`\nDeployment saved to: ${DEPLOYMENT_PATH}`);
}

// =====================================================================
// Main deployment flow
// =====================================================================

// Initial liquidity per market — enough to bootstrap the pool.
// For testnet, we use a fixed amount per collateral type.
const INITIAL_LIQUIDITY: Record<string, bigint> = {
  mockUSDC: 100_000_000_000n,         // 100,000 USDC (6 decimals)
  mockBTC:  1_000_000_00n,             // 1 BTC (8 decimals)
  mockSTRK: 10_000_000_000_000_000_000_000n, // 10,000 STRK (18 decimals)
};

async function deployAll() {
  const config = loadTestnetConfig();
  const admin = owner_account_address;
  const initialTimestamp = BigInt(Math.floor(Date.now() / 1000));

  console.log("=== Testnet Full Deployment ===");
  console.log(`Deployer: ${admin}`);
  console.log(`Tokens: ${config.tokens.length} | Markets: ${config.markets.length}\n`);

  // ------------------------------------------------------------------
  // Step 1: Deploy core contracts
  // ------------------------------------------------------------------
  console.log("--- Step 1: Deploy Core Contracts ---\n");

  console.log("[1/3] AccessRegistry");
  const accessRegistry = await deployAccessRegistry(admin);

  console.log("\n[2/3] Asceswap");
  const asceswap = await deployAsceswap(accessRegistry.address, admin);

  console.log("\n[3/3] Analytics");
  const analytics = await deployAnalytics(asceswap.address);

  // ------------------------------------------------------------------
  // Step 2: Deploy mock tokens
  // ------------------------------------------------------------------
  console.log("\n--- Step 2: Deploy Mock Tokens ---\n");

  const tokenContracts: Record<string, Contract> = {};
  const tokenAddresses: Record<string, string> = {};

  for (let i = 0; i < config.tokens.length; i++) {
    const token = config.tokens[i];
    console.log(`[${i + 1}/${config.tokens.length}] ${token.symbol} (${token.name}, ${token.decimals} decimals)`);
    const contract = await deployMockToken(admin, token);
    tokenContracts[token.symbol] = contract;
    tokenAddresses[token.symbol] = contract.address;
    console.log("");
  }

  // ------------------------------------------------------------------
  // Step 3: Owner mint large amounts for initial liquidity
  // ------------------------------------------------------------------
  console.log("--- Step 3: Owner Mint for Initial Liquidity ---\n");

  // Calculate total needed per token across all markets (with 10x buffer for testing)
  const totalNeeded: Record<string, bigint> = {};
  for (const market of config.markets) {
    const liq = INITIAL_LIQUIDITY[market.collateral];
    if (!liq) throw new Error(`No INITIAL_LIQUIDITY defined for ${market.collateral}`);
    totalNeeded[market.collateral] = (totalNeeded[market.collateral] || 0n) + liq;
  }

  // Owner mint — single call per token, large amount (total needed * 10 for buffer)
  for (const [symbol, needed] of Object.entries(totalNeeded)) {
    const tokenContract = tokenContracts[symbol];
    const mintAmount = needed * 10n; // 10x buffer for testing swaps, LP deposits, etc.

    console.log(`${symbol}: minting ${mintAmount} to deployer (${needed} needed for markets + 9x buffer)...`);
    const tx = await tokenContract.owner_mint(admin, { low: mintAmount, high: 0n });
    await provider.waitForTransaction(tx.transaction_hash);

    const balance = await tokenContract.balance_of(admin);
    console.log(`  Balance: ${balance}\n`);
  }

  // ------------------------------------------------------------------
  // Step 4: Deploy rate oracles & create markets
  // ------------------------------------------------------------------
  console.log("--- Step 4: Deploy Rate Oracles & Create Markets ---\n");

  let nextExpectedPairId = 1;
  const markets: Array<{
    pairId: number;
    oracleName: string;
    oracleAddress: string;
    collateral: string;
    collateralTokenAddress: string;
    initialRateBps: number;
    initialLiquidity: string;
    shares: string;
  }> = [];

  for (let i = 0; i < config.markets.length; i++) {
    const mc = config.markets[i];
    const collateralAddress = tokenAddresses[mc.collateral];
    const collateralContract = tokenContracts[mc.collateral];
    const initialLiquidity = INITIAL_LIQUIDITY[mc.collateral];

    if (!collateralAddress) {
      throw new Error(`Token ${mc.collateral} not found. Check testnet_markets.json collateral field.`);
    }

    console.log(`[${i + 1}/${config.markets.length}] ${mc.oracle_name}`);
    console.log(`  Collateral: ${mc.collateral} (${collateralAddress})`);
    console.log(`  Rate: ${mc.initial_rate_bps} bps | Term: ${mc.params.swap_term_seconds}s`);

    // Deploy rate oracle (owner = deployer)
    console.log(`  Deploying MockRateOracle...`);
    const oracle = await deployMockRateOracle(
      admin,
      mc.oracle_name,
      BigInt(mc.initial_rate_bps),
      initialTimestamp
    );

    // Approve collateral for initial liquidity
    console.log(`  Approving ${initialLiquidity} ${mc.collateral} for Asceswap...`);
    const approveTx = await collateralContract.approve(asceswap.address, {
      low: initialLiquidity,
      high: 0n,
    });
    await provider.waitForTransaction(approveTx.transaction_hash);

    // Create market pair
    console.log(`  Creating market pair...`);
    const asceswapInstance = getContractInstance("Asceswap", asceswap.address);
    const params = toCallDataParams(mc.params);

    const createTx = await asceswapInstance.create_market_pair(
      oracle.address,
      collateralAddress,
      admin, // curator = deployer
      params,
      { low: initialLiquidity, high: 0n }
    );
    await provider.waitForTransaction(createTx.transaction_hash);

    const pairId = nextExpectedPairId++;
    const shares = (initialLiquidity - 1000n).toString();

    console.log(`  Market created: pair_id=${pairId}, shares=${shares}\n`);

    markets.push({
      pairId,
      oracleName: mc.oracle_name,
      oracleAddress: oracle.address,
      collateral: mc.collateral,
      collateralTokenAddress: collateralAddress,
      initialRateBps: mc.initial_rate_bps,
      initialLiquidity: initialLiquidity.toString(),
      shares,
    });
  }

  // ------------------------------------------------------------------
  // Summary & save
  // ------------------------------------------------------------------
  console.log("\n=== Deployment Complete ===\n");
  console.log("Core Contracts:");
  console.log(`  AccessRegistry: ${accessRegistry.address}`);
  console.log(`  Asceswap:       ${asceswap.address}`);
  console.log(`  Analytics:      ${analytics.address}`);

  console.log("\nMock Tokens:");
  for (const [symbol, addr] of Object.entries(tokenAddresses)) {
    console.log(`  ${symbol}: ${addr}`);
  }

  console.log("\nMarkets:");
  for (const m of markets) {
    console.log(`  [${m.pairId}] ${m.oracleName} (${m.initialRateBps} bps)`);
    console.log(`      Oracle:     ${m.oracleAddress}`);
    console.log(`      Collateral: ${m.collateral} (${m.collateralTokenAddress})`);
  }

  const deployment = {
    network: process.env.SEPOLIA_RPC,
    timestamp: new Date().toISOString(),
    deployer: admin,
    contracts: {
      accessRegistry: accessRegistry.address,
      asceswap: asceswap.address,
      analytics: analytics.address,
    },
    tokens: tokenAddresses,
    markets,
  };

  saveDeployment(deployment);
  return deployment;
}

// =====================================================================
// Individual commands for partial re-runs
// =====================================================================

async function deployTokensOnly() {
  const config = loadTestnetConfig();
  const admin = owner_account_address;
  console.log("=== Deploy Mock Tokens Only ===\n");

  const tokenAddresses: Record<string, string> = {};
  for (const token of config.tokens) {
    console.log(`Deploying ${token.symbol}...`);
    const contract = await deployMockToken(admin, token);
    tokenAddresses[token.symbol] = contract.address;
    console.log("");
  }

  console.log("\nTokens deployed:");
  for (const [symbol, addr] of Object.entries(tokenAddresses)) {
    console.log(`  ${symbol}: ${addr}`);
  }
}

async function deployOraclesOnly() {
  const config = loadTestnetConfig();
  const admin = owner_account_address;
  const initialTimestamp = BigInt(Math.floor(Date.now() / 1000));

  console.log("=== Deploy Rate Oracles Only ===\n");

  for (const market of config.markets) {
    console.log(`Deploying oracle: ${market.oracle_name} (${market.initial_rate_bps} bps)...`);
    const oracle = await deployMockRateOracle(
      admin,
      market.oracle_name,
      BigInt(market.initial_rate_bps),
      initialTimestamp
    );
    console.log(`  Address: ${oracle.address}\n`);
  }
}

// =====================================================================
// Main
// =====================================================================

async function main() {
  const command = process.argv[2] || "deploy-all";

  switch (command) {
    case "deploy-all":
      await deployAll();
      break;
    case "deploy-tokens":
      await deployTokensOnly();
      break;
    case "deploy-oracles":
      await deployOraclesOnly();
      break;
    default:
      console.log("Usage: npx ts-node deploy_testnet.ts [command]\n");
      console.log("Commands:");
      console.log("  deploy-all      Full deployment: tokens + oracles + core contracts + markets (default)");
      console.log("  deploy-tokens   Deploy mock tokens only (mockUSDC, mockBTC, mockSTRK)");
      console.log("  deploy-oracles  Deploy rate oracles only (one per market)");
      process.exit(1);
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
