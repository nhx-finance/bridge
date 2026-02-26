// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {PolicyManager} from "./PolicyManager.sol";

/**
 * @title wKESY
 * @dev Wrapped KESY token on EVM chains (e.g., Sepolia).
 *
 * Integrates with an on-chain PolicyManager (ACE stub) to enforce compliance
 * on every token movement (mint, burn, transfer). If either party is blacklisted,
 * the operation reverts atomically.
 */
contract wKESY is ERC20, ERC20Burnable, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    PolicyManager public immutable policyManager;

    error NonCompliantOperation(address from, address to, uint256 amount);

    constructor(address _policyManager) ERC20("Wrapped KESY", "wKESY") {
        policyManager = PolicyManager(_policyManager);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @dev Match native KESY's 6 decimals on Hedera for 1:1 bridging.
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @dev OZ v5 unified hook — called on every mint, burn, and transfer.
     * Enforces ACE compliance before any token state change.
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        bytes memory context;
        if (from == address(0)) {
            context = abi.encode("mint");
        } else if (to == address(0)) {
            context = abi.encode("burn");
        } else {
            context = abi.encode("transfer");
        }

        if (!policyManager.isCompliant(from, to, value, context)) {
            revert NonCompliantOperation(from, to, value);
        }

        super._update(from, to, value);
    }

    /**
     * @dev Creates `amount` new tokens for `to`.
     * Requires the caller to have the `MINTER_ROLE`.
     * Compliance is enforced via _update → PolicyManager.
     */
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, deducting from the caller's allowance.
     * The caller must have the `BURNER_ROLE`. Compliance is enforced via _update.
     */
    function burnFrom(address account, uint256 amount) public override onlyRole(BURNER_ROLE) {
        super.burnFrom(account, amount);
    }

    // Override required by Solidity for multiple inheritance
    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
