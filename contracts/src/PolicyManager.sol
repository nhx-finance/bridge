// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PolicyManager
 * @dev A stub ACE PolicyManager for on-chain compliance enforcement.
 *
 * Manages a blacklist of addresses. Any token movement (mint, burn, transfer)
 * involving a blacklisted address will be blocked by the wKESY token's _update hook.
 *
 * In production, this would be replaced by Chainlink's audited ACE PolicyEngine
 * with modular policies (blacklist, volume limits, KYC attestations, etc.).
 */
contract PolicyManager is Ownable {
    // ── State ──────────────────────────────────────────────────────────
    mapping(address => bool) public blacklisted;

    // ── Events ─────────────────────────────────────────────────────────
    event AddressBlacklisted(address indexed account, bool status);

    // ── Errors ─────────────────────────────────────────────────────────
    error AddressIsBlacklisted(address account);

    constructor() Ownable(msg.sender) {}

    // ── Admin ──────────────────────────────────────────────────────────

    /**
     * @notice Add or remove an address from the blacklist.
     * @dev Only callable by the owner (or, in production, a CRE workflow via a multisig).
     */
    function setBlacklisted(address _account, bool _status) external onlyOwner {
        blacklisted[_account] = _status;
        emit AddressBlacklisted(_account, _status);
    }

    /**
     * @notice Batch-update the blacklist for multiple addresses.
     * @dev Useful for CRE workflows propagating multiple Hedera freeze events at once.
     */
    function batchSetBlacklisted(address[] calldata _accounts, bool _status) external onlyOwner {
        for (uint256 i = 0; i < _accounts.length; i++) {
            blacklisted[_accounts[i]] = _status;
            emit AddressBlacklisted(_accounts[i], _status);
        }
    }

    // ── Compliance Check ───────────────────────────────────────────────

    /**
     * @notice Check whether a token operation is compliant.
     * @param from Source address (address(0) for mints).
     * @param to Destination address (address(0) for burns).
     * @return True if the operation is allowed.
     *
     * @dev In a full ACE implementation, this would evaluate a chain of policies
     *      (blacklist, volume limits, KYC attestation, etc.) via a PolicyEngine.
     *      This stub only checks the blacklist.
     */
    function isCompliant(
        address from,
        address to,
        uint256, /* amount */
        bytes calldata /* context */
    ) external view returns (bool) {
        if (blacklisted[from]) return false;
        if (blacklisted[to]) return false;
        return true;
    }
}
