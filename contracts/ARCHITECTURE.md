# KESY Cross-Chain Bridging Architecture (Testnet)

## Overview

This document describes the current KESY bridging stack between **Hedera EVM Testnet** and **Ethereum Sepolia** using Chainlink CCIP. The design intentionally ships with a **messaging-only fallback** because Hedera Testnet does **not yet expose CCIP Cross-Chain Token (CCT) pools** in the public directory. As soon as LockRelease/BurnMint pools are available on this lane, we will upgrade to the native CCT path.

## Supported Path (Currently)

- **Direction:** Hedera Testnet → Ethereum Sepolia (one-way)
- **Mechanism:** CCIP Arbitrary Messaging (no token pools)
- **Tokens:**
  - KESY (Hedera) — existing live token at `0x00000000000000000000000000000000006e4dc3`
  - wKESY (Sepolia) — wrapped representation minted on receipt
- **Fee token:** LINK
  - Hedera LINK: `0x90a386d59b9A6a4795a011e8f032Fc21ED6FEFb6`
  - Sepolia LINK: `0x779877A7B0D9E8603169DdbD7836e478b4624789`
- **Routers:**
  - Hedera router: `0x802C5F84eAD128Ff36fD6a3f8a418e339f467Ce4`
  - Sepolia router: `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59`
- **Chain selectors:**
  - Hedera Testnet: `222782988166878823`
  - Ethereum Sepolia: `16015286601757825753`

## Contracts in Scope (Messaging Fallback)

- **BridgeSender (Hedera):**
  - Locks KESY via `transferFrom`.
  - Builds `EVM2AnyMessage` with encoded mint instructions in `data` (tokenAmounts empty).
  - Fetches dynamic fee via `getFee` and pays in LINK.
  - Emits `MessageSent` for UI/monitoring.
  - Dynamic allowlists: destination selectors and receiver bytes; supports arbitrary chains.
  - Dynamic `extraArgs`: stored per selector or passed per call (gas tuning per destination).
- **BridgeReceiver (Sepolia):**
  - Inherits `CCIPReceiver`; only the router can deliver.
  - Allows only allowlisted source selector + sender bytes.
  - Decodes `(user, amount)` from `data` and mints wKESY.
  - Emits `MessageReceived` for tracking.
- **wKESY (Sepolia):**
  - ERC20 with `MINTER_ROLE` granted to BridgeReceiver (in fallback mode).
  - Will be swapped to CCIP’s pre-audited `BurnMintERC20` when CCT pools go live.

## What’s Deliberately Deferred (Pending Hedera CCT Pools)

- **LockReleaseTokenPool (Hedera) + BurnMintTokenPool (Sepolia):** Not listed in the Hedera Testnet CCIP directory; CCT support marked “in progress.”
- **TokenAdminRegistry + RegistryModuleOwnerCustom registration:** Requires pool availability and token admin proof; deferred to avoid broken wiring.
- **Rate limits in pools:** Will be enforced once pools are active (per-hour/per-day caps).
- **Return path (Sepolia → Hedera):** Burn-and-unlock flow will be added with pools or a mirror messaging path.
- **Permit-based UX:** Current flow uses approve + transferFrom; permits can be added later.

## Security Posture

- Router-gated delivery (`onlyRouter` in receiver).
- Source/destination allowlists by chain selector and sender/receiver bytes (agnostic to EVM vs non-EVM addressing).
- Dynamic `extraArgs` per chain to avoid hardcoded gas assumptions.
- Fees are always quoted on-chain via `getFee` before send.
- Admin-controlled withdrawal of stuck tokens; no uncontrolled minting.

## Migration Plan to Full CCT (When Available)

1. Confirm CCT pool availability for Hedera ↔ Sepolia in the CCIP directory.
2. Assert token authority: KESY owner/admin on Hedera and wKESY admin on Sepolia.
3. Deploy pools:
   - LockReleaseTokenPool on Hedera for KESY locking + outbound rate limits.
   - BurnMintTokenPool on Sepolia with mint/burn rights on wKESY.
4. Register tokens and pools in TokenAdminRegistry/RegistryModuleOwnerCustom; configure rate limits and fee token settings.
5. Gradually switch UI to pool-based transfers while keeping messaging fallback as a guardrail.
6. Add the return path (Sepolia → Hedera) via burn-and-unlock once pools are active.

## User-Facing Expectations (While on Messaging Fallback)

- Direction supported: Hedera → Ethereum Sepolia only.
- Users need KESY + LINK on Hedera for the send; receive wKESY on Sepolia.
- Status can be tracked via `MessageSent` (Hedera) and `MessageReceived` (Sepolia), plus CCIP status APIs.

## Rationale for Shipping Now

- The messaging path is production-grade for authenticated, allowlisted, router-delivered messages.
- Avoids blocking on Hedera’s pending CCT pool enablement while keeping an upgrade path open.
- Architecture is chain-selector and address-format agnostic, enabling future expansion to additional CCIP-supported networks.
