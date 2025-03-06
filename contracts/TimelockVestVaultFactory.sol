// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ITimelockVestVault } from "./interfaces/ITimelockVestVault.sol";
import { IValidatorWhitelist } from "./interfaces/IValidatorWhitelist.sol";
import { IIPTokenStaking } from "./interfaces/IIPTokenStaking.sol";
import { IStakeRewardReceiver } from "./interfaces/IStakeRewardReceiver.sol";
import { StakeRewardReceiver } from "./StakeRewardReceiver.sol";
import "./TimelockVestVault.sol";

/// @title TimelockVestVaultFactory
/// @notice Deploys new TimelockVestVault contracts with preset configuration parameters.
/// @dev Immutable values (such as staking contract, validator whitelist, vesting schedule settings, etc.)
///      are set at deployment of the factory and passed to each vault on creation.
contract TimelockVestVaultFactory {
    /// @notice The staking contract address used by each vault.
    address private immutable STAKING_CONTRACT;
    /// @notice The validator whitelist contract address.
    address private immutable VALIDATORS_WHITELIST;
    /// @notice Total number of months over which tokens will unlock.
    uint64 private immutable UNLOCK_DURATION_MONTHS;
    /// @notice Number of months in the cliff period.
    uint64 private immutable CLIFF_DURATION_MONTHS;
    /// @notice Percentage (expressed in basis points, e.g. 2500 = 25%) unlocked at the cliff.
    uint64 private immutable CLIFF_PERCENTAGE;
    /// @notice Timestamp from which staking rewards become claimable.
    uint64 private immutable STAKING_REWARD_START;

    /// @notice Emitted when a new vault is deployed.
    /// @param creator The address that triggered the vault creation.
    /// @param beneficiary The beneficiary hash set for the vault.
    /// @param allocation The token allocation for the vault.
    /// @param vault The deployed TimelockVestVault contract address.
    event VaultCreated(address indexed creator, bytes32 indexed beneficiary, uint256 allocation, address vault);

    struct VaultFactoryConfig {
        address stakingContract;
        address validatorsWhitelist;
        uint64 unlockDurationMonths;
        uint64 cliffDurationMonths;
        uint64 cliffPercentage;
        uint64 stakingRewardStart;
    }

    error ZeroStakingContract();
    error ZeroValidatorsWhitelist();

    /// @notice Constructor sets the immutable parameters that will be passed to each vault.
    /// @param _stakingContract The address of the staking contract.
    /// @param _validatorsWhitelist The address of the validator whitelist contract.
    /// @param _unlockDurationMonths Total unlock duration in months.
    /// @param _cliffDurationMonths Cliff duration in months.
    /// @param _cliffPercentage Percentage (in basis points) unlocked at cliff.
    /// @param _stakingRewardStart Timestamp when staking rewards become claimable.
    constructor(
        address _stakingContract,
        address _validatorsWhitelist,
        uint64 _unlockDurationMonths,
        uint64 _cliffDurationMonths,
        uint64 _cliffPercentage,
        uint64 _stakingRewardStart
    ) {
        if (_stakingContract == address(0)) revert ZeroStakingContract();
        if (_validatorsWhitelist == address(0)) revert ZeroValidatorsWhitelist();
        STAKING_CONTRACT = _stakingContract;
        VALIDATORS_WHITELIST = _validatorsWhitelist;
        UNLOCK_DURATION_MONTHS = _unlockDurationMonths;
        CLIFF_DURATION_MONTHS = _cliffDurationMonths;
        CLIFF_PERCENTAGE = _cliffPercentage;
        STAKING_REWARD_START = _stakingRewardStart;
    }

    /// @notice Deploys a new TimelockVestVault with the specified beneficiary and allocation.
    /// @dev The function is payable. Any Ether sent will be forwarded to the vault contract.
    /// @param beneficiary The beneficiary as a bytes32 hash.
    /// @param allocation The token allocation for the vault.
    /// @return vaultAddress The address of the deployed TimelockVestVault contract.
    function createVault(bytes32 beneficiary, uint256 allocation) external payable returns (address vaultAddress) {
        // Deploy a new vault passing the immutable configuration along with the provided parameters.
        TimelockVestVault vault = new TimelockVestVault{ value: msg.value }(
            STAKING_CONTRACT,
            VALIDATORS_WHITELIST,
            UNLOCK_DURATION_MONTHS,
            CLIFF_DURATION_MONTHS,
            CLIFF_PERCENTAGE,
            STAKING_REWARD_START,
            beneficiary,
            allocation
        );
        vaultAddress = address(vault);

        emit VaultCreated(msg.sender, beneficiary, allocation, vaultAddress);
    }

    /// @notice Returns the immutable configuration parameters of the factory.
    /// @return config The configuration parameters of the factory.
    /// @dev This function is view and does not modify the state.
    function getFactoryParameters() external view returns (VaultFactoryConfig memory) {
        return
            VaultFactoryConfig({
                stakingContract: STAKING_CONTRACT,
                validatorsWhitelist: VALIDATORS_WHITELIST,
                unlockDurationMonths: UNLOCK_DURATION_MONTHS,
                cliffDurationMonths: CLIFF_DURATION_MONTHS,
                cliffPercentage: CLIFF_PERCENTAGE,
                stakingRewardStart: STAKING_REWARD_START
            });
    }

    /// @notice Generates a hash of the beneficiary address.
    /// @param beneficiaryAddress The address of the beneficiary.
    /// @return beneficiaryHash The hash of the beneficiary address.
    function toHash(address beneficiaryAddress) external pure returns (bytes32 beneficiaryHash) {
        return keccak256(abi.encodePacked(beneficiaryAddress));
    }

    /// @notice Validates the beneficiary address against the provided hash.
    /// @param beneficiaryAddress The address of the beneficiary.
    /// @param beneficiaryHash The hash of the beneficiary address.
    /// @return isValid True if the address matches the hash, false otherwise.
    function validateHash(address beneficiaryAddress, bytes32 beneficiaryHash) external pure returns (bool isValid) {
        return keccak256(abi.encodePacked(beneficiaryAddress)) == beneficiaryHash;
    }
}
