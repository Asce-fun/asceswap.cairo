import { Account, json, RpcProvider, Contract, hash } from "starknet";
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
// Artifact loading helpers (shared with deploy_testnet.ts)
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
// Load existing deployment
// =====================================================================

interface DeployedMarket {
  pairId: number;
  oracleName: string;
  oracleAddress: string;
  collateral: string;
  collateralTokenAddress: string;
  initialRateBps: number;
  initialLiquidity: string;
  shares: string;
}

interface Deployment {
  network: string;
  timestamp: string;
  deployer: string;
  contracts: {
    accessRegistry: string;
    asceswap: string;
    analytics: string;
  };
  tokens: Record<string, string>;
  markets: DeployedMarket[];
}

function loadDeployment(): Deployment {
  if (!fs.existsSync(DEPLOYMENT_PATH)) {
    throw new Error(`Deployment file not found: ${DEPLOYMENT_PATH}. Run deploy_testnet.ts first.`);
  }
  return JSON.parse(fs.readFileSync(DEPLOYMENT_PATH, "utf8"));
}

function saveDeployment(deployment: any): void {
  fs.writeFileSync(DEPLOYMENT_PATH, JSON.stringify(deployment, null, 2));
  console.log(`\nDeployment saved to: ${DEPLOYMENT_PATH}`);
}

// =====================================================================
// Upgrade + Oracle Migration
// =====================================================================

async function upgradeAndMigrate() {
  const deployment = loadDeployment();
  const admin = owner_account_address;
  const initialTimestamp = BigInt(Math.floor(Date.now() / 1000));

  console.log("=== Upgrade Asceswap + Deploy New Oracles with History ===\n");
  console.log(`Deployer: ${admin}`);
  console.log(`Asceswap: ${deployment.contracts.asceswap}`);
  console.log(`Markets: ${deployment.markets.length}\n`);

  // ------------------------------------------------------------------
  // Step 1: Declare new Asceswap class hash and upgrade
  // ------------------------------------------------------------------
  console.log("--- Step 1: Declare New Asceswap Class & Upgrade ---\n");

  const asceswapArtifacts = loadContractArtifacts("Asceswap");
  if (!asceswapArtifacts.casm) {
    throw new Error("Missing CASM for Asceswap. Run 'scarb build' first.");
  }

  // Declare the new class
  console.log("  Declaring new Asceswap class...");
  const declareResponse = await myAccount.declareIfNot({
    contract: asceswapArtifacts.sierra,
    casm: asceswapArtifacts.casm,
  });

  let newClassHash: string;
  if (declareResponse.transaction_hash) {
    await provider.waitForTransaction(declareResponse.transaction_hash);
    console.log(`  Declared tx: ${declareResponse.transaction_hash}`);
    newClassHash = declareResponse.class_hash;
  } else {
    newClassHash = declareResponse.class_hash;
    console.log(`  Class already declared.`);
  }
  console.log(`  New class hash: ${newClassHash}\n`);

  // Call upgrade_class_hash on the deployed Asceswap (via SecurityImpl)
  console.log("  Upgrading Asceswap contract...");
  const asceswapInstance = getContractInstance("Asceswap", deployment.contracts.asceswap);
  const upgradeTx = await asceswapInstance.upgrade_class_hash(newClassHash);
  await provider.waitForTransaction(upgradeTx.transaction_hash);
  console.log(`  Upgrade tx: ${upgradeTx.transaction_hash}\n`);

  // ------------------------------------------------------------------
  // Step 2: Deploy new MockRateOracle contracts (with history)
  // ------------------------------------------------------------------
  console.log("--- Step 2: Deploy New Oracles with History ---\n");

  const newOracles: Array<{ pairId: number; oracleName: string; oldAddress: string; newAddress: string }> = [];

  for (const market of deployment.markets) {
    console.log(`  [${market.pairId}] ${market.oracleName} (${market.initialRateBps} bps)`);

    const oracle = await declareAndDeploy("MockRateOracle", {
      owner: admin,
      name: market.oracleName,
      initial_rate: { low: BigInt(market.initialRateBps), high: 0n },
      initial_timestamp: initialTimestamp,
    });

    newOracles.push({
      pairId: market.pairId,
      oracleName: market.oracleName,
      oldAddress: market.oracleAddress,
      newAddress: oracle.address,
    });

    console.log(`    Old: ${market.oracleAddress}`);
    console.log(`    New: ${oracle.address}\n`);
  }

  // ------------------------------------------------------------------
  // Step 3: Update each market to point to new oracle
  // ------------------------------------------------------------------
  console.log("--- Step 3: Update Market Oracles ---\n");

  // Re-create instance after upgrade (ABI may have changed)
  const upgradedAsceswap = getContractInstance("Asceswap", deployment.contracts.asceswap);

  for (const oracle of newOracles) {
    console.log(`  [${oracle.pairId}] ${oracle.oracleName} -> ${oracle.newAddress}`);

    const tx = await upgradedAsceswap.update_market_oracle(oracle.pairId, oracle.newAddress);
    await provider.waitForTransaction(tx.transaction_hash);
    console.log(`    tx: ${tx.transaction_hash}`);
  }

  // ------------------------------------------------------------------
  // Step 4: Update deployment file
  // ------------------------------------------------------------------
  console.log("\n--- Step 4: Save Updated Deployment ---\n");

  const updatedMarkets = deployment.markets.map((market) => {
    const newOracle = newOracles.find((o) => o.pairId === market.pairId);
    return {
      ...market,
      oracleAddress: newOracle ? newOracle.newAddress : market.oracleAddress,
    };
  });

  const updatedDeployment = {
    ...deployment,
    timestamp: new Date().toISOString(),
    upgradeClassHash: newClassHash,
    markets: updatedMarkets,
  };

  saveDeployment(updatedDeployment);

  // ------------------------------------------------------------------
  // Summary
  // ------------------------------------------------------------------
  console.log("\n=== Upgrade Complete ===\n");
  console.log(`New class hash: ${newClassHash}`);
  console.log("\nUpdated oracles:");
  for (const oracle of newOracles) {
    console.log(`  [${oracle.pairId}] ${oracle.oracleName}: ${oracle.newAddress}`);
  }
}

// =====================================================================
// Deploy oracles only (without upgrade)
// =====================================================================

async function deployOraclesOnly() {
  const deployment = loadDeployment();
  const admin = owner_account_address;
  const initialTimestamp = BigInt(Math.floor(Date.now() / 1000));

  console.log("=== Deploy New Oracles Only (no upgrade) ===\n");

  for (const market of deployment.markets) {
    console.log(`[${market.pairId}] ${market.oracleName} (${market.initialRateBps} bps)`);

    const oracle = await declareAndDeploy("MockRateOracle", {
      owner: admin,
      name: market.oracleName,
      initial_rate: { low: BigInt(market.initialRateBps), high: 0n },
      initial_timestamp: initialTimestamp,
    });

    console.log(`  Address: ${oracle.address}\n`);
  }
}

// =====================================================================
// Update oracles only (assumes upgrade already done, oracles already deployed)
// =====================================================================

async function updateOraclesOnly(oracleAddresses: string[]) {
  const deployment = loadDeployment();

  if (oracleAddresses.length !== deployment.markets.length) {
    throw new Error(
      `Expected ${deployment.markets.length} oracle addresses, got ${oracleAddresses.length}`
    );
  }

  console.log("=== Update Market Oracles Only ===\n");

  const asceswap = getContractInstance("Asceswap", deployment.contracts.asceswap);

  for (let i = 0; i < deployment.markets.length; i++) {
    const market = deployment.markets[i];
    const newOracle = oracleAddresses[i];

    console.log(`[${market.pairId}] ${market.oracleName} -> ${newOracle}`);
    const tx = await asceswap.update_market_oracle(market.pairId, newOracle);
    await provider.waitForTransaction(tx.transaction_hash);
    console.log(`  tx: ${tx.transaction_hash}\n`);
  }

  // Update deployment file
  const updatedMarkets = deployment.markets.map((market, i) => ({
    ...market,
    oracleAddress: oracleAddresses[i],
  }));

  const updatedDeployment = {
    ...deployment,
    timestamp: new Date().toISOString(),
    markets: updatedMarkets,
  };

  saveDeployment(updatedDeployment);
}

// =====================================================================
// Upgrade + Update Market Params
// =====================================================================

interface MarketConfig {
  oracle_name: string;
  collateral: string;
  initial_rate_bps: number;
  params: {
    liquidation_threshold_bps: number;
    initial_margin_multiplier_bps: number;
    min_margin_floor_bps: number;
    swap_term_seconds: number;
    min_hold_period_seconds: number;
    swap_fee_bps: number;
    early_exit_fee_bps: number;
    liquidation_bonus_bps: number;
    base_fee_spread_bps: number;
    demand_spread_factor: number;
    max_total_utilization_bps: number;
    min_notional: string | number;
    max_oracle_staleness_seconds: number;
    max_rate_change_per_update_bps: number;
    is_lp_permissioned: boolean;
  };
}

function loadMarketsConfig(): { markets: MarketConfig[] } {
  return JSON.parse(fs.readFileSync(MARKETS_CONFIG_PATH, "utf8"));
}

async function upgradeAndUpdateParams() {
  const deployment = loadDeployment();
  const marketsConfig = loadMarketsConfig();

  console.log("=== Upgrade Asceswap + Update Market Params ===\n");
  console.log(`Deployer: ${owner_account_address}`);
  console.log(`Asceswap: ${deployment.contracts.asceswap}`);
  console.log(`Markets: ${deployment.markets.length}\n`);

  // ------------------------------------------------------------------
  // Step 1: Declare new Asceswap class hash and upgrade
  // ------------------------------------------------------------------
  console.log("--- Step 1: Declare New Asceswap Class & Upgrade ---\n");

  const asceswapArtifacts = loadContractArtifacts("Asceswap");
  if (!asceswapArtifacts.casm) {
    throw new Error("Missing CASM for Asceswap. Run 'scarb build' first.");
  }

  console.log("  Declaring new Asceswap class...");
  const declareResponse = await myAccount.declareIfNot({
    contract: asceswapArtifacts.sierra,
    casm: asceswapArtifacts.casm,
  });

  let newClassHash: string;
  if (declareResponse.transaction_hash) {
    await provider.waitForTransaction(declareResponse.transaction_hash);
    console.log(`  Declared tx: ${declareResponse.transaction_hash}`);
    newClassHash = declareResponse.class_hash;
  } else {
    newClassHash = declareResponse.class_hash;
    console.log(`  Class already declared.`);
  }
  console.log(`  New class hash: ${newClassHash}\n`);

  // Call upgrade_class_hash on the deployed Asceswap
  console.log("  Upgrading Asceswap contract...");
  const asceswapInstance = getContractInstance("Asceswap", deployment.contracts.asceswap);
  const upgradeTx = await asceswapInstance.upgrade_class_hash(newClassHash);
  await provider.waitForTransaction(upgradeTx.transaction_hash);
  console.log(`  Upgrade tx: ${upgradeTx.transaction_hash}\n`);

  // ------------------------------------------------------------------
  // Step 2: Update market params for each market
  // ------------------------------------------------------------------
  console.log("--- Step 2: Update Market Params ---\n");

  // Re-create instance after upgrade (ABI may have changed)
  const upgradedAsceswap = getContractInstance("Asceswap", deployment.contracts.asceswap);

  for (let i = 0; i < deployment.markets.length; i++) {
    const market = deployment.markets[i];
    const config = marketsConfig.markets[i];

    if (!config) {
      console.log(`  [${market.pairId}] ${market.oracleName}: SKIPPED (no config at index ${i})`);
      continue;
    }

    const p = config.params;
    console.log(`  [${market.pairId}] ${market.oracleName}`);
    console.log(`    max_oracle_staleness: ${p.max_oracle_staleness_seconds}s (${p.max_oracle_staleness_seconds / 3600}h)`);

    // Build MarketParams struct for Cairo
    const paramsCalldata = {
      liquidation_threshold_bps: { low: BigInt(p.liquidation_threshold_bps), high: 0n },
      initial_margin_multiplier_bps: { low: BigInt(p.initial_margin_multiplier_bps), high: 0n },
      min_margin_floor_bps: { low: BigInt(p.min_margin_floor_bps), high: 0n },
      swap_term_seconds: BigInt(p.swap_term_seconds),
      min_hold_period_seconds: BigInt(p.min_hold_period_seconds),
      swap_fee_bps: { low: BigInt(p.swap_fee_bps), high: 0n },
      early_exit_fee_bps: { low: BigInt(p.early_exit_fee_bps), high: 0n },
      liquidation_bonus_bps: { low: BigInt(p.liquidation_bonus_bps), high: 0n },
      base_fee_spread_bps: { low: BigInt(p.base_fee_spread_bps), high: 0n },
      demand_spread_factor: { low: BigInt(p.demand_spread_factor), high: 0n },
      max_total_utilization_bps: { low: BigInt(p.max_total_utilization_bps), high: 0n },
      min_notional: { low: BigInt(p.min_notional), high: 0n },
      max_oracle_staleness_seconds: BigInt(p.max_oracle_staleness_seconds),
      max_rate_change_per_update_bps: { low: BigInt(p.max_rate_change_per_update_bps), high: 0n },
      is_lp_permissioned: p.is_lp_permissioned,
    };

    try {
      const tx = await upgradedAsceswap.update_market_params(market.pairId, paramsCalldata);
      await provider.waitForTransaction(tx.transaction_hash);
      console.log(`    tx: ${tx.transaction_hash}`);
    } catch (err: any) {
      console.error(`    ERROR: ${err.message || err}`);
    }
  }

  // ------------------------------------------------------------------
  // Step 3: Save updated deployment
  // ------------------------------------------------------------------
  console.log("\n--- Step 3: Save Updated Deployment ---\n");

  const updatedDeployment = {
    ...deployment,
    timestamp: new Date().toISOString(),
    upgradeClassHash: newClassHash,
  };

  saveDeployment(updatedDeployment);

  console.log("\n=== Upgrade & Params Update Complete ===\n");
  console.log(`New class hash: ${newClassHash}`);
}

// =====================================================================
// Update market params only (no upgrade — use after already upgrading)
// =====================================================================

async function updateParamsOnly() {
  const deployment = loadDeployment();
  const marketsConfig = loadMarketsConfig();

  console.log("=== Update Market Params Only ===\n");

  const asceswap = getContractInstance("Asceswap", deployment.contracts.asceswap);

  for (let i = 0; i < deployment.markets.length; i++) {
    const market = deployment.markets[i];
    const config = marketsConfig.markets[i];

    if (!config) continue;

    const p = config.params;
    console.log(`[${market.pairId}] ${market.oracleName}`);

    const paramsCalldata = {
      liquidation_threshold_bps: { low: BigInt(p.liquidation_threshold_bps), high: 0n },
      initial_margin_multiplier_bps: { low: BigInt(p.initial_margin_multiplier_bps), high: 0n },
      min_margin_floor_bps: { low: BigInt(p.min_margin_floor_bps), high: 0n },
      swap_term_seconds: BigInt(p.swap_term_seconds),
      min_hold_period_seconds: BigInt(p.min_hold_period_seconds),
      swap_fee_bps: { low: BigInt(p.swap_fee_bps), high: 0n },
      early_exit_fee_bps: { low: BigInt(p.early_exit_fee_bps), high: 0n },
      liquidation_bonus_bps: { low: BigInt(p.liquidation_bonus_bps), high: 0n },
      base_fee_spread_bps: { low: BigInt(p.base_fee_spread_bps), high: 0n },
      demand_spread_factor: { low: BigInt(p.demand_spread_factor), high: 0n },
      max_total_utilization_bps: { low: BigInt(p.max_total_utilization_bps), high: 0n },
      min_notional: { low: BigInt(p.min_notional), high: 0n },
      max_oracle_staleness_seconds: BigInt(p.max_oracle_staleness_seconds),
      max_rate_change_per_update_bps: { low: BigInt(p.max_rate_change_per_update_bps), high: 0n },
      is_lp_permissioned: p.is_lp_permissioned,
    };

    try {
      const tx = await asceswap.update_market_params(market.pairId, paramsCalldata);
      await provider.waitForTransaction(tx.transaction_hash);
      console.log(`  tx: ${tx.transaction_hash}`);
    } catch (err: any) {
      console.error(`  ERROR: ${err.message || err}`);
    }
  }
}

// =====================================================================
// Main
// =====================================================================

async function main() {
  const command = process.argv[2] || "upgrade-all";

  switch (command) {
    case "upgrade-all":
      await upgradeAndMigrate();
      break;
    case "upgrade-params":
      await upgradeAndUpdateParams();
      break;
    case "update-params":
      await updateParamsOnly();
      break;
    case "deploy-oracles":
      await deployOraclesOnly();
      break;
    case "update-oracles": {
      const addresses = process.argv.slice(3);
      if (addresses.length === 0) {
        console.log("Usage: npx ts-node deploy_upgrade.ts update-oracles <addr1> <addr2> ...");
        process.exit(1);
      }
      await updateOraclesOnly(addresses);
      break;
    }
    default:
      console.log("Usage: npx ts-node deploy_upgrade.ts [command]\n");
      console.log("Commands:");
      console.log("  upgrade-all      Full upgrade: declare new class, upgrade contract, deploy new oracles, update markets (default)");
      console.log("  upgrade-params   Declare new class, upgrade contract, update market params from testnet_markets.json");
      console.log("  update-params    Update market params only (no upgrade, assumes contract already upgraded)");
      console.log("  deploy-oracles   Deploy new oracle contracts only (no upgrade, no market update)");
      console.log("  update-oracles   Update market oracles only (pass oracle addresses as args)");
      process.exit(1);
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
