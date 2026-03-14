/**
 * Bridgr -- OpenClaw Skill
 * Registers blockchain tools that the Claude/Groq agent can call
 *
 * File location: agent/skills/bridgr-skill.js
 *
 * Install:
 *   cd agent/skills && npm install
 *   openclaw skills add ./bridgr-skill.js --name bridgr
 *
 * Required .env vars:
 *   ROUTER_ADDRESS, AGENT_PRIVATE_KEY
 *   CELO_SEPOLIA_RPC (or CELO_MAINNET_RPC for production)
 *   CUSD_TESTNET (or CUSD_MAINNET)
 *   TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_WHATSAPP_FROM
 */

import { createWalletClient, createPublicClient, http, parseEther, formatUnits } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { celoAlfajores, celo } from "viem/chains";
import twilio from "twilio";
import "dotenv/config";

// -- Chain config --------------------------------------------------------------

const IS_MAINNET = process.env.NODE_ENV === "production";
const chain = IS_MAINNET ? celo : celoAlfajores;
const rpcUrl = IS_MAINNET
  ? process.env.CELO_MAINNET_RPC
  : process.env.CELO_SEPOLIA_RPC;

// -- Viem clients --------------------------------------------------------------

const account = privateKeyToAccount(process.env.AGENT_PRIVATE_KEY);

const walletClient = createWalletClient({
  account,
  chain,
  transport: http(rpcUrl),
});

const publicClient = createPublicClient({
  chain,
  transport: http(rpcUrl),
});

// -- Contract ABI (minimal -- only what the agent needs) -----------------------

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
  {
    name: "getCorridor",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "corridorId", type: "uint256" }],
    outputs: [
      { name: "tokenOut", type: "address" },
      { name: "label", type: "string" },
      { name: "currency", type: "string" },
      { name: "active", type: "bool" },
    ],
  },
  {
    name: "RemittanceSent",
    type: "event",
    inputs: [
      { name: "sender", type: "address", indexed: true },
      { name: "recipient", type: "address", indexed: true },
      { name: "corridorId", type: "uint256", indexed: true },
      { name: "usdAmount", type: "uint256" },
      { name: "localAmount", type: "uint256" },
      { name: "fee", type: "uint256" },
      { name: "memo", type: "string" },
    ],
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

const ROUTER_ADDRESS = process.env.ROUTER_ADDRESS;
const CUSD_ADDRESS = IS_MAINNET
  ? process.env.CUSD_MAINNET
  : process.env.CUSD_TESTNET;

// -- Fee comparison data -------------------------------------------------------

const COMPETITOR_FEES = {
  westernUnion: parseFloat(process.env.WESTERN_UNION_FEE_USD || "7.99"),
  wise: parseFloat(process.env.WISE_FEE_USD || "2.50"),
  bridgrFeeBps: parseInt(process.env.OYA_SEND_FEE_BPS || "50"),
};

// -- Tool: getQuote ------------------------------------------------------------

export async function getQuote({ corridorId, usdAmount }) {
  const usdWei = parseEther(usdAmount.toString());

  const [localAmount, fee, exchangeRate] = await publicClient.readContract({
    address: ROUTER_ADDRESS,
    abi: ROUTER_ABI,
    functionName: "getQuote",
    args: [BigInt(corridorId), usdWei],
  });

  const [, , currency] = await publicClient.readContract({
    address: ROUTER_ADDRESS,
    abi: ROUTER_ABI,
    functionName: "getCorridor",
    args: [BigInt(corridorId)],
  });

  const bridgrFee = (usdAmount * COMPETITOR_FEES.bridgrFeeBps) / 10_000;

  return {
    localAmount: localAmount.toString(),
    localAmountFormatted: Number(formatUnits(localAmount, 18)).toLocaleString("en-US", {
      maximumFractionDigits: 0,
    }),
    currency,
    fee: fee.toString(),
    feeFormatted: Number(formatUnits(fee, 18)).toFixed(2),
    exchangeRate: Number(formatUnits(exchangeRate, 18)).toFixed(2),
    bridgrFee: bridgrFee.toFixed(2),
    westernUnionFee: COMPETITOR_FEES.westernUnion.toFixed(2),
    wiseFee: COMPETITOR_FEES.wise.toFixed(2),
    savings_vs_wu: (COMPETITOR_FEES.westernUnion - bridgrFee).toFixed(2),
    savings_vs_wise: (COMPETITOR_FEES.wise - bridgrFee).toFixed(2),
  };
}

// -- Tool: sendRemittance ------------------------------------------------------

export async function sendRemittance({
  senderAddress,
  recipientAddress,
  corridorId,
  usdAmount,
  slippagePct = 1,
  memo,
}) {
  const usdWei = parseEther(usdAmount.toString());

  // 1. Get quote to calculate minLocalOut with slippage
  const [localAmount] = await publicClient.readContract({
    address: ROUTER_ADDRESS,
    abi: ROUTER_ABI,
    functionName: "getQuote",
    args: [BigInt(corridorId), usdWei],
  });

  const minLocalOut = (localAmount * BigInt(100 - slippagePct)) / BigInt(100);

  // 2. Approve cUSD spend
  const approveTx = await walletClient.writeContract({
    address: CUSD_ADDRESS,
    abi: ERC20_ABI,
    functionName: "approve",
    args: [ROUTER_ADDRESS, usdWei],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveTx });

  // 3. Execute remittance
  const sendTx = await walletClient.writeContract({
    address: ROUTER_ADDRESS,
    abi: ROUTER_ABI,
    functionName: "sendRemittance",
    args: [
      senderAddress,
      recipientAddress,
      BigInt(corridorId),
      usdWei,
      minLocalOut,
      memo,
    ],
  });

  const receipt = await publicClient.waitForTransactionReceipt({ hash: sendTx });

  return {
    success: true,
    txHash: sendTx,
    txUrl: `https://celoscan.io/tx/${sendTx}`,
    localReceived: formatUnits(minLocalOut, 18),
    gasUsed: formatUnits(receipt.gasUsed * receipt.effectiveGasPrice, 18),
    timestamp: new Date().toISOString(),
  };
}

// -- Tool: getTransactionHistory -----------------------------------------------

export async function getTransactionHistory({ senderAddress, limit = 10 }) {
  const logs = await publicClient.getLogs({
    address: ROUTER_ADDRESS,
    event: ROUTER_ABI.find((x) => x.name === "RemittanceSent"),
    args: { sender: senderAddress },
    fromBlock: "earliest",
    toBlock: "latest",
  });

  return logs
    .slice(-limit)
    .reverse()
    .map((log) => ({
      txHash: log.transactionHash,
      txUrl: `https://celoscan.io/tx/${log.transactionHash}`,
      usdAmount: Number(formatUnits(log.args.usdAmount, 18)).toFixed(2),
      localAmount: Number(formatUnits(log.args.localAmount, 18)).toLocaleString(),
      corridorId: log.args.corridorId.toString(),
      recipient: log.args.recipient,
      memo: log.args.memo,
    }));
}

// -- Tool: notifyRecipient -----------------------------------------------------

export async function notifyRecipient({
  recipientPhone,
  senderName,
  amount,
  currency,
  txHash,
}) {
  const client = twilio(
    process.env.TWILIO_ACCOUNT_SID,
    process.env.TWILIO_AUTH_TOKEN
  );

  const currencySymbols = { NGN: "NGN", KES: "KSh", GHS: "GHS" };
  const symbol = currencySymbols[currency] || currency;

  const message = await client.messages.create({
    from: process.env.TWILIO_WHATSAPP_FROM,
    to: `whatsapp:${recipientPhone}`,
    body:
      `Bridgr -- Money Received!\n\n` +
      `${senderName} just sent you ${symbol} ${amount}.\n` +
      `Your funds are live on Celo.\n\n` +
      `Tx: celoscan.io/tx/${txHash.slice(0, 20)}...`,
  });

  return { success: true, messageSid: message.sid };
}

// -- Tool: scheduleRecurring ---------------------------------------------------

export async function scheduleRecurring({
  frequency,
  dayOfMonth = 1,
  usdAmount,
  corridorId,
  recipientAddress,
  recipientName,
  memo,
}) {
  const cronMap = {
    daily: "0 9 * * *",
    weekly: "0 9 * * 1",
    monthly: `0 9 ${dayOfMonth} * *`,
  };

  return {
    type: "schedule",
    cron: cronMap[frequency] || cronMap.monthly,
    task: "sendRemittance",
    params: {
      corridorId,
      usdAmount,
      recipientAddress,
      recipientName,
      memo: memo || `Recurring ${frequency} transfer to ${recipientName} via Bridgr`,
    },
    description: `Send $${usdAmount} to ${recipientName} ${frequency} via Bridgr`,
  };
}