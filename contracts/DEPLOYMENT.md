# Deployment & Operation: KESY OmniBridge

This document provides step-by-step instructions for deploying and interacting with the bidirectional KESY bridge stack.

## Prerequisites

- **Foundry** installed (`forge`, `cast`, `anvil`).
- **Private Key** with sufficient HBAR (Hedera) and SepoliaETH (Sepolia).
- **LINK Tokens** on both chains for CCIP transaction fees.

## 1. Deployment Steps

### A. Deploy to Ethereum Sepolia (Spoke)
```bash
source .env
forge script script/DeploySepolia.s.sol:DeploySepolia --rpc-url $ETH_SEPOLIA_RPC_URL --broadcast -vvvv
```
*Note the wKESY and Bridge Spoke addresses.*

### B. Deploy to Hedera Testnet (Hub)
```bash
forge script script/DeployHedera.s.sol:DeployHedera --rpc-url $HEDERA_TESTNET_RPC_URL --broadcast -vvvv
```
*Note the Bridge Hub address.*

## 2. Configuration & Allowlisting

Both contracts must be configured to recognize each other as legitimate cross-chain partners.

### Configure Hedera Hub
```bash
HEDERA_HUB=0xD27c613C9d8D52C7E0BAE118562fB6cae7cC3A38
SEPOLIA_SPOKE=0x5109Cd5e68e3182efeF8615C692989119aF76959
SEPOLIA_CHAIN=16015286601757825753
SPOKE_BYTES=$(cast abi-encode "f(address)" $SEPOLIA_SPOKE)

# Allowlists
cast send $HEDERA_HUB "allowlistDestinationChain(uint64,bool)" $SEPOLIA_CHAIN true --rpc-url $HEDERA_TESTNET_RPC_URL --private-key $PRIVATE_KEY
cast send $HEDERA_HUB "allowlistSourceChain(uint64,bool)" $SEPOLIA_CHAIN true --rpc-url $HEDERA_TESTNET_RPC_URL --private-key $PRIVATE_KEY
cast send $HEDERA_HUB "allowlistReceiver(uint64,bytes,bool)" $SEPOLIA_CHAIN $SPOKE_BYTES true --rpc-url $HEDERA_TESTNET_RPC_URL --private-key $PRIVATE_KEY
cast send $HEDERA_HUB "allowlistSender(uint64,bytes,bool)" $SEPOLIA_CHAIN $SPOKE_BYTES true --rpc-url $HEDERA_TESTNET_RPC_URL --private-key $PRIVATE_KEY

# Gas Limit (200k standard)
EXTRA_ARGS="0x97a657c90000000000000000000000000000000000000000000000000000000000030d40"
cast send $HEDERA_HUB "setDefaultExtraArgs(uint64,bytes)" $SEPOLIA_CHAIN $EXTRA_ARGS --rpc-url $HEDERA_TESTNET_RPC_URL --private-key $PRIVATE_KEY
```

### Configure Sepolia Spoke
```bash
HEDERA_CHAIN=222782988166878823
HUB_BYTES=$(cast abi-encode "f(address)" $HEDERA_HUB)

# Allowlists
cast send $SEPOLIA_SPOKE "allowlistDestinationChain(uint64,bool)" $HEDERA_CHAIN true --rpc-url $ETH_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
cast send $SEPOLIA_SPOKE "allowlistSourceChain(uint64,bool)" $HEDERA_CHAIN true --rpc-url $ETH_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
cast send $SEPOLIA_SPOKE "allowlistReceiver(uint64,bytes,bool)" $HEDERA_CHAIN $HUB_BYTES true --rpc-url $ETH_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
cast send $SEPOLIA_SPOKE "allowlistSender(uint64,bytes,bool)" $HEDERA_CHAIN $HUB_BYTES true --rpc-url $ETH_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY

# Gas Limit (200k standard)
cast send $SEPOLIA_SPOKE "setDefaultExtraArgs(uint64,bytes)" $HEDERA_CHAIN $EXTRA_ARGS --rpc-url $ETH_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

---

## 3. Live Bridge Operations

### Direction 1: Hedera -> Sepolia
1. **Approve:** `cast send 0x...4dc3 "approve(address,uint256)" $HEDERA_HUB 1000000... --private-key $PRIVATE_KEY`
2. **Bridge:** `cast send $HEDERA_HUB "bridgeKESY(uint64,bytes,uint256)" $SEPOLIA_CHAIN $SPOKE_BYTES 1000000... --private-key $PRIVATE_KEY`

### Direction 2: Sepolia -> Hedera
**⚠️ WARNING:** Destination Hedera wallet **MUST** be associated with KESY (0x...4dc3) before sending!
1. **Approve:** `cast send $wKESY_TOKEN "approve(address,uint256)" $SEPOLIA_SPOKE 1000000... --private-key $PRIVATE_KEY`
2. **Bridge:** `cast send $SEPOLIA_SPOKE "bridgeKESY(uint64,bytes,uint256)" $HEDERA_CHAIN $HUB_BYTES 1000000... --private-key $PRIVATE_KEY`

## 4. Monitoring

Track any `transactionHash` using:
- **CCIP Explorer:** [ccip.chain.link](https://ccip.chain.link)
- **HashScan (Hedera Testnet):** [hashscan.io/testnet](https://hashscan.io/testnet)
- **Etherscan (Sepolia):** [sepolia.etherscan.io](https://sepolia.etherscan.io)