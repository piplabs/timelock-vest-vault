// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { IStakeRewardReceiver } from "./interfaces/IStakeRewardReceiver.sol";
import { ITimelockVestVault } from "./interfaces/ITimelockVestVault.sol";
import { IIPTokenStaking } from "./interfaces/IIPTokenStaking.sol";

error CallerIsNotVault();

/// @title StakeRewardReceiver
/// @notice Receives and tracks staking rewards for a beneficiary.
contract StakeRewardReceiver is IStakeRewardReceiver {
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

    receive() external payable {}

    /// @notice Transfers reward tokens to given address
    /// @dev the function can only be called by the vault
    /// @param amount The amount of tokens to transfer
    function transferReward(address to, uint256 amount) external override onlyVault {
        Address.sendValue(payable(to), amount);
        emit RewardTokensTransferred(address(this), to, amount);
    }

    /// @notice return the beneficiary address (hashed) associated with this receiver
    function getBeneficiary() external view override returns (bytes32) {
        return BENEFICIARY;
    }

    /// @notice return the vault address associated with this receiver
    function getVault() external view override returns (address) {
        return VAULT;
    }
}
