// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
interface ITimelockVestVault {
    /// @notice The struct that defines the unlocking schedule
    /// start: The start time of the unlocking schedule
    /// durationMonths: The duration of the unlocking schedule in months
    /// end: The end time of the unlocking schedule
    /// cliff: The cliff time of the unlocking schedule
    /// cliffMonths: The cliff duration of the unlocking schedule in months
    /// cliffPercentage: The percentage of tokens that can be claimed at the cliff. 10000 = 100%
    struct UnlockingSchedule {
        uint64 start;
        uint64 durationMonths;
        uint64 end;
        uint64 cliff;
        uint64 cliffMonths;
        uint64 cliffPercentage;
    }

    // Events
    /// @notice Emitted when unlocked tokens are claimed
    /// @param beneficiary The address of the beneficiary
    /// @param amount The amount of unlocked tokens claimed
    event UnlockedTokensClaimed(bytes32 indexed beneficiary, uint256 amount);

    /// @notice Emitted when locked tokens are staked
    /// @param beneficiary The address of the beneficiary
    /// @param validator The address of the validator
    /// @param amount The amount of locked tokens staked
    event LockedTokensStaked(bytes32 indexed beneficiary, bytes validator, uint256 amount);

    /// @notice Emitted when locked tokens are unstaked
    /// @param beneficiary The address of the beneficiary
    /// @param validator The address of the validator
    /// @param amount The amount of locked tokens unstaked
    event LockedTokensUnstakeRequested(bytes32 indexed beneficiary, bytes validator, uint256 amount);

    /// @notice Emitted when staking rewards are claimed
    /// @param beneficiary The address of the beneficiary
    /// @param amount The amount of staking rewards claimed
    event StakingRewardsClaimed(bytes32 indexed beneficiary, uint256 amount);

    receive() external payable;

    // Functions
    /// @notice claim unlocked tokens from vault to the caller, the caller should be a beneficiary
    /// @param amount The amount of unlocked tokens to claim
    function claimUnlockedTokens(uint256 amount) external;

    /// @notice Stake locked tokens
    /// @param amount The amount of locked tokens to stake
    /// @param validator The address of the validator
    function stakeLockedTokens(uint256 amount, bytes calldata validator) external;

    /// @notice Unstake locked tokens
    /// @param amount The amount of locked tokens to unstake
    /// @param validator The address of the validator
    function unstakeLockedTokens(uint256 amount, bytes calldata validator) external;

    /// @notice Claims the staking rewards
    /// @param amount The amount of staking rewards to claim
    function claimStakingRewards(uint256 amount) external;

    /// @notice Returns the amount of unlocked tokens for a beneficiary at a given timestamp
    /// @param timestamp The timestamp to check the unlocked amount
    /// @return unlockedAmount The amount of unlocked tokens
    function getUnlockedAmount(uint64 timestamp) external view returns (uint256 unlockedAmount);

    /// @notice Returns the amount of claimable rewards for a beneficiary,
    /// The staking rewards will be locked for the first 6 months.
    /// After the first 6 months block rewards withheld, all block rewards are unlocked.
    /// @return The amount of claimable rewards
    function claimableStakingRewards() external view returns (uint256);

    /// @notice Returns the amount of claimable unlocked tokens for a beneficiary
    /// @return The amount of claimable unlocked tokens
    function claimableUnlockedTokens() external view returns (uint256);

    /// @notice Returns unlocking schedule of the caller (beneficiary)
    /// which includes start, end, cliff and monthly unlocking
    /// @return UnlockingSchedule struct
    function getUnlockingSchedule() external view returns (UnlockingSchedule memory);

    /// @notice Returns the start time of the vesting and unlocking schedule
    /// @return timestamp
    function getStartTime() external view returns (uint64 timestamp);

    /// @notice Returns the staking reward claimable start time
    /// @return timestamp
    function getStakingRewardClaimableStartTime() external view returns (uint64 timestamp);


    /// @notice Returns the total amount of stakeable tokens for a beneficiary
    /// @return The amount of stakeable tokens
    function getStakeableAmount() external view returns (uint256);


    /// @notice get StakeRewardReceiver address for the beneficiary
    /// @return The address of the StakeRewardReceiver contract associate with the beneficiary
    function getStakeRewardReceiverAddress() external view returns (address);
}
