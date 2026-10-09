// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IComplianceRegistry} from "./interfaces/IPairwise.sol";

/// @title ComplianceRegistry
/// @notice Pluggable allowlist hook. OFF by default: while disabled every account is allowed.
///         When enabled (Timelock decision), vault deposits/mints, vault-share transfers, staking and pair proposals
///         require the account to be allowlisted. Withdrawals are deliberately never gated.
contract ComplianceRegistry is AccessControl, IComplianceRegistry {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    uint256 public constant MAX_BATCH = 200;

    bool public enabled;
    mapping(address account => bool) public allowlisted;

    event EnabledSet(bool enabled);
    event AllowlistSet(address indexed account, bool allowed);

    error BatchTooLarge();

    constructor(address admin, address complianceOfficer) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, complianceOfficer);
    }

    function setEnabled(bool enabled_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = enabled_;
        emit EnabledSet(enabled_);
    }

    function setAllowlisted(address[] calldata accounts, bool allowed) external onlyRole(COMPLIANCE_ROLE) {
        if (accounts.length > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < accounts.length; ++i) {
            allowlisted[accounts[i]] = allowed;
            emit AllowlistSet(accounts[i], allowed);
        }
    }

    function isAllowed(address account) external view returns (bool) {
        return !enabled || allowlisted[account];
    }
}
