// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title PairwiseTimelock
/// @notice Holds DEFAULT_ADMIN_ROLE on every Pairwise contract after deployment. Minimum delay is 48 hours and can
///         only be changed by the timelock itself (i.e. through another 48h-delayed operation).
///         The timelock is self-administered (no external admin).
contract PairwiseTimelock is TimelockController {
    uint256 public constant MIN_DELAY = 48 hours;

    error DelayTooShort();

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors)
        TimelockController(minDelay, proposers, executors, address(0))
    {
        if (minDelay < MIN_DELAY) revert DelayTooShort();
    }
}
