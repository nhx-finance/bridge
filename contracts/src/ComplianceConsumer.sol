// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RejectPolicy} from "@chainlink/policy-management/policies/RejectPolicy.sol";

/**
 * @title ComplianceConsumer
 * @notice Middleware contract between CRE Forwarder and ACE RejectPolicy.
 * @dev    The CRE DON delivers signed reports to this contract, which then
 *         calls rejectAddress() / unrejectAddress() on the RejectPolicy.
 *
 *         This contract MUST be the owner of the RejectPolicy, since those
 *         functions are onlyOwner. The deployer EOA retains admin control
 *         over this contract itself (can pause, update policy address, etc.).
 *
 * Architecture:
 *   CRE DON → Forwarder → ComplianceConsumer.processReport() → RejectPolicy.rejectAddress()
 */
contract ComplianceConsumer is Ownable {

    RejectPolicy public rejectPolicy;

    event ComplianceActionProcessed(address indexed account, bool rejected);
    event RejectPolicyUpdated(address indexed oldPolicy, address indexed newPolicy);

    error InvalidAction();

    constructor(address _rejectPolicy) Ownable(msg.sender) {
        rejectPolicy = RejectPolicy(_rejectPolicy);
    }

    // ================================================================
    // │                   CRE REPORT PROCESSING                       │
    // ================================================================

    /**
     * @notice Process a compliance report — reject or unreject an address.
     * @dev    This is the function the CRE Forwarder calls after delivering
     *         a DON-signed report. Anyone can call this, but it only does
     *         safe, bounded operations (reject/unreject on the RejectPolicy).
     *
     * @param account The address to reject or unreject
     * @param reject  true = add to reject list, false = remove from reject list
     */
    function processReport(address account, bool reject) external {
        if (reject) {
            rejectPolicy.rejectAddress(account);
        } else {
            rejectPolicy.unrejectAddress(account);
        }
        emit ComplianceActionProcessed(account, reject);
    }

    /**
     * @notice Batch process multiple compliance actions.
     * @param accounts Array of addresses to process
     * @param reject   true = reject all, false = unreject all
     */
    function batchProcessReport(address[] calldata accounts, bool reject) external {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (reject) {
                rejectPolicy.rejectAddress(accounts[i]);
            } else {
                rejectPolicy.unrejectAddress(accounts[i]);
            }
            emit ComplianceActionProcessed(accounts[i], reject);
        }
    }

    // ================================================================
    // │                           ADMIN                               │
    // ================================================================

    /**
     * @notice Update the RejectPolicy address (e.g., after policy upgrade).
     */
    function setRejectPolicy(address _newPolicy) external onlyOwner {
        address old = address(rejectPolicy);
        rejectPolicy = RejectPolicy(_newPolicy);
        emit RejectPolicyUpdated(old, _newPolicy);
    }

    /**
     * @notice Check if an address is currently rejected.
     */
    function isRejected(address account) external view returns (bool) {
        return rejectPolicy.addressRejected(account);
    }
}
