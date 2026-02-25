# KESY Bridge — Decentralized OmniBridge Guide

<div align="center">

**Bi-Directional Bridging: Hedera Testnet ↔ Ethereum Sepolia**

*Powered by Chainlink CCIP & KESY Global Hub*

</div>

---

## Architecture Overview

The KESY OmniBridge enables seamless, secure, and bidirectional token transfers between Hedera and EVM-compatible chains. It implements a **Hub-and-Spoke** model to overcome Hedera's current lack of native CCIP Token Pools.

### Bridging Flow (Bi-Directional)

```mermaid
sequenceDiagram
    participant User
    participant Hub as Hedera Hub (KESYOmniBridge)
    participant CCIP as Chainlink CCIP Network
    participant Spoke as Sepolia Spoke (KESYOmniBridge)
    participant wKESY as wKESY (Sepolia)

    Note over User, wKESY: Direction: Hedera -> Sepolia
    User->>Hub: 1. approve(KESY)
    User->>Hub: 2. bridgeKESY(Sepolia)
    Hub->>Hub: 3. Lock native KESY
    Hub->>CCIP: 4. ccipSend (Mint Order)
    CCIP->>Spoke: 5. ccipReceive
    Spoke->>wKESY: 6. mint(user, amount)

    Note over User, wKESY: Direction: Sepolia -> Hedera
    User->>wKESY: 7. approve(wKESY)
    User->>Spoke: 8. bridgeKESY(Hedera)
    Spoke->>wKESY: 9. burnFrom(user, amount)
    Spoke->>CCIP: 10. ccipSend (Unlock Order)
    CCIP->>Hub: 11. ccipReceive
    Hub->>Hub: 12. Unlock native KESY to User
```

### Logical Infrastructure

```mermaid
graph TB
    subgraph "Hedera Testnet (HUB)"
        KESY["KESY Token<br/><code>Native HTS (0x...4dc3)</code>"]
        LINK_H["LINK Token"]
        Hub["KESYOmniBridge<br/><code>isHub = true</code>"]
        HR["Hedera Router"]
    end

    subgraph "CCIP Network"
        DON["Decentralized Oracle Network"]
    end

    subgraph "Ethereum Sepolia (SPOKE)"
        SR["Sepolia Router"]
        Spoke["KESYOmniBridge<br/><code>isHub = false</code>"]
        WKESY["wKESY Token<br/><code>BurnMintERC20</code>"]
    end

    KESY <-->|"Vault Lock/Unlock"| Hub
    LINK_H -->|"Fee Payment"| Hub
    Hub <-->|"ccipSend"| HR
    HR <--> DON
    DON <--> SR
    SR <-->|"ccipReceive"| Spoke
    Spoke <-->|"Burn/Mint"| WKESY

    style Hub fill:#4F46E5,color:#fff
    style Spoke fill:#059669,color:#fff
    style WKESY fill:#D97706,color:#fff
    style KESY fill:#7C3AED,color:#fff
    style DON fill:#DC2626,color:#fff
```

## Contract & Network Reference

### Hedera Testnet (Hub)

| Item | Address / Value |
|------|----------------|
| **Hub Bridge** | [`0xD27c613C9d8D52C7E0BAE118562fB6cae7cC3A38`](https://hashscan.io/testnet/contract/0xD27c613C9d8D52C7E0BAE118562fB6cae7cC3A38) |
| **Native KESY** | [`0x00000000000000000000000000000000006E4dc3`](https://hashscan.io/testnet/token/0.0.7228099) |
| **CCIP Router** | `0x802C5F84eAD128Ff36fD6a3f8a418e339f467Ce4` |
| **LINK Token** | `0x90a386d59b9A6a4795a011e8f032Fc21ED6FEFb6` |
| **Chain Selector** | `222782988166878823` |

### Ethereum Sepolia (Spoke)

| Item | Address / Value |
|------|----------------|
| **Spoke Bridge** | [`0x5109Cd5e68e3182efeF8615C692989119aF76959`](https://sepolia.etherscan.io/address/0x5109Cd5e68e3182efeF8615C692989119aF76959) |
| **wKESY Token** | [`0x8Cff9519bb09f61B3A78e12572d569F071fd283A`](https://sepolia.etherscan.io/address/0x8Cff9519bb09f61B3A78e12572d569F071fd283A) |
| **CCIP Router** | `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59` |
| **LINK Token** | `0x779877A7B0D9E8603169DdbD7836e478b4624789` |
| **Chain Selector** | `16015286601757825753` |

---

## Security Model

1. **Router Protection:** The `onlyRouter` modifier ensures that only official Chainlink delivery mechanisms can trigger the `ccipReceive` logic.
2. **Dual-Layer Allowlisting:**
   - **Chain-Level:** Rejects messages from unauthorized chain selectors.
   - **Contract-Level:** Rejects messages from unauthorized sender addresses to prevent impersonation.
3. **Immutability of Logic:** The roles are fixed; a Hub cannot burn tokens, and a Spoke cannot unlock tokens it doesn't hold.
4. **Dynamic Fee Calculation:** All transactions query `getFee()` in real-time to prevent underpayment or hardcoded gas failures.

## Testing & Operations

See [DEPLOYMENT.md](./DEPLOYMENT.md) for full deployment instructions and [ARCHITECTURE.md](./ARCHITECTURE.md) for deep technical implementation details.

---

<div align="center">

**Built with ❤️ by the KESY Team using Chainlink CCIP**

</div>