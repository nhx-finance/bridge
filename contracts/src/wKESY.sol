// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {PolicyProtected} from "@chainlink/policy-management/core/PolicyProtected.sol";

/**
 * @title wKESY — Wrapped KESY Token (ACE-Protected)
 * @dev ERC-20 representation of KESY on EVM spokes, protected by Chainlink ACE.
 *
 * Key properties:
 *   - 6 decimals (matches native HTS KESY)
 *   - MINTER_ROLE / BURNER_ROLE restricted to the KESYOmniBridge
 *   - ACE PolicyProtected: transfer(), transferFrom(), mint(), and burnFrom()
 *     are all gated by the `runPolicy()` modifier. The PolicyEngine runs all
 *     attached policies (e.g. AddressBlacklistPolicy, VolumePolicy) before
 *     allowing the operation.
 *
 * Enforcement points:
 *   - User-initiated transfers: ERC20TransferExtractor
 *   - Bridge-initiated mints/burns: KESYExtractor
 *   - Both flow through the same PolicyEngine
 */
contract wKESY is ERC20, ERC20Burnable, AccessControl, PolicyProtected {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /**
     * @param _policyEngine Address of the deployed ACE PolicyEngine (proxy).
     */
    constructor(
        address _policyEngine
    ) ERC20("Wrapped KESY", "wKESY") PolicyProtected(msg.sender, _policyEngine) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // ─── ACE-Protected ERC-20 Operations ────────────────────────────────

    /**
     * @dev ACE-gated transfer. PolicyEngine evaluates all policies attached
     *      to this contract + transfer selector before allowing execution.
     */
    function transfer(address to, uint256 amount) public override runPolicy returns (bool) {
        return super.transfer(to, amount);
    }

    /**
     * @dev ACE-gated transferFrom.
     */
    function transferFrom(address from, address to, uint256 amount) public override runPolicy returns (bool) {
        return super.transferFrom(from, to, amount);
    }

    /**
     * @dev ACE-gated mint. Only MINTER_ROLE (the bridge) can call.
     *      PolicyEngine can reject if the recipient is blacklisted.
     */
    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) runPolicy {
        _mint(to, amount);
    }

    /**
     * @dev ACE-gated burnFrom. Only BURNER_ROLE (the bridge) can call.
     *      PolicyEngine can reject if the sender is blacklisted.
     */
    function burnFrom(address account, uint256 amount) public override onlyRole(BURNER_ROLE) runPolicy {
        super.burnFrom(account, amount);
    }

    // ─── Inheritance Resolution ─────────────────────────────────────────

    /**
     * @dev ERC165 supportsInterface — resolve diamond inheritance between
     *      AccessControl and PolicyProtected (both inherit ERC165).
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl, PolicyProtected)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
