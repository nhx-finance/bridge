# KESY Bi-Directional OmniBridge Architecture (Testnet)

## Overview

This document describes the upgraded **OmniBridge** architecture connecting **Hedera EVM Testnet** and **Ethereum Sepolia** (and arbitrarily more EVM chains) using Chainlink CCIP. 

Because Hedera Testnet does not yet expose CCIP Cross-Chain Token (CCT) pools (due to Hedera Token Service complexities), we have built a custom **Hub-and-Spoke OmniBridge**. Hedera acts as the central Hub locking and unlocking native HTS tokens, while EVM chains act as Spokes burning and minting wrapped ERC-20 tokens.

## Hub-and-Spoke Model

- **The Hub (Hedera Testnet):**
  - Holds the real KESY tokens in a smart contract vault.
  - *Outbound (Hub → Spoke):* Locks KESY tokens and dispatches a CCIP message to mint wKESY on the destination.
  - *Inbound (Spoke → Hub):* Receives a CCIP message and unlocks real KESY tokens back to the user.
- **The Spokes (EVM Chains like Sepolia):**
  - Hold no real KESY, only wrapped tokens (`wKESY`).
  - *Outbound (Spoke → Hub):* Burns the user's `wKESY` and dispatches a CCIP message to unlock KESY on the Hub.
  - *Inbound (Hub → Spoke):* Receives a CCIP message and mints new `wKESY` to the user.

## Unified Smart Contract: `KESYOmniBridge.sol`

Both the Hub and the Spoke share the exact same `KESYOmniBridge.sol` contract logic, differentiated only by a deployment flag `isHub`.
- If `isHub == true`, the contract uses `transferFrom` and `transfer` to lock and unlock real tokens.
- If `isHub == false`, the contract uses `burnFrom` and `mint` to destroy and create wrapped tokens.

### Security Posture
- **Router-gated delivery:** `onlyRouter` enforces that CCIP messages strictly come from Chainlink.
- **Strict Allowlists:** `onlyAllowlistedSource` and `onlyAllowlistedSender` ensures Spokes only respect messages from the Hub, and vice versa.
- **Dynamic `extraArgs`:** Gas limits are never hardcoded; they are updated dynamically per chain by the bridge admin.
- **Dynamic Fees:** Bridges call `getFee()` on the router before every dispatch, guaranteeing accurate gas payments in LINK.

## ⚠️ Critical UX Requirement: Hedera Token Association

Bridging from an EVM Spoke *back* to the Hedera Hub introduces a unique interaction hurdle: **Hedera Token Association**.

On Hedera, a wallet or contract cannot receive a token it hasn't explicitly "associated" with. If a user on Sepolia burns 100 wKESY to bridge it to a brand new Hedera wallet, the CCIP message will arrive on Hedera, attempt to transfer the unlocked KESY to the user, and **revert**. 

**The Solution:**
This must be handled by the Frontend UI.
1. The UI checks the user's connected Hedera account against the Mirror Node API.
2. If the user's account is NOT associated with the KESY token ID, the "Bridge" button on the EVM side is disabled.
3. The user is prompted to sign an "Associate KESY" transaction via their Hedera wallet (e.g., HashPack).
4. Once associated, the "Bridge" button unlocks, and the user can safely dispatch their cross-chain transaction knowing it will land successfully.

## Migration to Native CCIP CCT Pools
When Chainlink releases full Cross-Chain Token (CCT) pools for Hedera that natively handle `0x167` precompiles and association overheads, this custom infrastructure can be retired:
1. `wKESY` was built using the CCIP `BurnMintERC20` standard. The admin can simply revoke the OmniBridge's `BURNER_ROLE` and `MINTER_ROLE` and grant them to the official Chainlink `BurnMintTokenPool`.
2. Hedera KESY liquidity currently locked in the OmniBridge Vault can be migrated to the official Chainlink `LockReleaseTokenPool`.
