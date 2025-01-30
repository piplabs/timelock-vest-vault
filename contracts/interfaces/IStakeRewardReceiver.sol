// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IStakeRewardReceiver
/// @notice Interface for StakeRewardReceiver. one beneficiary has one StakeRewardReceiver.
/// it is used to receive the staking rewards of the beneficiary
interface IStakeRewardReceiver {
    // Events
    /// @notice Emitted when tokens are transferred
    event RewardTokensTransferred(address indexed from, address indexed to, uint256 amount);

    /// @notice Emitted when reward tokens are received
    event RewardTokensReceived(bytes32 indexed beneficiary, uint256 amount);

    // Functions
    /// @notice Transfers reward tokens to given address
    /// @dev the function can only be called by the vault
    /// @param amount The amount of tokens to transfer
    function transferReward(address to, uint256 amount) external;

    /// @notice return the beneficiary address (hashed) associated with this receiver
    function getBeneficiary() external view returns (bytes32);

    /// @notice return the vault address associated with this receiver
    function getVault() external view returns (address);
}