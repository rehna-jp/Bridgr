/**
 * Bridgr Skill Server
 * Exposes blockchain tools as HTTP endpoints
 * Run: node server.js
 */

import express from "express";
import { createWalletClient, http, parseEther, formatUnits, defineChain, encodeFunctionData, decodeFunctionResult } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { celo } from "viem/chains";
import "dotenv/config";

const app = express();
app.use(express.json());

// ── Chain config ──────────────────────────────────────────────────────────────

const IS_MAINNET = process.env.NODE_ENV === "production";
const rpcUrl = IS_MAINNET
  ? process.env.CELO_MAINNET_RPC
  : process.env.CELO_SEPOLIA_RPC;

const celoSepolia = defineChain({
  id: 44787,
  name: "Celo Sepolia",
  nativeCurrency: { name: "CELO", symbol: "CELO", decimals: 18 },
  rpcUrls: { default: { http: [rpcUrl] } },
});

const chain = IS_MAINNET ? celo : celoSepolia;

const account = privateKeyToAccount(process.env.AGENT_PRIVATE_KEY);
const walletClient = createWalletClient({
  account,
  chain,
  transport: http(rpcUrl),
});

const ROUTER_ADDRESS = process.env.ROUTER_ADDRESS;
const CUSD_ADDRESS = IS_MAINNET ? process.env.CUSD_MAINNET : process.env.CUSD_TESTNET;

const CORRIDOR_CURRENCIES = { 0: "NGN", 1: "KES", 2: "GHS" };
const COMPETITOR_FEES = {
  westernUnion: parseFloat(process.env.WESTERN_UNION_FEE_USD || "7.99"),
  wise: parseFloat(process.env.WISE_FEE_USD || "2.50"),
  bridgrFeeBps: parseInt(process.env.OYA_SEND_FEE_BPS || "50"),
};

// ── ABI ───────────────────────────────────────────────────────────────────────

const ROUTER_ABI = [
  {
    name: "getQuote",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "corridorId", type: "uint256" },
      { name: "usdAmount", type: "uint256" },
    ],
    outputs: [
      { name: "localAmount", type: "uint256" },
      { name: "fee", type: "uint256" },
      { name: "exchangeRate", type: "uint256" },
    ],
  },
  {
    name: "sendRemittance",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "sender", type: "address" },
      { name: "recipient", type: "address" },
      { name: "corridorId", type: "uint256" },
      { name: "usdAmount", type: "uint256" },
      { name: "minLocalOut", type: "uint256" },
      { name: "memo", type: "string" },
    ],
    outputs: [{ name: "localReceived", type: "uint256" }],
  },
];

const ERC20_ABI = [
  {
    name: "approve",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
];

// ── Raw eth_call helper (bypasses viem gas simulation) ────────────────────────

async function ethCall(to, data) {
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "eth_call",
      params: [{ to, data }, "latest"],
      id: 1,
    }),
  });
  const json = await response.json();
  if (json.error) throw new Error(json.error.message);
  return json.result;
}

// ── Routes ────────────────────────────────────────────────────────────────────

app.get("/health", (req, res) => {
  res.json({ status: "ok", agent: account.address, chain: chain.name, router: ROUTER_ADDRESS });
});

app.get("/quote", async (req, res) => {
  try {
    const corridorId = parseInt(req.query.corridorId);
    const usdAmount = parseFloat(req.query.usdAmount);

    if (isNaN(corridorId) || isNaN(usdAmount) || usdAmount <= 0) {
      return res.status(400).json({ error: "Invalid corridorId or usdAmount" });
    }

    const usdWei = parseEther(usdAmount.toString());

    // Use raw eth_call to avoid viem gas simulation issues
    const calldata = encodeFunctionData({
      abi: ROUTER_ABI,
      functionName: "getQuote",
      args: [BigInt(corridorId), usdWei],
    });

    const result = await ethCall(ROUTER_ADDRESS, calldata);

    const [localAmount, fee, exchangeRate] = decodeFunctionResult({
      abi: ROUTER_ABI,
      functionName: "getQuote",
      data: result,
    });

    const currency = CORRIDOR_CURRENCIES[corridorId] || "UNKNOWN";
    const bridgrFee = (usdAmount * COMPETITOR_FEES.bridgrFeeBps) / 10_000;

    res.json({
      success: true,
      corridorId,
      currency,
      usdAmount,
      localAmountFormatted: Number(formatUnits(localAmount, 18)).toLocaleString("en-US", { maximumFractionDigits: 0 }),
      fee: Number(formatUnits(fee, 18)).toFixed(4),
      exchangeRate: Number(formatUnits(exchangeRate, 18)).toFixed(2),
      bridgrFee: bridgrFee.toFixed(2),
      westernUnionFee: COMPETITOR_FEES.westernUnion.toFixed(2),
      wiseFee: COMPETITOR_FEES.wise.toFixed(2),
      savingsVsWU: (COMPETITOR_FEES.westernUnion - bridgrFee).toFixed(2),
      savingsVsWise: (COMPETITOR_FEES.wise - bridgrFee).toFixed(2),
    });
  } catch (err) {
    console.error("Quote error:", err.message);
    res.status(500).json({ error: err.message });
  }
});

app.post("/send", async (req, res) => {
  try {
    const { senderAddress, recipientAddress, corridorId, usdAmount, slippagePct = 1, memo } = req.body;

    if (!senderAddress || !recipientAddress || corridorId === undefined || !usdAmount) {
      return res.status(400).json({ error: "Missing required fields" });
    }

    const usdWei = parseEther(usdAmount.toString());

    // Get quote via raw call
    const calldata = encodeFunctionData({
      abi: ROUTER_ABI,
      functionName: "getQuote",
      args: [BigInt(corridorId), usdWei],
    });
    const result = await ethCall(ROUTER_ADDRESS, calldata);
    const [localAmount] = decodeFunctionResult({
      abi: ROUTER_ABI,
      functionName: "getQuote",
      data: result,
    });

    const minLocalOut = (localAmount * BigInt(100 - slippagePct)) / BigInt(100);

    // Approve cUSD
    const approveTx = await walletClient.writeContract({
      address: CUSD_ADDRESS,
      abi: ERC20_ABI,
      functionName: "approve",
      args: [ROUTER_ADDRESS, usdWei],
    });
    console.log("Approve tx:", approveTx);

    // Send remittance
    const sendTx = await walletClient.writeContract({
      address: ROUTER_ADDRESS,
      abi: ROUTER_ABI,
      functionName: "sendRemittance",
      args: [senderAddress, recipientAddress, BigInt(corridorId), usdWei, minLocalOut, memo || "Sent via Bridgr"],
    });

    const currency = CORRIDOR_CURRENCIES[corridorId] || "UNKNOWN";

    res.json({
      success: true,
      txHash: sendTx,
      txUrl: `https://celoscan.io/tx/${sendTx}`,
      currency,
      localReceived: Number(formatUnits(minLocalOut, 18)).toFixed(0),
      timestamp: new Date().toISOString(),
    });
  } catch (err) {
    console.error("Send error:", err.message);
    res.status(500).json({ error: err.message });
  }
});

app.get("/history", async (req, res) => {
  try {
    const { senderAddress, limit = 10 } = req.query;
    if (!senderAddress) return res.status(400).json({ error: "Missing senderAddress" });
    res.json({ success: true, count: 0, history: [], note: "History requires event indexing - coming soon" });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

const PORT = process.env.SKILL_SERVER_PORT || 3001;
app.listen(PORT, () => {
  console.log(`Bridgr skill server running on http://localhost:${PORT}`);
  console.log(`Agent wallet: ${account.address}`);
  console.log(`Chain: ${chain.name} (${chain.id})`);
  console.log(`Router: ${ROUTER_ADDRESS}`);
});