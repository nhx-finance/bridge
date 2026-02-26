// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IExtractor} from "@chainlink/policy-management/interfaces/IExtractor.sol";
import {IPolicyEngine} from "@chainlink/policy-management/interfaces/IPolicyEngine.sol";

/**
 * @title KESYExtractor
 * @notice ACE parameter extractor for wKESY token operations.
 * @dev Handles four function selectors:
 *   - transfer(address to, uint256 amount)
 *   - transferFrom(address from, address to, uint256 amount)
 *   - mint(address to, uint256 amount)
 *   - burnFrom(address account, uint256 amount)
 *
 * Extracts `account` and `amount` parameters using keccak256 naming convention.
 * Policies like AddressBlacklistPolicy check `account`, VolumePolicy checks `amount`.
 */
contract KESYExtractor is IExtractor {
    string public constant override typeAndVersion = "KESYExtractor 1.0.0";

    /// @notice keccak256("account") — used by blacklist policy
    bytes32 public constant PARAM_ACCOUNT = keccak256("account");

    /// @notice keccak256("amount") — used by volume policy
    bytes32 public constant PARAM_AMOUNT = keccak256("amount");

    // ─── Function selectors ─────────────────────────────────────────────

    // transfer(address,uint256)
    bytes4 private constant TRANSFER_SELECTOR = 0xa9059cbb;
    // transferFrom(address,address,uint256)
    bytes4 private constant TRANSFER_FROM_SELECTOR = 0x23b872dd;
    // mint(address,uint256)
    bytes4 private constant MINT_SELECTOR = 0x40c10f19;
    // burnFrom(address,uint256)
    bytes4 private constant BURN_FROM_SELECTOR = 0x79cc6790;

    /**
     * @inheritdoc IExtractor
     * @dev Extracts account and amount from wKESY operations:
     *
     * | Selector       | account      | amount   |
     * |----------------|--------------|----------|
     * | transfer       | to           | amount   |
     * | transferFrom   | to           | amount   |
     * | mint           | to           | amount   |
     * | burnFrom       | account      | amount   |
     */
    function extract(IPolicyEngine.Payload calldata payload)
        external
        pure
        override
        returns (IPolicyEngine.Parameter[] memory)
    {
        address account;
        uint256 amount;

        if (payload.selector == TRANSFER_SELECTOR) {
            // transfer(address to, uint256 amount)
            (account, amount) = abi.decode(payload.data, (address, uint256));
        } else if (payload.selector == TRANSFER_FROM_SELECTOR) {
            // transferFrom(address from, address to, uint256 amount)
            // Check the `to` address for compliance (recipient)
            (, account, amount) = abi.decode(payload.data, (address, address, uint256));
        } else if (payload.selector == MINT_SELECTOR) {
            // mint(address to, uint256 amount)
            (account, amount) = abi.decode(payload.data, (address, uint256));
        } else if (payload.selector == BURN_FROM_SELECTOR) {
            // burnFrom(address account, uint256 amount)
            (account, amount) = abi.decode(payload.data, (address, uint256));
        } else {
            revert IPolicyEngine.UnsupportedSelector(payload.selector);
        }

        IPolicyEngine.Parameter[] memory result = new IPolicyEngine.Parameter[](2);
        result[0] = IPolicyEngine.Parameter(PARAM_ACCOUNT, abi.encode(account));
        result[1] = IPolicyEngine.Parameter(PARAM_AMOUNT, abi.encode(amount));

        return result;
    }
}
