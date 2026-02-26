# KESY OmniBridge — Architecture

## System Overview

KESY is a regulated stablecoin issued as a native HTS token on Hedera. The OmniBridge brings it to EVM chains via Chainlink CCIP, with full compliance enforcement via **Chainlink ACE (Automated Compliance Engine)** and automated state sync via **CRE (Chainlink Runtime Environment)**.

---

## Hub-and-Spoke Model

```mermaid
graph LR
    subgraph "Hedera (Hub)"
        H_KESY["Native KESY"] --> H_BRIDGE["KESYOmniBridge<br/>isHub=true<br/>Lock / Unlock"]
    end

    subgraph "Chainlink"
        CCIP["CCIP<br/>Arbitrary Messaging"]
    end

    subgraph "Sepolia (Spoke)"
        S_BRIDGE["KESYOmniBridge<br/>isHub=false<br/>Burn / Mint"] --> S_WKESY["wKESY<br/>PolicyProtected<br/>ERC-20"]
    end

    H_BRIDGE <-->|"CCIP Messages"| CCIP
    CCIP <-->|"CCIP Messages"| S_BRIDGE

    style H_BRIDGE fill:#4F46E5,color:#fff
    style S_BRIDGE fill:#059669,color:#fff
    style S_WKESY fill:#D97706,color:#fff
```

A single `KESYOmniBridge.sol` is deployed on both chains, differentiated by `isHub`:

- **Hub (Hedera):** Locks native KESY on outbound, unlocks on inbound
- **Spoke (Sepolia):** Burns wKESY on outbound, mints on inbound

---

## ACE Compliance Layer

Chainlink ACE is a generalized on-chain policy framework. We use the real `@chainlink/policy-management` v1.0.0 package.

### Components

```mermaid
graph TB
    subgraph "ACE Infrastructure (all on Sepolia)"
        PE["PolicyEngine<br/><i>ERC1967Proxy</i><br/>Registry + Coordinator"]
        RP["RejectPolicy<br/><i>ERC1967Proxy</i><br/>Address Blacklist"]
        VP["VolumePolicy<br/><i>ERC1967Proxy</i><br/>Min/Max Transfer Caps"]
        EX["KESYExtractor<br/>Parameter Extraction"]
    end

    subgraph "Protected Contract"
        WKESY["wKESY<br/>inherits PolicyProtected"]
    end

    WKESY -->|"runPolicy()"| PE
    PE -->|"extract(msg.sig, msg.data)"| EX
    PE -->|"run(account)"| RP
    PE -->|"run(amount)"| VP

    style PE fill:#BE185D,color:#fff
    style RP fill:#DC2626,color:#fff
    style VP fill:#7C3AED,color:#fff
    style WKESY fill:#D97706,color:#fff
```

| Component | Role |
|-----------|------|
| **PolicyEngine** | Registry: maps `(contract, selector) → policies[]`. Runs policies in order. |
| **RejectPolicy** | Rejects ops if any address is on the reject list (`rejectAddress()` / `unrejectAddress()`) |
| **VolumePolicy** | Rejects ops if amount is below min or above max (`setMin()` / `setMax()`) |
| **KESYExtractor** | Parses calldata for `transfer`, `transferFrom`, `mint`, `burnFrom` → extracts `account` + `amount` |
| **wKESY** | Inherits `PolicyProtected`. Every token op calls `runPolicy()` before executing |

### Policy Configuration (how policies are attached)

```solidity
// Attach RejectPolicy to wKESY's transfer() selector
policyEngine.setExtractor(transferSelector, address(kesyExtractor));
policyEngine.addPolicy(
    address(wKESY),        // target contract
    transferSelector,       // function selector
    address(rejectPolicy),  // policy contract
    [keccak256("account")]  // parameter IDs to pass to policy
);
```

Policies are attached per `(contract address + function selector)` with specific `keccak256` parameter IDs. The extractor translates raw calldata into named parameters that policies understand.

### Protected Selectors

| Selector | RejectPolicy | VolumePolicy |
|----------|:---:|:---:|
| `transfer(address,uint256)` | ✅ checks `to` | ✅ checks `amount` |
| `transferFrom(address,address,uint256)` | ✅ checks `to` | ✅ checks `amount` |
| `mint(address,uint256)` | ✅ checks `to` | — |
| `burnFrom(address,uint256)` | ✅ checks `account` | — |

---

## CRE Compliance Sync Workflow

```mermaid
flowchart LR
    A["Hedera Admin<br/>freezes account"] --> B["Mirror Node<br/>records event"]
    B --> C["CRE Workflow<br/>polls every 5 min"]
    C --> D["RejectPolicy<br/>rejectAddress()"]
    D --> E["wKESY.transfer()<br/>reverts for<br/>this address"]

    style A fill:#7C3AED,color:#fff
    style C fill:#0891B2,color:#fff
    style D fill:#DC2626,color:#fff
    style E fill:#D97706,color:#fff
```

The CRE workflow monitors Hedera's Mirror Node for KESY freeze events and propagates them to the `RejectPolicy` on Sepolia. Currently, the `RejectPolicy.rejectAddress()` function is `onlyOwner`, so the CRE workflow's on-chain delivery targets the deployer address. In production, this would use a CRE Forwarder → ComplianceConsumer → RejectPolicy chain.

**Max propagation delay:** ~5 minutes (configurable via cron schedule)

---

## Bridge Flow

```mermaid
sequenceDiagram
    participant User
    participant Hub as Hub Bridge (Hedera)
    participant CCIP
    participant Spoke as Spoke Bridge (Sepolia)
    participant ACE as PolicyEngine
    participant wKESY

    Note over User,wKESY: Hedera → Sepolia (Lock & Mint)
    User->>Hub: bridgeKESY(sepolia, receiver, 100)
    Hub->>Hub: KESY.safeTransferFrom(user, bridge, 100)
    Hub->>CCIP: ccipSend(receiver, 100)
    CCIP->>Spoke: ccipReceive(receiver, 100)
    Spoke->>wKESY: mint(receiver, 100)
    wKESY->>ACE: runPolicy() → RejectPolicy ✓
    ACE-->>wKESY: Allowed
    wKESY->>wKESY: _mint(receiver, 100) ✓

    Note over User,wKESY: Sepolia → Hedera (Burn & Unlock)
    User->>Spoke: bridgeKESY(hedera, receiver, 100)
    Spoke->>wKESY: burnFrom(user, 100)
    wKESY->>ACE: runPolicy() → RejectPolicy ✓
    Spoke->>CCIP: ccipSend(receiver, 100)
    CCIP->>Hub: ccipReceive(receiver, 100)
    Hub->>Hub: KESY.safeTransfer(receiver, 100)
```

---

## Deployed Addresses (Testnet)

### Hedera Testnet

| Contract | Address |
|----------|---------|
| Hub Bridge | `0xD27c613C9d8D52C7E0BAE118562fB6cae7cC3A38` |
| Native KESY | `0x006E4dc3` (Token ID: 0.0.7228099) |

### Ethereum Sepolia

| Contract | Address |
|----------|---------|
| PolicyEngine (proxy) | `0x990D65f053c8Fa6Dfe43cF293534474B94F906a3` |
| RejectPolicy (proxy) | `0x366491aB0a574385B1795E24477D91BF2840c301` |
| VolumePolicy (proxy) | `0xA2899CAa08977408792aE767799d2144B5112469` |
| KESYExtractor | `0xaBCEf98127Da5DB87b41593E47a5d1a492bAA82b` |
| wKESY | `0xa3CC176553fbCe4Bb1270752d9c75464d21F6ba1` |
| Spoke Bridge | `0x4B0D9839db5962022E17fa8d61F3b6Ac8BB82a48` |
