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

interface IIPTokenStakingWithFee is IIPTokenStaking {
    function fee() external view returns (uint256);
}

///  @title TimelockVestVault
///  @notice Manages time-locked allocations, unlocking logic, and staking of locked tokens.
///  @dev The contract is designed to track following data for each beneficiary:
///  allocation -> allocation of the beneficiary
///  unlocked   -> unlocking schedule of the beneficiary
///  whithdrawn -> total amount of tokens withdrawn by the beneficiary
contract TimelockVestVault is ITimelockVestVault, ReentrancyGuardTransient {
    uint256 public constant HUNDRED_PERCENT = 10000; // 100%
    uint64 private constant START_TIME = 1739404800; // 2025-02-13 00:00:00 UTC

    // Reference to the deployed IPTokenStaking contract
    IIPTokenStakingWithFee private immutable stakingContract;

    // Reference to the validator whitelist
    IValidatorWhitelist private immutable whitelist;

    UnlockingSchedule private unlocking;

    uint64 private immutable stakingRewardStartTime;

    // Beneficiary address hashed
    bytes32 private beneficiary;

    // Allocation of the beneficiary
    uint256 private allocation;

    // Total amount of tokens withdrawn by the beneficiary
    uint256 private withdrawn;

    // address of the StakeRewardReceiver contract
    IStakeRewardReceiver private stakingRewardReceiver;

    // Custom errors
    error NotBeneficiary();
    error TokensNotUnlockedYet();
    error AmountMustBeGreaterThanZero();
    error NotEnoughUnlockedTokens(uint256 amount, uint256 claimable);
    error NotEnoughWithdrawableTokens(uint256 amount, uint256 withdrawable);
    error ValidatorNotWhitelisted();
    error InsufficientBalanceInVault();
    error StakingRewardsNotClaimableYet();
    error IncorrectFeeAmount();
    error NotEnoughStakingRewardToken(uint256 amount, uint256 claimable);

    modifier onlyBeneficiary() {
        if (_toHash(msg.sender) != beneficiary) {
            revert NotBeneficiary();
        }
        _;
    }

    // Constructor can be designed to set up schedules & references
    /// @param _stakingContract The address of the staking contract
    /// @param _validatorWhitelist The address of the validator whitelist contract
    /// @param _unlockDurationMonths The duration of the unlocking schedule in months
    /// @param _cliffDurationMonths The duration of the cliff period in months
    /// @param _cliffPercentage The percentage of tokens to be unlocked at the cliff
    /// @param _stakingRewardStart The start time of can claim staking reward
    /// @param _beneficiary The address of the beneficiary
    /// @param _allocation The allocation of the beneficiary
    constructor(
        address _stakingContract,
        address _validatorWhitelist,
        uint64 _unlockDurationMonths,
        uint64 _cliffDurationMonths,
        uint64 _cliffPercentage,
        uint64 _stakingRewardStart,
        bytes32 _beneficiary,
        uint256 _allocation
    ) payable {
        stakingContract = IIPTokenStakingWithFee(_stakingContract);
        whitelist = IValidatorWhitelist(_validatorWhitelist);

        unlocking = UnlockingSchedule({
            start: START_TIME,
            durationMonths: _unlockDurationMonths,
            end: getEndTimestamp(_unlockDurationMonths),
            cliff: getEndTimestamp(_cliffDurationMonths),
            cliffMonths: _cliffDurationMonths,
            cliffPercentage: _cliffPercentage
        });

        stakingRewardStartTime = _stakingRewardStart;

        beneficiary = _beneficiary;
        allocation = _allocation;
        stakingRewardReceiver = new StakeRewardReceiver(_beneficiary, address(this), address(stakingContract));
        stakingContract.setRewardsAddress{ value: stakingContract.fee() }(address(stakingRewardReceiver));
    }

    receive() external payable {}

    /// @notice withdraw unlocked tokens from vault to the caller, the caller should be a beneficiary
    /// all balance in the vault is withdrawable after unlock duration
    /// @param amount The amount of unlocked tokens to withdraw
    function withdrawUnlockedTokens(uint256 amount) external override onlyBeneficiary nonReentrant {
        if (block.timestamp < unlocking.cliff) revert TokensNotUnlockedYet();
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        uint256 withdrawable = _withdrawableUnlockedTokens(beneficiary);
        if (withdrawable < amount) revert NotEnoughWithdrawableTokens(amount, withdrawable);

        if (address(this).balance < amount) {
            revert NotEnoughUnlockedTokens(amount, address(this).balance);
        }
        withdrawn += amount;
        emit UnlockedTokensWithdrawn(beneficiary, amount);

        // Transfer the unlocked tokens to the beneficiary
        Address.sendValue(payable(msg.sender), amount);
    }

    /// @notice Stake tokens
    /// @param amount The amount of tokens to stake
    /// @param validator The address of the validator
    function stakeTokens(uint256 amount, bytes calldata validator) external override onlyBeneficiary nonReentrant {
        if (!whitelist.isValidatorWhitelisted(validator)) revert ValidatorNotWhitelisted();
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        if (address(this).balance < amount) revert InsufficientBalanceInVault();

        emit TokensStaked(beneficiary, validator, amount);
        stakingContract.stake{ value: amount }(validator, IIPTokenStaking.StakingPeriod.FLEXIBLE, "");
    }

    /// @notice Unstake tokens
    /// @param amount The amount of tokens to unstake
    /// @param validator The address of the validator
    function unstakeTokens(
        uint256 amount,
        bytes calldata validator
    ) external payable override onlyBeneficiary nonReentrant {
        if (amount == 0) revert AmountMustBeGreaterThanZero();
        // Retrieve the fee required by the staking contract.
        uint256 fee = stakingContract.fee();
        // Verify that the caller provided the exact fee.
        if (msg.value != fee) revert IncorrectFeeAmount();
        // delegation id is 0 for flexible staking
        stakingContract.unstake{ value: fee }(validator, 0, amount, "");
        // Record the unstake request
        emit TokensUnstakeRequested(beneficiary, validator, amount);
    }

    /// @notice Claims the staking rewards
    /// @param amount The amount of staking rewards to claim
    function claimStakingRewards(uint256 amount) external override onlyBeneficiary nonReentrant {
        if (block.timestamp < stakingRewardStartTime) revert StakingRewardsNotClaimableYet();
        // load balance into memory
        uint256 claimable = address(stakingRewardReceiver).balance;
        if (claimable < amount) revert NotEnoughStakingRewardToken(amount, claimable);
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        stakingRewardReceiver.transferReward(msg.sender, amount);
        emit StakingRewardsClaimed(beneficiary, amount);
    }

    /// @notice Returns the amount of withdrawable unlocked tokens for a beneficiary
    /// @return The amount of withdrawable unlocked tokens
    function withdrawableUnlockedTokens() external view override returns (uint256) {
        return _withdrawableUnlockedTokens(beneficiary);
    }

    /// @notice Returns the amount of unlocked tokens for a beneficiary at a given timestamp
    /// @param timestamp The timestamp to check the unlocked amount
    /// @return unlockedAmount The amount of unlocked tokens
    function getUnlockedAmount(uint64 timestamp) external view override returns (uint256 unlockedAmount) {
        return _getUnlockedAmount(beneficiary, timestamp);
    }

    /// @notice Returns the amount of claimable rewards for a beneficiary,
    /// The staking rewards will be locked for the first 6 months.
    /// After the first 6 months block rewards withheld, all block rewards are unlocked.
    /// @return The amount of claimable rewards
    function claimableStakingRewards() external view override returns (uint256) {
        if (block.timestamp < stakingRewardStartTime) {
            return 0;
        }
        return address(stakingRewardReceiver).balance;
    }

    /// @notice Returns unlocking schedule of the caller (beneficiary)
    /// which includes start, end, cliff and monthly unlocking
    /// @return UnlockingSchedule struct
    function getUnlockingSchedule() external view override returns (UnlockingSchedule memory) {
        return unlocking;
    }

    /// @notice Returns the start time of the vesting and unlocking schedule
    /// @return timestamp
    function getStartTime() external view override returns (uint64 timestamp) {
        return unlocking.start;
    }

    /// @notice Returns the staking reward claimable start time
    /// @return timestamp
    function getStakingRewardClaimableStartTime() external view override returns (uint64 timestamp) {
        return stakingRewardStartTime;
    }

    /// @notice get StakeRewardReceiver address for the beneficiary
    /// @return The address of the StakeRewardReceiver contract associate with the beneficiary
    function getStakeRewardReceiverAddress() external view returns (address) {
        return address(stakingRewardReceiver);
    }

    /// @notice Get the end timestamp of from START_TIME after durationMonths.
    /// @dev example:
    /// from 2025-02-13 after 1 month is 2025-03-13  (28 days)
    /// from 2025-02-13 after 2 month is 2025-04-13  (31 days + 28 days)
    /// @param durationMonths The duration in months
    /// @return endTimestamp The end timestamp
    function getEndTimestamp(uint64 durationMonths) public view returns (uint64 endTimestamp) {
        uint8[48] memory MONTH_DURATIONS = _getMonthDurations();
        endTimestamp = START_TIME;
        for (uint64 i = 0; i < durationMonths; i++) {
            endTimestamp += MONTH_DURATIONS[i] * 1 days;
        }
    }

    /// @dev get elapsed months since START_TIME to the timestamp
    /// @return elapsedMonths The elapsed months
    function getElapsedMonths(uint64 timestamp) public pure returns (uint64 elapsedMonths) {
        uint8[48] memory MONTH_DURATIONS = _getMonthDurations();
        elapsedMonths = 0;
        uint64 endTimestamp = START_TIME;
        for (uint64 i = 0; i < MONTH_DURATIONS.length; i++) {
            endTimestamp += MONTH_DURATIONS[i] * 1 days;
            if (endTimestamp <= timestamp) {
                elapsedMonths += 1;
            } else {
                break;
            }
        }
    }

    /// @dev Returns the amount of claimable unlocked tokens for a beneficiary,
    /// all balance in the vault is withdrawable after unlock duration
    /// @param beneficiary The address of the beneficiary
    function _withdrawableUnlockedTokens(bytes32 beneficiary) internal view returns (uint256 withdrawable) {
        // all balance in the vault is withdrawable after unlock duration
        if (block.timestamp >= unlocking.end) {
            return address(this).balance;
        }
        // formular: withdrawable = min[(unlocked - withdrawn), balance]
        uint256 unlockedSoFar = _getUnlockedAmount(beneficiary, uint64(block.timestamp));
        withdrawable = Math.min(unlockedSoFar - withdrawn, address(this).balance);
    }

    /// @dev Returns the amount of unlocked tokens for a beneficiary at a given timestamp
    /// The formula is based on the configurable cliff and monthly unlock percentage.
    /// @param beneficiary The address of the beneficiary
    /// @param timestamp The timestamp to check the unlocked amount
    /// @return unlockedAmount The amount of unlocked tokens
    function _getUnlockedAmount(bytes32 beneficiary, uint64 timestamp) internal view returns (uint256 unlockedAmount) {
        if (timestamp < unlocking.cliff) {
            return 0;
        }
        // load allocation into memory
        uint256 alloc = allocation;
        if (alloc == 0) {
            return 0;
        }

        if (timestamp >= unlocking.end) {
            // Fully unlocked
            return alloc;
        }

        uint64 durationMonthsAfterCliff = unlocking.durationMonths - unlocking.cliffMonths;
        uint256 elapsedMonthsAfterCliff = getElapsedMonths(timestamp) - unlocking.cliffMonths;
        // unlockedAmount = cliff unlock + monthly unlock * elapsed months after cliff
        //   unlockedAmount = (alloc * unlocking.cliffPercentage) / 100 +
        //      (alloc * (100 - unlocking.cliffPercentage) / 100) / durationMonthsAfterCliff * elapsedMonthsAfterCliff;
        // example:
        // unlockedAmount = (alloc * 25) / 100 + ((alloc * 75) / 100) / durationMonthsAfterCliff *
        //    elapsedMonthsAfterCliff
        // Multiply by durationMonthsAfterCliff before dividing to mitigate precision loss from rounding.
        // unlockedAmount is calculated as:
        // unlockedAmount = ((alloc * 25 * durationMonthsAfterCliff) + (alloc * 75 * elapsedMonthsAfterCliff)) /
        //    (durationMonthsAfterCliff * 100);
        // Although the formula can be simplified by factoring out 'alloc', it remains expanded for clarity.
        unlockedAmount =
            ((alloc * unlocking.cliffPercentage * durationMonthsAfterCliff) +
                (alloc * (HUNDRED_PERCENT - unlocking.cliffPercentage) * elapsedMonthsAfterCliff)) /
            (durationMonthsAfterCliff * HUNDRED_PERCENT);

        if (unlockedAmount > alloc) {
            unlockedAmount = alloc;
        }
    }

    /// @dev define an array of month durations for 2025-2029, 2025-01-01 is month 1, 2026-01-01 is month 13
    /// @return MONTH_DURATIONS The array of month durations
    function _getMonthDurations() internal pure returns (uint8[48] memory) {
        // Start from 2025 Feb. 2025-02 is month 0, 2026-01 is month 11
        uint8[48] memory MONTH_DURATIONS = [
                    28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
                    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
                    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
                    31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
                    31
            ];
        return MONTH_DURATIONS;
    }

    function _toHash(address addr) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(addr));
    }
}
