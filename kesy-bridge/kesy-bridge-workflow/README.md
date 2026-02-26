# KESY Compliance Sync Workflow

A **Chainlink CRE (Chainlink Runtime Environment)** workflow that monitors the Hedera network for KESY token freeze events and propagates compliance state to the `PolicyManager` on EVM spoke chains (e.g., Sepolia).

## Architecture

```
┌─────────────────────────┐     ┌───────────────────┐     ┌─────────────────────┐
│   Hedera Mirror Node    │     │  CRE DON Network  │     │  Sepolia            │
│                         │     │                   │     │                     │
│  Freeze events for      │────▶│  Cron trigger      │────▶│  PolicyManager      │
│  KESY token (0.0.7228099)│     │  HTTP fetch        │     │  .setBlacklisted()  │
│                         │     │  DON-signed report │     │                     │
│                         │     │  writeReport()     │     │  wKESY._update()    │
│                         │     │                   │     │  checks compliance  │
└─────────────────────────┘     └───────────────────┘     └─────────────────────┘
```

## How It Works

1. **Cron Trigger**: The workflow runs on a schedule (default: every 5 minutes)
2. **Mirror Node Polling**: Fetches recent freeze/unfreeze events for the KESY token from the Hedera Mirror Node API
3. **Report Generation**: Encodes a `setBlacklisted(address, bool)` call and signs it via DON consensus
4. **Chain Write**: Delivers the signed report to the `PolicyManager` contract on Sepolia via the CRE Forwarder

## Setup

### Install dependencies
```bash
cd kesy-bridge-workflow && bun install
```

### Configure `.env`
```env
CRE_ETH_PRIVATE_KEY=<your-funded-sepolia-private-key>
CRE_TARGET=staging-settings
```

### Simulate locally
```bash
cre workflow simulate ./kesy-bridge-workflow --target=staging-settings
```

### Deploy to CRE
```bash
cre workflow deploy ./kesy-bridge-workflow --target=staging-settings
```

## Config Reference

| Field | Description |
|-------|-------------|
| `schedule` | Cron schedule (e.g., `*/300 * * * * *` = every 5 min) |
| `hederaMirrorUrl` | Hedera Mirror Node base URL |
| `hederaKesyTokenId` | KESY token ID on Hedera (e.g., `0.0.7228099`) |
| `sepoliaChainSelector` | CCIP chain selector for Sepolia |
| `policyManagerAddress` | PolicyManager contract address on Sepolia |

## Deployed Addresses

| Contract | Chain | Address |
|----------|-------|---------|
| PolicyManager | Sepolia | `0x0eb38584703b9d22b757a5772211f78d8bae391d` |
| wKESY | Sepolia | `0xeE60AaAc2b6173f3Ff42ad3F1ff615d09100C4A7` |
| Spoke Bridge | Sepolia | `0xbE6E85a565eE95Bb6bdFb8f98D5677f84e8686eE` |
| Hub Bridge | Hedera Testnet | `0xD27c613C9d8D52C7E0BAE118562fB6cae7cC3A38` |
