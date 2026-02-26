# KESY OmniBridge — Technical Overview

## What KESY Is

KESY is a **stablecoin** issued as a native **HTS (Hedera Token Service) token** on Hedera. We've built a cross-chain bridge to bring it to EVM chains using Chainlink CCIP.

---

## Architecture: Hub-and-Spoke via CCIP Arbitrary Messaging

We use a **single unified contract** (`KESYOmniBridge.sol`) deployed on both chains, differentiated by an `isHub` immutable flag:

- **Hub (Hedera, `isHub=true`):** Holds the real KESY in a vault. Locks tokens on outbound, unlocks on inbound.
- **Spoke (Sepolia/EVM, `isHub=false`):** Burns `wKESY` on outbound, mints on inbound. No real KESY ever lives here.

We use **CCIP Arbitrary Messaging** (not CCT token pools) because Hedera Testnet doesn't yet support native CCIP token pools due to HTS precompile complexities.

---

## Smart Contracts

### `KESYOmniBridge.sol` (deployed on both chains)

```solidity
contract KESYOmniBridge is CCIPReceiver, Ownable, ReentrancyGuard {
    IERC20 public immutable i_token;  // KESY on Hedera, wKESY on EVM
    bool public immutable i_isHub;    // true = lock/unlock, false = burn/mint

    // Outbound: user calls bridgeKESY()
    function _bridgeKESY(...) internal {
        if (i_isHub) {
            i_token.safeTransferFrom(msg.sender, address(this), _amount); // LOCK
        } else {
            IwKESY(address(i_token)).burnFrom(msg.sender, _amount);       // BURN
        }
        // Encode (msg.sender, amount) → router.ccipSend()
    }

    // Inbound: CCIP router delivers message
    function _ccipReceive(Client.Any2EVMMessage memory msg) internal override {
        (address recipient, uint256 amount) = abi.decode(msg.data, (address, uint256));
        if (i_isHub) {
            i_token.safeTransfer(recipient, amount);                      // UNLOCK
        } else {
            IwKESY(address(i_token)).mint(recipient, amount);             // MINT
        }
    }
}
```

### `wKESY.sol` (EVM only)

```solidity
contract wKESY is ERC20, ERC20Burnable, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function decimals() public pure override returns (uint8) { return 6; } // matches native KESY
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) { _mint(to, amount); }
    function burnFrom(address account, uint256 amount) public override onlyRole(BURNER_ROLE) {
        super.burnFrom(account, amount);
    }
}
```

Only the bridge contract holds `MINTER_ROLE` and `BURNER_ROLE`.

---

## Security Model

- **Router-gated:** `onlyRouter` on `ccipReceive`
- **Dual allowlists:** Chain selector + contract address verified on both send and receive
- **Dynamic fees:** `router.getFee()` called per transaction
- **Owner-only config:** All allowlist and extraArgs changes require `onlyOwner`

---

## Deployed Addresses (Testnet)

| Contract | Chain | Address |
|----------|-------|---------|
| Hub Bridge | Hedera Testnet | `0xD27c613C9d8D52C7E0BAE118562fB6cae7cC3A38` |
| Spoke Bridge | Sepolia | `0x5109Cd5e68e3182efeF8615C692989119aF76959` |
| wKESY | Sepolia | `0x8Cff9519bb09f61B3A78e12572d569F071fd283A` |
| Native KESY | Hedera | `0x00000000000000000000000000000000006E4dc3` |

---

## What We Want to Explore with CRE/ACE

Since KESY is a **stablecoin**, we need to maintain compliance (e.g., freeze/seize, allowlist/blocklist) on the bridged `wKESY` across EVM chains. We're looking at how CRE workflows and ACE could help us:

1. **Automate compliance enforcement** on bridged wKESY (e.g., blocklist checks before mint)
2. **Cross-chain state synchronization** (e.g., if an address is frozen on Hedera, propagate that to all Spokes)
3. **Monitoring and alerting** on bridge activity
