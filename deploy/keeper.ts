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
const STATE_PATH = path.join(__dirname, "keeper_state.json");

// =====================================================================
// Rate Simulation Config (Mean-Reverting / Ornstein-Uhlenbeck)
//
// Model: new_rate = rate + theta * (mean - rate) + sigma * N(0,1)
//
//   theta  = mean-reversion speed (0.0-1.0). Higher = snaps back faster.
//   sigma  = volatility in BPS per update. Controls noise amplitude.
//   mean   = base rate the market reverts toward.
//   min/max = hard clamp bounds (from market params).
// =====================================================================

interface MarketSimConfig {
  pairId: number;
  name: string;
  meanBps: number;       // Base rate to revert toward
  theta: number;         // Mean-reversion speed (0.0 - 1.0)
  sigmaBps: number;      // Volatility per step (in BPS)
  minBps: number;        // Hard floor
  maxBps: number;        // Hard ceiling
}

const MARKET_CONFIGS: MarketSimConfig[] = [
  {
    // BTC Funding Rate — volatile, swings around 10%
    pairId: 1,
    name: "BTC Funding Rate",
    meanBps: 1000,
    theta: 0.05,          // Slow reversion — lets trends develop
    sigmaBps: 80,         // ~0.8% per hour volatility
    minBps: 0,
    maxBps: 200000,       // from market params: max_rate_bps
  },
  {
    // STRK Staking Yield — moderate moves around 8%
    pairId: 2,
    name: "STRK Staking Yield",
    meanBps: 800,
    theta: 0.08,
    sigmaBps: 40,         // ~0.4% per hour
    minBps: 0,
    maxBps: 100000,
  },
  {
    // Troves xWBTC Supply Rate — fairly stable around 3%
    pairId: 3,
    name: "Troves xWBTC Supply Rate",
    meanBps: 300,
    theta: 0.10,
    sigmaBps: 20,         // ~0.2% per hour
    minBps: 0,
    maxBps: 50000,
  },
  {
    // US SOFR Rate — very stable around 4.3%
    pairId: 4,
    name: "US SOFR Rate",
    meanBps: 430,
    theta: 0.15,          // Strong reversion — stays near mean
    sigmaBps: 5,          // ~0.05% per hour — barely moves
    minBps: 0,
    maxBps: 50000,
  },
  {
    // Ekubo STRK/USDC Pool Rate — volatile DEX yield
    pairId: 5,
    name: "Ekubo STRK/USDC Pool Rate",
    meanBps: 1200,
    theta: 0.06,
    sigmaBps: 90,         // ~0.9% per hour — most volatile
    minBps: 0,
    maxBps: 150000,
  },
  {
    // US Real Estate Cap Rate — glacially slow
    pairId: 6,
    name: "US Real Estate Cap Rate",
    meanBps: 550,
    theta: 0.20,          // Strong reversion
    sigmaBps: 3,          // ~0.03% per hour — barely moves
    minBps: 100,
    maxBps: 30000,
  },
];

// =====================================================================
// Math helpers
// =====================================================================

// Box-Muller transform: generate standard normal random variable
function randomNormal(): number {
  let u1 = 0, u2 = 0;
  while (u1 === 0) u1 = Math.random();
  while (u2 === 0) u2 = Math.random();
  return Math.sqrt(-2.0 * Math.log(u1)) * Math.cos(2.0 * Math.PI * u2);
}

// Ornstein-Uhlenbeck step
function simulateNextRate(currentBps: number, config: MarketSimConfig): number {
  const drift = config.theta * (config.meanBps - currentBps);
  const noise = config.sigmaBps * randomNormal();
  const newRate = currentBps + drift + noise;

  // Clamp to bounds
  return Math.max(config.minBps, Math.min(config.maxBps, Math.round(newRate)));
}

// =====================================================================
// Contract helpers
// =====================================================================

function loadOracleArtifacts(): any {
  const files = fs.readdirSync(DEV_DIR);
  const sierraFile = files.find(
    (f) => f.endsWith(".contract_class.json") && f.includes("MockRateOracle") && !f.includes(".test.")
  );
  if (!sierraFile) throw new Error("Missing MockRateOracle Sierra file");
  return json.parse(fs.readFileSync(path.join(DEV_DIR, sierraFile), "utf8"));
}

function getOracleContract(address: string, abi: any): Contract {
  return new Contract({ abi: abi.abi, address, providerOrAccount: myAccount });
}

interface Deployment {
  markets: Array<{
    pairId: number;
    oracleName: string;
    oracleAddress: string;
    initialRateBps: number;
  }>;
}

function loadDeployment(): Deployment {
  return JSON.parse(fs.readFileSync(DEPLOYMENT_PATH, "utf8"));
}

// =====================================================================
// Keeper state (persists last known rate per market between runs)
// =====================================================================

interface KeeperState {
  lastUpdate: string;
  rates: Record<number, number>;  // pairId -> last rate in BPS
}

function loadState(): KeeperState {
  if (fs.existsSync(STATE_PATH)) {
    return JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));
  }
  return { lastUpdate: "", rates: {} };
}

function saveState(state: KeeperState): void {
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));
}

// =====================================================================
// Main keeper logic
// =====================================================================

async function updateRates(): Promise<void> {
  const deployment = loadDeployment();
  const oracleAbi = loadOracleArtifacts();
  const state = loadState();
  const now = Math.floor(Date.now() / 1000);

  console.log(`\n[${new Date().toISOString()}] Keeper update starting...`);
  console.log(`──────────────────────────────────────────────────`);

  for (const config of MARKET_CONFIGS) {
    const market = deployment.markets.find((m) => m.pairId === config.pairId);
    if (!market) {
      console.log(`  [${config.pairId}] ${config.name}: SKIPPED (not in deployment)`);
      continue;
    }

    // Get current rate (from state, or read from chain)
    let currentRate: number;
    if (state.rates[config.pairId] !== undefined) {
      currentRate = state.rates[config.pairId];
    } else {
      // First run — read from chain
      const oracle = getOracleContract(market.oracleAddress, oracleAbi);
      const [rateBps] = await oracle.get_rate();
      currentRate = Number(rateBps);
    }

    // Simulate next rate
    const newRate = simulateNextRate(currentRate, config);
    const delta = newRate - currentRate;
    const deltaSign = delta >= 0 ? "+" : "";
    const deltaPercent = currentRate > 0 ? ((delta / currentRate) * 100).toFixed(2) : "0.00";

    console.log(
      `  [${config.pairId}] ${config.name.padEnd(28)} ` +
      `${currentRate} → ${newRate} bps  (${deltaSign}${delta} bps, ${deltaSign}${deltaPercent}%)`
    );

    // Call set_rate on oracle
    const oracle = getOracleContract(market.oracleAddress, oracleAbi);
    try {
      const tx = await oracle
        .withOptions({ tip: 0n })
        .set_rate(
          { low: BigInt(newRate), high: 0n },
          BigInt(now),
        );
      await provider.waitForTransaction(tx.transaction_hash);
      console.log(`         tx: ${tx.transaction_hash}`);

      // Update state
      state.rates[config.pairId] = newRate;
    } catch (err: any) {
      console.error(`         ERROR: ${err.message || err}`);
    }
  }

  state.lastUpdate = new Date().toISOString();
  saveState(state);

  console.log(`──────────────────────────────────────────────────`);
  console.log(`  Done. State saved to ${STATE_PATH}\n`);
}

// Seed history with initial data points (useful for first run)
async function seedHistory(count: number): Promise<void> {
  const deployment = loadDeployment();
  const oracleAbi = loadOracleArtifacts();

  console.log(`\n=== Seeding ${count} history entries per oracle ===\n`);
  console.log(`This simulates ${count} hours of past rate updates.\n`);

  for (const config of MARKET_CONFIGS) {
    const market = deployment.markets.find((m) => m.pairId === config.pairId);
    if (!market) continue;

    const oracle = getOracleContract(market.oracleAddress, oracleAbi);
    const now = Math.floor(Date.now() / 1000);

    // Start from initial rate and simulate forward
    let rate = config.meanBps;
    const rates: Array<{ rate: number; timestamp: number }> = [];

    // Generate the full path first
    for (let i = 0; i < count; i++) {
      rate = simulateNextRate(rate, config);
      // Timestamps go from (now - count*3600) to (now - 3600), spaced 1 hour apart
      const timestamp = now - (count - i) * 3600;
      rates.push({ rate, timestamp });
    }

    console.log(`  [${config.pairId}] ${config.name}`);
    console.log(`         ${count} entries: ${rates[0].rate} bps → ${rates[rates.length - 1].rate} bps`);
    console.log(`         Time span: ${new Date(rates[0].timestamp * 1000).toISOString()} → ${new Date(rates[rates.length - 1].timestamp * 1000).toISOString()}`);

    // Send each set_rate call (each one pushes previous to history buffer)
    for (let i = 0; i < rates.length; i++) {
      const { rate: r, timestamp: ts } = rates[i];
      try {
        const tx = await oracle
          .withOptions({ tip: 0n })
          .set_rate(
            { low: BigInt(r), high: 0n },
            BigInt(ts),
          );
        await provider.waitForTransaction(tx.transaction_hash);

        // Progress indicator
        if ((i + 1) % 10 === 0 || i === rates.length - 1) {
          process.stdout.write(`         ${i + 1}/${rates.length} updates sent\r`);
        }
      } catch (err: any) {
        console.error(`\n         ERROR at entry ${i}: ${err.message || err}`);
      }
    }
    console.log(`         ${rates.length}/${rates.length} updates sent ✓`);

    // Save final rate to state
    const state = loadState();
    state.rates[config.pairId] = rates[rates.length - 1].rate;
    state.lastUpdate = new Date().toISOString();
    saveState(state);
  }

  console.log(`\n=== Seeding complete ===\n`);
}

// Preview simulated rates without sending transactions
function previewRates(steps: number): void {
  console.log(`\n=== Rate Simulation Preview (${steps} steps) ===\n`);

  for (const config of MARKET_CONFIGS) {
    let rate = config.meanBps;
    const series: number[] = [rate];
    let min = rate, max = rate;

    for (let i = 0; i < steps; i++) {
      rate = simulateNextRate(rate, config);
      series.push(rate);
      min = Math.min(min, rate);
      max = Math.max(max, rate);
    }

    const final = series[series.length - 1];
    const change = final - series[0];
    const sign = change >= 0 ? "+" : "";

    console.log(`  [${config.pairId}] ${config.name}`);
    console.log(`         Start: ${series[0]} bps → End: ${final} bps (${sign}${change} bps)`);
    console.log(`         Range: ${min} – ${max} bps`);
    console.log(`         θ=${config.theta}  σ=${config.sigmaBps}  μ=${config.meanBps}`);

    // ASCII sparkline (50 chars wide)
    const width = 50;
    const range = max - min || 1;
    const sparkline = series
      .filter((_, i) => i % Math.max(1, Math.floor(series.length / width)) === 0)
      .map((v) => {
        const pos = Math.round(((v - min) / range) * 7);
        return ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"][pos];
      })
      .join("");
    console.log(`         ${sparkline}\n`);
  }
}

// =====================================================================
// Loop mode — run every hour
// =====================================================================

async function loop(intervalMs: number): Promise<void> {
  console.log(`\n=== Keeper loop started (interval: ${intervalMs / 1000}s) ===`);
  console.log(`Press Ctrl+C to stop.\n`);

  // Run immediately, then on interval
  await updateRates();

  setInterval(async () => {
    try {
      await updateRates();
    } catch (err: any) {
      console.error(`[${new Date().toISOString()}] Loop error: ${err.message || err}`);
    }
  }, intervalMs);
}

// =====================================================================
// CLI
// =====================================================================

async function main() {
  const command = process.argv[2] || "update";

  switch (command) {
    case "update":
      await updateRates();
      break;

    case "loop": {
      const intervalHours = parseFloat(process.argv[3] || "1");
      await loop(intervalHours * 3600 * 1000);
      break;
    }

    case "seed": {
      const count = parseInt(process.argv[3] || "48", 10);
      await seedHistory(count);
      break;
    }

    case "preview": {
      const steps = parseInt(process.argv[3] || "168", 10);
      previewRates(steps);
      break;
    }

    default:
      console.log("Usage: npx ts-node keeper.ts [command]\n");
      console.log("Commands:");
      console.log("  update              Single rate update for all oracles (default)");
      console.log("  loop [hours]        Continuous updates every N hours (default: 1)");
      console.log("  seed [count]        Seed N historical entries per oracle (default: 48)");
      console.log("  preview [steps]     Preview simulated rates without sending transactions");
      process.exit(1);
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
