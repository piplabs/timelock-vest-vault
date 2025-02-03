// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IStakeAgent
/// @notice Interface for StakeAgent. one beneficiary has one StageAgent. it stake token on behalf of beneficiary.
/// the contract is also unstaked locked token receiver which receives unstaked tokens for a beneficiary
interface IStakeAgent {
    // Events
    /// @notice Emitted when tokens are transferred to the vault
    event UnstakedTokensTransferredToVault(address indexed from, address indexed to, uint256 amount);

    /// @notice Emitted when the unstake receiver address is set
    event UnstakeReceiverAddressSet(bytes32 indexed beneficiary, address indexed unstakeReceiver);

    /// @notice Emitted when the reward receiver address is set
    event RewardReceiverAddressSet(bytes32 indexed beneficiary, address indexed rewardReceiver);

    receive() external payable;

    // Functions
    /// @notice Transfers tokens to the vault
    /// @dev the function can only be called by the vault
    /// @param amount The amount of tokens to transfer
    function transferToVault(uint256 amount) external;

    /// @notice set the unstake receiver address in IPStaking contract
    /// @dev the function can only be called by the vault
    function setUnstakeReceiverAddress(address unstakeReceiver) external payable;

    /// @notice set the reward receiver address in IPStaking contract
    /// @dev the function can only be called by the vault
    function setRewardReceiverAddress(address rewardReceiver) external payable;

    /// @notice return the beneficiary address (hashed) associated with this StakeAgent
    /// @return The beneficiary address
    function getBeneficiary() external view returns (bytes32);

    /// @notice return the vault address associated with this StakeAgent
    /// @return The vault address
    function getVault() external view returns (address);

    /// @notice set the operator address of this StakeAgent in IPStaking contract
    /// @dev the function can only be called by the vault
    /// @param _operator The address of the operator
    function setOperator(address _operator) external payable;

    /// @notice return the staking contract associated with this StakeAgent
    /// @return The staking contract address
    function getStakingContract() external view returns (address);
}