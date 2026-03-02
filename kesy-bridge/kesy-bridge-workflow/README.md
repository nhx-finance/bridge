# KESY Compliance Sync Workflow

<div align="center">

**Chainlink CRE · Automated Cross-Chain Compliance**

_Stablecoin SDK Server → CRE DON → ACE RejectPolicy on Sepolia_

</div>

---

## What This Workflow Does

This workflow is the **automated compliance bridge** between Hedera's native freeze/unfreeze capabilities (HTS) and the on-chain ACE `RejectPolicy` that guards every `wKESY` token operation on Sepolia via Chainlink's Automated Compliance Engine.

Without this workflow, a Hedera admin would need to manually freeze on Hedera _and_ separately submit a transaction on every EVM chain. With CRE, this is fully automated.

---

## Architecture

```mermaid
graph TB
    subgraph "Hedera Network"
        HTS["🪙 KESY HTS Token<br/><i>0.0.7228099</i>"]
        MN["🪞 Stablecoin SDK Server<br/><i>testnet.mirrornode.hedera.com</i>"]
        Admin["👤 Compliance Admin"]
    end

    subgraph "Chainlink Runtime Environment"
        CRON["⏰ CronCapability<br/><i>Every 5 minutes</i>"]
        HTTP["🌐 HTTP Capability<br/><i>runInNodeMode</i>"]
        DON["🔐 DON Consensus<br/><i>runtime.report()</i>"]
        EVM["⛓️ EVM Capability<br/><i>writeReport()</i>"]
    end

    subgraph "Ethereum Sepolia — ACE Stack"
        RP["🛡️ RejectPolicy<br/><code>0x3664...01</code>"]
        PE["🔧 PolicyEngine<br/><code>0x990D...a3</code>"]
        WKESY["🪙 wKESY Token<br/><code>0xa3CC...a1</code>"]
    end

    Admin -->|"HTS freeze"| HTS
    HTS -->|"event recorded"| MN
    CRON -->|"triggers"| HTTP
    HTTP -->|"GET /tokens/{id}/balances"| MN
    MN -->|"frozen accounts"| HTTP
    HTTP -->|"encode rejectAddress()"| DON
    DON -->|"signed report"| EVM
    EVM -->|"writeReport()"| RP
    RP -.->|"policy enforcement"| PE
    PE -.->|"runPolicy() rejects"| WKESY

    style CRON fill:#0891B2,color:#fff
    style DON fill:#DC2626,color:#fff
    style RP fill:#BE185D,color:#fff
    style WKESY fill:#D97706,color:#fff
    style Admin fill:#7C3AED,color:#fff
```

---

## Execution Flow

```mermaid
sequenceDiagram
    participant CRE as CRE Workflow
    participant MN as Mirror Node API
    participant DON as DON Consensus
    participant RP as RejectPolicy (Sepolia)
    participant wKESY as wKESY Token

    Note over CRE: ⏰ Cron fires (every 5 min)
    CRE->>MN: GET /api/v1/tokens/0.0.7228099/balances
    MN-->>CRE: { balances: [{account, balance}] }
    CRE->>CRE: Filter frozen accounts
    alt No frozen accounts
        CRE->>CRE: Log "No updates needed"
    else Found frozen accounts
        CRE->>CRE: encodeFunctionData(rejectAddress, [addr])
        CRE->>DON: runtime.report(encodedPayload)
        DON-->>CRE: Signed report (ecdsa + keccak256)
        CRE->>RP: evmClient.writeReport(receiver, report)
        RP-->>RP: rejectList[addr] = true
        Note over RP,wKESY: Next wKESY op → PolicyEngine →<br/>RejectPolicy → ❌ PolicyRejected
    end
```

---

## Workflow Code Highlights

### 1. Cron Trigger → Mirror Node Poll

```typescript
// Fetch from Stablecoin SDK Server inside DON consensus
const frozenCount = runtime
  .runInNodeMode((nodeRuntime) => {
    const httpClient = new cre.capabilities.HTTPClient();
    const response = httpClient
      .sendRequest(nodeRuntime, {
        url: `${config.hederaMirrorUrl}/api/v1/tokens/${config.hederaKesyTokenId}/balances`,
        method: "GET",
      })
      .result();
    // Parse response and count frozen accounts
    return accounts.length;
  }, consensusMedianAggregation())()
  .result();
```

### 2. DON-Signed Report → EVM Delivery

```typescript
// Encode rejectAddress(addr) calldata
const calldata = encodeFunctionData({
  abi: RejectPolicyABI,
  functionName: "rejectAddress",
  args: [frozenAddress],
});

// Generate DON-signed report
const report = runtime
  .report({
    encodedPayload: hexToBase64(calldata),
    encoderName: "evm",
    signingAlgo: "ecdsa",
    hashingAlgo: "keccak256",
  })
  .result();

// Deliver to RejectPolicy on Sepolia
const resp = evmClient
  .writeReport(runtime, {
    receiver: config.rejectPolicyAddress,
    report: report,
    gasConfig: { gasLimit: "200000" },
  })
  .result();
```

---

## Configuration

### `config.staging.json`

```json
{
  "schedule": "*/300 * * * * *",
  "hederaMirrorUrl": "https://testnet.mirrornode.hedera.com",
  "hederaKesyTokenId": "0.0.7228099",
  "sepoliaChainSelector": "16015286601757825753",
  "rejectPolicyAddress": "0x366491aB0a574385B1795E24477D91BF2840c301"
}
```

| Field                  | Description                                              |
| ---------------------- | -------------------------------------------------------- |
| `schedule`             | Cron expression (e.g., `*/300 * * * * *` = every 5 min)  |
| `hederaMirrorUrl`      | Stablecoin SDK Server base URL                           |
| `hederaKesyTokenId`    | KESY token ID on Hedera                                  |
| `sepoliaChainSelector` | CCIP chain selector for Sepolia (`16015286601757825753`) |
| `rejectPolicyAddress`  | Deployed ACE RejectPolicy on Sepolia                     |

---

## Setup & Running

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
# From the kesy-bridge project root:
cre workflow simulate ./kesy-bridge-workflow --target=staging-settings
```

### Deploy to CRE network

```bash
cre workflow deploy ./kesy-bridge-workflow --target=staging-settings
```

---

## Architecture: CRE → ComplianceConsumer → RejectPolicy

`RejectPolicy.rejectAddress()` is restricted to `onlyOwner`. The CRE DON delivers signed reports via a **CRE Forwarder contract** — not the deployer EOA. To solve this, the `ComplianceConsumer` contract owns the `RejectPolicy` and acts as middleware:

```mermaid
graph LR
    DON["CRE DON"] -->|"signed report"| FWD["CRE Forwarder"]
    FWD -->|"processReport(addr, true)"| CC["ComplianceConsumer<br/><code>0x6917...72bc</code><br/><i>owns RejectPolicy</i>"]
    CC -->|"rejectAddress(addr)"| RP["RejectPolicy<br/><code>0x3664...01</code>"]

    style DON fill:#0891B2,color:#fff
    style FWD fill:#7C3AED,color:#fff
    style CC fill:#059669,color:#fff
    style RP fill:#DC2626,color:#fff
```

| Function | Description |
|----------|-------------|
| `processReport(address, bool)` | `true` → reject, `false` → unreject |
| `batchProcessReport(address[], bool)` | Batch reject/unreject multiple addresses |
| `isRejected(address)` | Check rejection status |
| `setRejectPolicy(address)` | Admin: update policy address |

```bash
# Reject an address via ComplianceConsumer
cast send 0x6917e5902a2eadd13ba0008951e0af19746372bc \
  "processReport(address,bool)" <TARGET_ADDRESS> true \
  --rpc-url $ETH_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

---

## Deployed Addresses

| Contract | Chain | Address |
|----------|-------|---------|
| **PolicyEngine** | Sepolia | [`0x990D65f053c8Fa6Dfe43cF293534474B94F906a3`](https://sepolia.etherscan.io/address/0x990D65f053c8Fa6Dfe43cF293534474B94F906a3) |
| **RejectPolicy** | Sepolia | [`0x366491aB0a574385B1795E24477D91BF2840c301`](https://sepolia.etherscan.io/address/0x366491aB0a574385B1795E24477D91BF2840c301) |
| **ComplianceConsumer** | Sepolia | [`0x6917e5902a2eadd13ba0008951e0af19746372bc`](https://sepolia.etherscan.io/address/0x6917e5902a2eadd13ba0008951e0af19746372bc) |
| **VolumePolicy** | Sepolia | [`0xA2899CAa08977408792aE767799d2144B5112469`](https://sepolia.etherscan.io/address/0xA2899CAa08977408792aE767799d2144B5112469) |
| **wKESY Token** | Sepolia | [`0xa3CC176553fbCe4Bb1270752d9c75464d21F6ba1`](https://sepolia.etherscan.io/address/0xa3CC176553fbCe4Bb1270752d9c75464d21F6ba1) |
| **Spoke Bridge** | Sepolia | [`0x4B0D9839db5962022E17fa8d61F3b6Ac8BB82a48`](https://sepolia.etherscan.io/address/0x4B0D9839db5962022E17fa8d61F3b6Ac8BB82a48) |
| **Hub Bridge** | Hedera Testnet | [`0xD27c613C9d8D52C7E0BAE118562fB6cae7cC3A38`](https://hashscan.io/testnet/contract/0xD27c613C9d8D52C7E0BAE118562fB6cae7cC3A38) |

---

## End-to-End Compliance Picture

```mermaid
graph LR
    A["Hedera Admin<br/>freezes account"] --> B["Mirror Node<br/>records event"]
    B --> C["CRE Workflow<br/>polls every 5 min"]
    C --> D["RejectPolicy<br/>rejectAddress()"]
    D --> E["wKESY.transfer()<br/>PolicyEngine → RejectPolicy<br/>→ ❌ PolicyRejected"]

    style A fill:#7C3AED,color:#fff
    style C fill:#0891B2,color:#fff
    style D fill:#BE185D,color:#fff
    style E fill:#DC2626,color:#fff
```

> **Max propagation delay:** ~5 minutes (configurable via cron schedule)
>
> **Coverage:** All EVM Spoke chains that share the same ACE pattern — deploy a new Spoke with its own PolicyEngine + RejectPolicy, point CRE at its RejectPolicy address, and compliance auto-propagates from day one.
