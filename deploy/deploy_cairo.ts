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

  // Find Sierra file (contract_class.json)
  // First try main contracts, then fall back to test contracts if allowed
  let sierraFile = files.find(
    (f) => f.endsWith(".contract_class.json") && f.includes(contractName) && !f.includes(".test.")
  );

  // If not found and test contracts allowed, try test contracts
  if (!sierraFile && allowTestContracts) {
    sierraFile = files.find(
      (f) => f.endsWith(".test.contract_class.json") && f.includes(contractName)
    );
  }

  if (!sierraFile) {
    throw new Error(`Missing Sierra file for ${contractName} in ${DEV_DIR}`);
  }

  // Find CASM file (compiled_contract_class.json) - optional
  let casmFile = files.find(
    (f) => f.endsWith(".compiled_contract_class.json") && f.includes(contractName) && !f.includes(".test.")
  );

  // If not found and test contracts allowed, try test contracts
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
    console.error(`\nTo generate CASM files, you have two options:`);
    console.error(`\n1. Add casm = true to Scarb.toml:`);
    console.error(`   [[target.starknet-contract]]`);
    console.error(`   sierra = true`);
    console.error(`   casm = true`);
    console.error(`\n2. Use starkli or sncast for deployment instead`);
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

// Deploy AccessRegistry
async function deployAccessRegistry(admin: string): Promise<Contract> {
  return declareAndDeploy("AccessRegistry", { owner: admin }, false);
}

// Deploy MockOracle for mainnet fork testing
async function deployMockOracle(
  initialRateBps: bigint,
  initialTimestamp: bigint
): Promise<Contract> {
  // MockOracle constructor: (initial_rate: u256, initial_timestamp: u64)
  // u256 is serialized as (low, high) for felt252 arrays
  return declareAndDeploy(
    "MockOracle",
    {
      initial_rate: { low: initialRateBps, high: 0n },
      initial_timestamp: initialTimestamp,
    },
    false // Now using main src/mocks.cairo
  );
}

// Deploy MockERC20
async function deployMockERC20(decimals: number): Promise<Contract> {
  return declareAndDeploy("MockERC20", { decimals: decimals }, false);
}

// Deploy Asceswap main contract
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

// Default market parameters (matching test Helper::default_market_params)
function getDefaultMarketParams() {
  return {
    liquidation_threshold_bps: { low: 8000n, high: 0n },
    initial_margin_multiplier_bps: { low: 12000n, high: 0n }, // 120% of max exposure
    min_margin_floor_bps: { low: 2000n, high: 0n }, // 20% minimum at expiry
    swap_term_seconds: 2592000n, // 30 days
    min_hold_period_seconds: 3600n, // 1 hour before early exit allowed
    swap_fee_bps: { low: 50n, high: 0n }, // 0.5% on collateral at entry
    early_exit_fee_bps: { low: 100n, high: 0n }, // 1% penalty for early exit
    liquidation_bonus_bps: { low: 500n, high: 0n }, // 5% incentive for liquidators
    fee_spread_bps: { low: 25n, high: 0n }, // 0.25%
    max_imbalance_adjustment_bps: { low: 200n, high: 0n }, // 2%
    max_utilization_bps: { low: 8000n, high: 0n }, // 80%
    min_notional: { low: 1000000n, high: 0n }, // 1 USDC (6 decimals)
    max_notional_per_swap: { low: 1000000000000n, high: 0n }, // 1M USDC
    max_oracle_staleness_seconds: 3600n, // 1 hour
    max_rate_change_per_update_bps: { low: 1000n, high: 0n }, // 10%
    min_rate_bps: { low: 0n, high: 0n }, // 0%
    max_rate_bps: { low: 100000n, high: 0n }, // 1000%
    is_lp_permissioned: false,
  };
}

// Create a market pair
async function createMarket(
  asceswapContract: Contract,
  oracleAddress: string,
  collateralTokenAddress: string,
  curatorAddress: string,
  marketParams?: ReturnType<typeof getDefaultMarketParams>
): Promise<string> {
  const params = marketParams || getDefaultMarketParams();

  console.log(`\nCreating market pair...`);
  console.log(`  Oracle: ${oracleAddress}`);
  console.log(`  Collateral Token: ${collateralTokenAddress}`);
  console.log(`  Curator: ${curatorAddress}`);

  // Call create_market_pair on the contract
  const tx = await asceswapContract.create_market_pair(
    oracleAddress,
    collateralTokenAddress,
    curatorAddress,
    params
  );

  console.log(`Market creation tx hash: ${tx.transaction_hash}`);

  // Wait for transaction
  const receipt = await provider.waitForTransaction(tx.transaction_hash);
  console.log(`Transaction confirmed`);

  // Get the pair_id from the transaction (it's returned by the function)
  // The pair_id is typically the first event or we can query it
  const pairId = "1"; // First market will have ID 1

  console.log(`Market created with pair_id: ${pairId}`);

  return pairId;
}

// Mint tokens to an address (for testing)
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

// Supply LP collateral to a market
async function supplyLpCollateral(
  asceswapContract: Contract,
  erc20Contract: Contract,
  pairId: string,
  amount: bigint
): Promise<void> {
  console.log(`\nSupplying ${amount} LP collateral to market ${pairId}...`);

  // First approve the Asceswap contract to spend tokens
  console.log(`Approving Asceswap to spend tokens...`);
  const approveTx = await erc20Contract.approve(asceswapContract.address, {
    low: amount,
    high: 0n,
  });
  await provider.waitForTransaction(approveTx.transaction_hash);
  console.log(`Approval confirmed`);

  // Then supply collateral
  const supplyTx = await asceswapContract.supply_lp_collateral(pairId, {
    low: amount,
    high: 0n,
  });
  console.log(`Supply tx hash: ${supplyTx.transaction_hash}`);

  await provider.waitForTransaction(supplyTx.transaction_hash);
  console.log(`LP collateral supplied successfully`);
}

// Full deployment for mainnet fork testing
async function deployForMainnetFork(setupMarket = true) {
  console.log("=== Deploying contracts for mainnet fork testing ===\n");

  const admin = owner_account_address;
  const treasury = owner_account_address; // Use deployer as treasury for testing
  const curator = owner_account_address; // Use deployer as curator for testing

  // 1. Deploy AccessRegistry
  console.log("\n--- Step 1: Deploy AccessRegistry ---");
  const accessRegistry = await deployAccessRegistry(admin);

  // 2. Deploy MockOracle (5% rate = 500 bps)
  console.log("\n--- Step 2: Deploy MockOracle ---");
  const initialRateBps = 500n; // 5%
  const initialTimestamp = BigInt(Math.floor(Date.now() / 1000));
  const mockOracle = await deployMockOracle(initialRateBps, initialTimestamp);

  // 3. Deploy MockERC20 (6 decimals like USDC)
  console.log("\n--- Step 3: Deploy MockERC20 ---");
  const mockERC20 = await deployMockERC20(6);

  // 4. Deploy Asceswap
  console.log("\n--- Step 4: Deploy Asceswap ---");
  const asceswap = await deployAsceswap(accessRegistry.address, treasury);

  let pairId: string | undefined;

  if (setupMarket) {
    // 5. Create a market
    console.log("\n--- Step 5: Create Market ---");
    pairId = await createMarket(
      asceswap,
      mockOracle.address,
      mockERC20.address,
      curator
    );

    // 6. Mint tokens and supply LP liquidity
    console.log("\n--- Step 6: Setup LP Liquidity ---");
    const lpAmount = 100000000000n; // 100,000 USDC (6 decimals)
    await mintTokens(mockERC20, admin, lpAmount);
    await supplyLpCollateral(asceswap, mockERC20, pairId, lpAmount);

    // 7. Mint tokens for test users (optional)
    console.log("\n--- Step 7: Mint tokens for testing ---");
    const testUserAmount = 10000000000n; // 10,000 USDC
    await mintTokens(mockERC20, admin, testUserAmount);
  }

  // Summary
  console.log("\n=== Deployment Summary ===");
  console.log(`AccessRegistry: ${accessRegistry.address}`);
  console.log(`MockOracle:     ${mockOracle.address}`);
  console.log(`MockERC20:      ${mockERC20.address}`);
  console.log(`Asceswap:       ${asceswap.address}`);
  if (pairId) {
    console.log(`Market PairId:  ${pairId}`);
  }

  // Save deployment info to file
  const deploymentInfo = {
    network: process.env.SEPOLIA_RPC,
    timestamp: new Date().toISOString(),
    deployer: admin,
    contracts: {
      accessRegistry: accessRegistry.address,
      mockOracle: mockOracle.address,
      mockERC20: mockERC20.address,
      asceswap: asceswap.address,
    },
    market: pairId
      ? {
          pairId,
          oracle: mockOracle.address,
          collateralToken: mockERC20.address,
          curator,
        }
      : undefined,
  };

  const deploymentPath = path.join(__dirname, "deployment.json");
  fs.writeFileSync(deploymentPath, JSON.stringify(deploymentInfo, null, 2));
  console.log(`\nDeployment info saved to: ${deploymentPath}`);

  return {
    accessRegistry,
    mockOracle,
    mockERC20,
    asceswap,
    pairId,
  };
}

// Deploy only MockOracle (for adding to existing setup)
async function deployMockOracleOnly() {
  console.log("=== Deploying MockOracle only ===\n");

  const initialRateBps = 500n; // 5%
  const initialTimestamp = BigInt(Math.floor(Date.now() / 1000));
  const mockOracle = await deployMockOracle(initialRateBps, initialTimestamp);

  console.log("\n=== Deployment Summary ===");
  console.log(`MockOracle: ${mockOracle.address}`);

  return mockOracle;
}

// Create market on existing deployment (using addresses from deployment.json)
async function createMarketOnExistingDeployment() {
  const deploymentPath = path.join(__dirname, "deployment.json");

  if (!fs.existsSync(deploymentPath)) {
    throw new Error(
      `deployment.json not found. Run 'deploy-only' first to deploy contracts.`
    );
  }

  const deployment = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));
  console.log("=== Creating market on existing deployment ===\n");
  console.log(`Asceswap: ${deployment.contracts.asceswap}`);
  console.log(`MockOracle: ${deployment.contracts.mockOracle}`);
  console.log(`MockERC20: ${deployment.contracts.mockERC20}`);

  // Load the Asceswap contract ABI
  const artifacts = loadContractArtifacts("Asceswap", false);
  const asceswap = new Contract({
    abi: artifacts.sierra.abi,
    address: deployment.contracts.asceswap,
    providerOrAccount: myAccount,
  });

  // Load MockERC20 contract
  const mockErc20Artifacts = loadContractArtifacts("MockERC20", false);
  const mockERC20 = new Contract({
    abi: mockErc20Artifacts.sierra.abi,
    address: deployment.contracts.mockERC20,
    providerOrAccount: myAccount,
  });

  // Create market
  const curator = owner_account_address;
  const pairId = await createMarket(
    asceswap,
    deployment.contracts.mockOracle,
    deployment.contracts.mockERC20,
    curator
  );

  // Supply LP liquidity
  console.log("\n--- Setting up LP Liquidity ---");
  const lpAmount = 100000000000n; // 100,000 USDC
  await mintTokens(mockERC20, owner_account_address, lpAmount);
  await supplyLpCollateral(asceswap, mockERC20, pairId, lpAmount);

  // Update deployment.json with market info
  deployment.market = {
    pairId,
    oracle: deployment.contracts.mockOracle,
    collateralToken: deployment.contracts.mockERC20,
    curator,
  };
  fs.writeFileSync(deploymentPath, JSON.stringify(deployment, null, 2));
  console.log(`\nDeployment info updated: ${deploymentPath}`);

  return pairId;
}

async function main() {
  const args = process.argv.slice(2);
  const command = args[0] || "full";

  switch (command) {
    case "full":
      // Deploy all contracts and create market
      await deployForMainnetFork(true);
      break;
    case "deploy-only":
      // Deploy contracts without creating market
      await deployForMainnetFork(false);
      break;
    case "create-market":
      // Create market on existing deployment
      await createMarketOnExistingDeployment();
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
        "  full            - Deploy all contracts + create market + setup LP (default)"
      );
      console.log("  deploy-only     - Deploy contracts only (no market setup)");
      console.log(
        "  create-market   - Create market on existing deployment (uses deployment.json)"
      );
      console.log("  mock-oracle     - Deploy MockOracle only");
      console.log("  access-registry - Deploy AccessRegistry only");
      console.log("  mock-erc20      - Deploy MockERC20 only");
      process.exit(1);
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}