# Bridgr -- TOOLS.md (Blockchain Tools via HTTP)

The Bridgr skill server runs locally at http://localhost:3001
Call these endpoints to get live blockchain data and execute transfers.

IMPORTANT: Always call GET /quote before any transfer.
IMPORTANT: Never call POST /send without explicit user confirmation ("yes", "send it", "confirm").

---

## GET /quote

Get a live exchange rate quote from the RemittanceRouter contract.

When to use: Before every transfer, and when user asks "how much will they get?"

Query params:
- corridorId: 0=NGN, 1=KES, 2=GHS
- usdAmount: numeric dollar amount (e.g. 30)

Example: GET http://localhost:3001/quote?corridorId=0&usdAmount=30

Response:
{
  "success": true,
  "currency": "NGN",
  "usdAmount": 30,
  "localAmountFormatted": "46,185",
  "exchangeRate": "1540.50",
  "bridgrFee": "0.15",
  "westernUnionFee": "7.99",
  "wiseFee": "2.50",
  "savingsVsWU": "7.84",
  "savingsVsWise": "2.35"
}

Format the response for the user like this:
Bridgr Quote
-----------------
Sending:        $30.00 USD
Recipient gets: NGN 46,185 (approx)
Exchange rate:  NGN 1,540 per $1
Bridgr fee:     $0.15 (0.5%)

vs Western Union: you save $7.84
vs Wise:          you save $2.35

Reply YES to confirm, or NO to cancel.

---

## POST /send

Execute a transfer on-chain. ONLY call after user says YES.

Body:
{
  "senderAddress": "0x...",
  "recipientAddress": "0x...",
  "corridorId": 0,
  "usdAmount": 30,
  "slippagePct": 1,
  "memo": "Sent via Bridgr"
}

Response:
{
  "success": true,
  "txHash": "0x...",
  "txUrl": "https://celoscan.io/tx/0x...",
  "currency": "NGN",
  "localReceived": "46185",
  "timestamp": "2026-03-14T..."
}

After success, tell the user:
Transfer Complete!
---------------------
Sent:      $30.00 USD
Received:  NGN 46,185
Tx:        celoscan.io/tx/0x...
Time:      2.3 seconds

Bridgr delivered. Money moves.

---

## GET /history

Fetch past transfers for a wallet address.

Query params:
- senderAddress: 0x... wallet address
- limit: number of results (default 10)

Example: GET http://localhost:3001/history?senderAddress=0x...&limit=5

---

## GET /health

Check if the skill server is running.
Example: GET http://localhost:3001/health

---

## Corridor Reference
- 0 = USD -> NGN (Nigeria)
- 1 = USD -> KES (Kenya)
- 2 = USD -> GHS (Ghana)

## Notes
- If skill server is not running, tell user: "The Bridgr service is starting up, please try again."
- Always show formatted amounts, never raw wei values
- Always include the celoscan link after a successful transfer