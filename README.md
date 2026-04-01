# ClankerPaste

Uncensorable pastebin running entirely on the Internet Computer. No accounts. No censorship. No takedowns.

Pay in Sepolia ETH to store content on-chain. Pastes under 1KB are free. Content is served directly via HTTP from the canister — no server, no hosting provider, no single point of failure.

**Live:** https://7agvh-biaaa-aaaas-qgfqa-cai.icp0.io/

## Why

Every pastebin can be censored. Pastebin.com, GitHub Gists, Hastebin — they all have a company behind them that can be pressured to remove content. Domain registrars can seize domains. Hosting providers can pull the plug.

ClankerPaste can't be taken down because:

- **The code runs on-chain** — No server to seize, no hosting account to suspend
- **The frontend is on-chain** — Served from an ICP asset canister, not Vercel or Cloudflare
- **The deployer is pseudonymous** — Deployed from a burner identity with no traceable connection
- **Payment is cross-chain** — Pay in ETH on Sepolia testnet, verified on-chain via ICP's EVM RPC canister. No payment processor to freeze.

## How It Works

```
User uploads content → Canister stores it on-chain
                         ↓
User pays in Sepolia ETH → Transaction verified via EVM RPC canister
                         ↓
Paste goes live → Served via HTTP at /{paste-id}
                         ↓
Anyone can access → Direct URL, no login required
```

### Payment Verification Flow

ClankerPaste doesn't use HTTPS outcalls or external APIs. Payment verification is fully inter-canister:

1. User creates a paste, gets a payment address + unique amount
2. User sends Sepolia ETH to the address using any wallet
3. User submits the transaction hash
4. The ClankerPaste canister calls the **EVM RPC canister** (`7hfb6-caaaa-aaaar-qadga-cai`) — an ICP system service that proxies JSON-RPC calls to Ethereum
5. The EVM RPC canister fetches the transaction receipt from Sepolia, verifies `status: 0x1` and correct recipient
6. Paste is marked as confirmed and goes live

No oracles. No bridges. Just one canister asking another canister to check Ethereum.

## Architecture

| Component | Technology | Canister ID |
|-----------|-----------|-------------|
| **Backend** | Motoko persistent actor | `245pc-kaaaa-aaaas-qgfpq-cai` |
| **Frontend** | React + Vite + Tailwind | `7agvh-biaaa-aaaas-qgfqa-cai` |
| **Payment verification** | EVM RPC canister (Sepolia) | `7hfb6-caaaa-aaaar-qadga-cai` |

### Backend Features

- **HTTP interface** — Pastes served directly via `http_request` at `/p/{id}`
- **Chunked uploads** — Files up to 100MB via chunked upload API (~1.9MB per chunk)
- **Payment gating** — Returns HTTP 402 for unpaid pastes
- **Expiry + GC** — Pastes expire based on payment duration, garbage collected
- **Free tier** — Pastes under 1KB stored for free
- **EVM RPC verification** — Verifies Sepolia ETH transactions on-chain

### Frontend Features

- **Text + file uploads** — Paste text or upload images/files
- **Payment flow** — Shows payment address, amount, and tx hash input
- **Paste viewer** — View pastes by ID with image rendering support
- **Dark theme** — Because obviously

## ICP Skills Used

Built as part of the [ICP Skills Community Testing](https://skills.internetcomputer.org/) program (Day 2 — Skills-Guided Build). Composing 6 ICP capabilities:

1. **`icp-cli`** — Project scaffolding, build, deploy
2. **`motoko`** — Persistent actor, mo:core collections
3. **`canister-security`** — Anonymous principal rejection, owner-only methods
4. **`stable-memory`** — Persistent actor pattern for upgrade-safe storage
5. **`evm-rpc`** — Inter-canister call to verify Sepolia ETH transactions
6. **`asset-canister`** — Frontend hosting via recipe

## Original Inspiration

We started with the question: *"What's a product that genuinely benefits from decentralization?"*

Riffed through ideas — civic issue trackers, review platforms, stablecoins, VPN resellers, AI API proxies — before landing on the thing that felt most honest: **an uncensorable pastebin that accepts crypto payments and can't be traced back to its operator.**

The key insight: the canister IS the server AND the payment processor. No external dependencies. No identity leaks. Deploy from a burner identity, fund with untraceable cycles, and walk away. The code runs itself.

## Development

```bash
# Install dependencies
npm install -g @icp-sdk/icp-cli @icp-sdk/ic-wasm

# Start local network
icp network start -d

# Deploy locally
icp deploy

# Deploy to mainnet
icp deploy -e ic
```

### Send a test payment (Sepolia)

```bash
# Install Foundry for the `cast` CLI
brew install foundry

# Send Sepolia ETH (replace amount and address from paste creation)
cast send 0x2DA4E8752DB47048476aF400011BA9b307e23e39 \
  --value <AMOUNT>wei \
  --private-key <YOUR_SEPOLIA_PRIVATE_KEY> \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```

## Direct Paste Access

Pastes are served as raw HTTP responses:

```
https://245pc-kaaaa-aaaas-qgfpq-cai.raw.icp0.io/p/{paste-id}
```

- **200** — Paste content with correct `Content-Type`
- **402** — Payment required (paste exists but isn't paid for)
- **404** — Paste not found
- **410** — Paste expired

## License

Do whatever you want with this.
