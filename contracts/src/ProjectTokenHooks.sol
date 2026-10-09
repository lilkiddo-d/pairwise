// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IProjectTokenHooks, IComplianceRegistry} from "./interfaces/IPairwise.sol";

/// @title ProjectTokenHooks
/// @notice Every $PAIR feature lives here and is inert until the Timelock calls `setProjectToken` (exactly once).
///         Pairwise does NOT deploy a token; $PAIR launches separately and is plugged in by address.
///         - Staking: stake $PAIR, earn a share of performance fees (USDG), streamed over REWARD_DURATION so
///           just-in-time stakers cannot snipe a harvest.
///         - Pair proposals: stakers above `proposalThreshold` can propose new pairs. Listing still requires a
///           Timelock transaction on PairVaultFactory; the proposal is an on-chain signal with a status.
contract ProjectTokenHooks is AccessControl, ReentrancyGuard, Pausable, IProjectTokenHooks {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant FEE_NOTIFIER_ROLE = keccak256("FEE_NOTIFIER_ROLE");

    uint256 public constant REWARD_DURATION = 7 days;
    uint256 public constant PROPOSAL_COOLDOWN = 1 days;
    uint256 public constant MAX_RATIONALE_BYTES = 1_024;

    enum ProposalStatus {
        NONE,
        OPEN,
        LISTED,
        REJECTED
    }

    struct Proposal {
        address proposer;
        address tokenA;
        address tokenB;
        uint64 createdAt;
        ProposalStatus status;
        string rationale;
    }

    IERC20 public immutable rewardToken; // USDG
    IERC20 public projectToken;
    IComplianceRegistry public compliance;

    uint256 public totalStaked;
    mapping(address => uint256) public staked;

    uint256 public rewardRate; // reward tokens per second, 1e18-scaled
    uint256 public periodFinish;
    uint256 public lastUpdate;
    uint256 public rewardPerTokenStored; // 1e36-scaled (reward units per staked wei)
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    uint256 public undistributed; // rewards notified while nobody staked (re-streamed on next notify)

    uint256 public proposalThreshold;
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(address => uint256) public lastProposalAt;

    event ProjectTokenSet(address indexed token);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);
    event RewardsNotified(uint256 amount, uint256 rewardRate, uint256 periodFinish);
    event PairProposed(
        uint256 indexed id, address indexed proposer, address tokenA, address tokenB, string rationale
    );
    event ProposalStatusSet(uint256 indexed id, ProposalStatus status);
    event ProposalThresholdSet(uint256 threshold);
    event ComplianceSet(address compliance);

    error TokenAlreadySet();
    error TokenNotSet();
    error BadParam();
    error BelowThreshold();
    error ProposalCooldown();
    error NotAllowed(address account);

    constructor(address admin, IERC20 rewardToken_, address guardian, uint256 proposalThreshold_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, guardian);
        rewardToken = rewardToken_;
        proposalThreshold = proposalThreshold_;
    }

    // ---------------------------------------------------------------- admin (Timelock)

    /// @notice One-shot: plugs in the externally launched $PAIR token. Until then every token feature reverts
    ///         or is skipped, and the protocol runs normally without it.
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(projectToken) != address(0)) revert TokenAlreadySet();
        if (token == address(0) || token.code.length == 0 || token == address(rewardToken)) revert BadParam();
        projectToken = IERC20(token);
        lastUpdate = block.timestamp;
        emit ProjectTokenSet(token);
    }

    function setProposalThreshold(uint256 threshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        proposalThreshold = threshold;
        emit ProposalThresholdSet(threshold);
    }

    function setProposalStatus(uint256 id, ProposalStatus status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (id == 0 || id > proposalCount || status == ProposalStatus.NONE) revert BadParam();
        proposals[id].status = status;
        emit ProposalStatusSet(id, status);
    }

    function setCompliance(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = IComplianceRegistry(registry);
        emit ComplianceSet(registry);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------- staking

    modifier tokenSet() {
        if (address(projectToken) == address(0)) revert TokenNotSet();
        _;
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdate = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function stake(uint256 amount) external nonReentrant whenNotPaused tokenSet updateReward(msg.sender) {
        if (amount == 0) revert BadParam();
        _checkAllowed(msg.sender);
        uint256 before = projectToken.balanceOf(address(this));
        projectToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = projectToken.balanceOf(address(this)) - before; // fee-on-transfer safe
        staked[msg.sender] += received;
        totalStaked += received;
        emit Staked(msg.sender, received);
    }

    /// @notice Never paused and never compliance-gated: users can always exit.
    function unstake(uint256 amount) external nonReentrant tokenSet updateReward(msg.sender) {
        if (amount == 0 || amount > staked[msg.sender]) revert BadParam();
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        projectToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claim() public nonReentrant updateReward(msg.sender) returns (uint256 reward) {
        reward = rewards[msg.sender];
        if (reward != 0) {
            rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// @inheritdoc IProjectTokenHooks
    function rewardsActive() external view returns (bool) {
        return address(projectToken) != address(0) && totalStaked != 0;
    }

    /// @inheritdoc IProjectTokenHooks
    function notifyRewards(uint256 amount) external nonReentrant onlyRole(FEE_NOTIFIER_ROLE) updateReward(address(0)) {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 total = amount + undistributed;
        undistributed = 0;
        if (totalStaked == 0) {
            undistributed = total;
            emit RewardsNotified(amount, rewardRate, periodFinish);
            return;
        }
        if (block.timestamp < periodFinish) {
            total += Math.mulDiv(periodFinish - block.timestamp, rewardRate, 1e18);
        }
        rewardRate = Math.mulDiv(total, 1e18, REWARD_DURATION);
        lastUpdate = block.timestamp;
        periodFinish = block.timestamp + REWARD_DURATION;
        emit RewardsNotified(amount, rewardRate, periodFinish);
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    // slither: incorrect-equality: exact-zero checks are early returns on empty positions/supply, not equality on attacker-controlled balances
    // slither-disable-start incorrect-equality
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        uint256 t = lastTimeRewardApplicable();
        if (t <= lastUpdate) return rewardPerTokenStored;
        return rewardPerTokenStored + Math.mulDiv((t - lastUpdate) * rewardRate, 1e18, totalStaked);
    }
    // slither-disable-end incorrect-equality

    function earned(address account) public view returns (uint256) {
        return rewards[account]
            + Math.mulDiv(staked[account], rewardPerToken() - userRewardPerTokenPaid[account], 1e36);
    }

    // ---------------------------------------------------------------- pair proposals

    function proposePair(address tokenA, address tokenB, string calldata rationale)
        external
        whenNotPaused
        tokenSet
        returns (uint256 id)
    {
        if (staked[msg.sender] < proposalThreshold || staked[msg.sender] == 0) revert BelowThreshold();
        _checkAllowed(msg.sender);
        if (tokenA == address(0) || tokenB == address(0) || tokenA == tokenB) revert BadParam();
        if (bytes(rationale).length > MAX_RATIONALE_BYTES) revert BadParam();
        uint256 last = lastProposalAt[msg.sender];
        if (last != 0 && block.timestamp < last + PROPOSAL_COOLDOWN) revert ProposalCooldown();
        lastProposalAt[msg.sender] = block.timestamp;
        id = ++proposalCount;
        proposals[id] = Proposal({
            proposer: msg.sender,
            tokenA: tokenA,
            tokenB: tokenB,
            createdAt: uint64(block.timestamp),
            status: ProposalStatus.OPEN,
            rationale: rationale
        });
        emit PairProposed(id, msg.sender, tokenA, tokenB, rationale);
    }

    function _checkAllowed(address account) internal view {
        IComplianceRegistry c = compliance;
        if (address(c) != address(0) && !c.isAllowed(account)) revert NotAllowed(account);
    }
}
