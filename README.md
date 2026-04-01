# ClankerPaste

Uncensorable pastebin on the Internet Computer. Pay in ETH, content lives on-chain, served via HTTP.

Inspired by [x402](https://github.com/coinbase/x402) — the idea that any HTTP endpoint should be able to charge for access. ClankerPaste is a native ICP implementation: the canister IS the server, the payment processor, and the storage layer. No Coinbase, no USDC, no middleman. Just ETH in, content out.

**Live:** https://7agvh-biaaa-aaaas-qgfqa-cai.icp0.io/

## How It Works

1. Upload text or an image
2. Pastes under 1KB are free. Larger pastes show a payment address + amount
3. Send ETH on Sepolia testnet to the address
4. Submit your tx hash — the canister verifies it on-chain via the EVM RPC canister
5. Paste goes live at a permanent HTTP URL

```
https://245pc-kaaaa-aaaas-qgfpq-cai.raw.icp0.io/p/{paste-id}
```

Unpaid pastes return **HTTP 402 Payment Required**. Paid pastes return 200 with the content.

## Payment Verification

No oracles. No bridges. No HTTPS outcalls. Fully inter-canister:

```
ClankerPaste canister → EVM RPC canister → Ethereum Sepolia
```

The [EVM RPC canister](https://internetcomputer.org/docs/references/evm-rpc-canister) is an ICP system service that proxies JSON-RPC calls to Ethereum. ClankerPaste calls it to fetch the transaction receipt, checks `status: 0x1` and correct recipient, and confirms the paste.

## Architecture

| Layer | Tech |
|-------|------|
| Backend | Motoko persistent actor (`245pc-kaaaa-aaaas-qgfpq-cai`) |
| Frontend | React + Vite + Tailwind (`7agvh-biaaa-aaaas-qgfqa-cai`) |
| Payment verification | EVM RPC canister, Sepolia testnet |
| Storage | On-chain, chunked uploads up to 100MB |
| HTTP serving | Native `http_request` — no proxy, no CDN |

## Quick Start

```bash
npm install -g @icp-sdk/icp-cli @icp-sdk/ic-wasm
icp network start -d
icp deploy
```

### Pay for a paste

```bash
brew install foundry

cast send <PAYMENT_ADDRESS> \
  --value <AMOUNT>wei \
  --private-key <YOUR_KEY> \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com
```

## ICP Skills Used

Built during the [ICP Skills Community Testing](https://skills.internetcomputer.org/) sprint, composing 6 capabilities: `icp-cli`, `motoko`, `canister-security`, `stable-memory`, `evm-rpc`, `asset-canister`.

## License

Do whatever you want with this.
