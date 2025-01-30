// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IStakeAgent } from "./interfaces/IStakeAgent.sol";
import { IIPTokenStaking } from "./interfaces/IIPTokenStaking.sol";

error CallerIsNotVault();

///
/// @title StakeAgent
/// @notice This contract represents a beneficiary's agent to stake on their behalf
///         and receive any unstaked tokens. It references a vault to handle token
///         distribution and calls IPTokenStaking for actual stake operations.
contract StakeAgent is IStakeAgent {
    bytes32 private immutable BENEFICIARY;
    address private immutable VAULT;
    IIPTokenStaking private immutable STAKING_CONTRACT;

    modifier onlyVault() {
        if (msg.sender != VAULT) revert CallerIsNotVault();
        _;
    }

    constructor(bytes32 _beneficiary, address _vault, address _stakingContract) {
        BENEFICIARY = _beneficiary;
        VAULT = _vault;
        STAKING_CONTRACT = IIPTokenStaking(_stakingContract);
    }

    /// @notice Transfers tokens to the vault
    /// @dev the function can only be called by the vault
    /// @param amount The amount of tokens to transfer
    function transferToVault(uint256 amount) external override onlyVault {
        Address.sendValue(payable(VAULT), amount);
        emit UnstakedTokensTransferredToVault(address(this), VAULT, amount);
    }

    /// @notice set the unstake receiver address in IPStaking contract
    /// @dev the function can only be called by the vault
    function setUnstakeReceiverAddress(address unstakeReceiver) external override onlyVault {
        STAKING_CONTRACT.setWithdrawalAddress(unstakeReceiver);
        emit UnstakeReceiverAddressSet(BENEFICIARY, unstakeReceiver);
    }

    /// @notice set the reward receiver address in IPStaking contract
    /// @dev the function can only be called by the vault
    function setRewardReceiverAddress(address rewardReceiver) external override onlyVault {
        STAKING_CONTRACT.setRewardsAddress(rewardReceiver);
        emit RewardReceiverAddressSet(BENEFICIARY, rewardReceiver);
    }

    /// @notice set the operator address of this StakeAgent in IPStaking contract
    /// @dev the function can only be called by the vault
    /// @param _operator The address of the operator
    function setOperator(address _operator) external override onlyVault {
        STAKING_CONTRACT.setOperator(_operator);
    }

    /// @notice return the beneficiary address (hashed) associated with this StakeAgent
    /// @return The beneficiary address
    function getBeneficiary() external view override returns (bytes32) {
        return BENEFICIARY;
    }

    /// @notice return the vault address associated with this StakeAgent
    /// @return The vault address
    function getVault() external view override returns (address) {
        return VAULT;
    }

    /// @notice return the staking contract associated with this StakeAgent
    /// @return The staking contract address
    function getStakingContract() external view returns (address) {
        return address(STAKING_CONTRACT);
    }
}
