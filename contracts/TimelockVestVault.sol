// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
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
///  staked     -> total staked amount of the beneficiary
///  unstaked   -> balance of stakeAgent contract of the beneficiary
///  stakeable  -> allocation - staked - unlocked
contract TimelockVestVault is ITimelockVestVault, ReentrancyGuardTransient {
    uint256 public constant HUNDRED_PERCENT = 10000; // 100%
    uint64 private constant START_2025 = 1735689600; // 2025-01-01 00:00:00 UTC

    // Reference to the deployed IPTokenStaking contract
    IIPTokenStakingWithFee private immutable stakingContract;

    // Reference to the validator whitelist
    IValidatorWhitelist private immutable whitelist;

    UnlockingSchedule private unlocking;

    uint64 private immutable stakingRewardStartTime;

    bytes32 private beneficiary;

    uint256 private allocation;

    uint256 private claimed;

    // flag to indicate if all tokens are allocated
    bool private isTokenAllocated;

    // Custom errors
    error NotBeneficiary();
    error TokensNotUnlockedYet();
    error AmountMustBeGreaterThanZero();
    error NotEnoughUnlockedTokens(uint256 amount, uint256 claimable);
    error ValidatorNotWhitelisted();
    error InsufficientBalanceInVault();
    error NotEnoughStakedTokens();
    error StakeAgentAlreadyExists();
    error StakeRewardReceiverAlreadyExists();
    error InvalidInputLengths();
    error StakingRewardsNotClaimableYet();
    error VaultBalanceNotMatchAllocation(uint256 vaultBalance, uint256 allocation);

    modifier onlyBeneficiary() {
        if (_toHash(msg.sender) != beneficiary) {
            revert NotBeneficiary();
        }
        _;
    }

    // only allow the function to be called when all tokens are allocated
    modifier whenTokenAllocated() {
        if (!isTokenAllocated) {
            if (address(this).balance < allocation) {
                revert VaultBalanceNotMatchAllocation(address(this).balance, allocation);
            } else {
                isTokenAllocated = true;
            }
        }
        _;
    }

    // Constructor can be designed to set up schedules & references
    /// @param _stakingContract The address of the staking contract
    /// @param _validatorWhitelist The address of the validator whitelist contract
    /// @param _startTime The start time of the unlocking schedule
    /// @param _unlockDurationMonths The duration of the unlocking schedule in months
    /// @param _cliffDurationMonths The duration of the cliff period in months
    /// @param _cliffPercentage The percentage of tokens to be unlocked at the cliff
    /// @param _stakingRewardStart The start time of can claim staking reward
    /// @param _beneficiary The address of the beneficiary
    /// @param _allocation The allocation of the beneficiary
    constructor(
        address _stakingContract,
        address _validatorWhitelist,
        uint64 _startTime,
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
            start: _startTime,
            durationMonths: _unlockDurationMonths,
            end: getEndTimestamp(_startTime, _unlockDurationMonths),
            cliff: getEndTimestamp(_startTime, _cliffDurationMonths),
            cliffMonths: _cliffDurationMonths,
            cliffPercentage: _cliffPercentage
        });

        stakingRewardStartTime = _stakingRewardStart;

        beneficiary = _beneficiary;
        allocation = _allocation;
        IStakeRewardReceiver receiver = _createStakeRewardReceiver(_beneficiary);
        stakingContract.setWithdrawalAddress{ value: stakingContract.fee() }(address(this));
        stakingContract.setRewardsAddress{ value: stakingContract.fee() }(address(receiver));
    }

    receive() external payable {}

    /// @notice claim unlocked tokens from vault to the caller, the caller should be a beneficiary
    /// @param amount The amount of unlocked tokens to claim
    function claimUnlockedTokens(uint256 amount) external override onlyBeneficiary whenTokenAllocated nonReentrant {
        if (block.timestamp < unlocking.cliff) {
            revert TokensNotUnlockedYet();
        }
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        uint256 claimable = _claimableUnlockedTokens(beneficiary);
        if (claimable < amount) {
            revert NotEnoughUnlockedTokens(amount, claimable);
        }

        if (address(this).balance < amount) {
            revert NotEnoughUnlockedTokens(amount, address(this).balance);
        }
        claimed += amount;
        emit UnlockedTokensClaimed(beneficiary, amount);

        // Transfer the unlocked tokens to the beneficiary
        Address.sendValue(payable(msg.sender), amount);
    }

    /// @notice Stake locked tokens
    /// @param amount The amount of locked tokens to stake
    /// @param validator The address of the validator
    function stakeLockedTokens(
        uint256 amount,
        bytes calldata validator
    ) external override onlyBeneficiary whenTokenAllocated nonReentrant {
        if (!whitelist.isValidatorWhitelisted(validator)) {
            revert ValidatorNotWhitelisted();
        }
        uint256 stakeable = _getStakeableAmount(beneficiary);
        if (stakeable < amount) {
            revert NotEnoughStakedTokens();
        }
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        if (address(this).balance < amount) {
            revert InsufficientBalanceInVault();
        }

        emit LockedTokensStaked(beneficiary, validator, amount);
        stakingContract.stake{ value: amount }(
            validator,
            IIPTokenStaking.StakingPeriod.FLEXIBLE,
            ""
        );
    }

    /// @notice Unstake locked tokens
    /// @param amount The amount of locked tokens to unstake
    /// @param validator The address of the validator
    function unstakeLockedTokens(
        uint256 amount,
        bytes calldata validator
    ) external override onlyBeneficiary whenTokenAllocated nonReentrant {
        _unstakeLockedTokens(amount, validator);
    }

    /// @notice Claims the staking rewards
    /// @param amount The amount of staking rewards to claim
    function claimStakingRewards(uint256 amount) external override onlyBeneficiary whenTokenAllocated nonReentrant {
        if (block.timestamp < stakingRewardStartTime) {
            revert StakingRewardsNotClaimableYet();
        }
        uint256 claimable = _claimableStakingRewards(beneficiary);
        if (claimable < amount) {
            revert NotEnoughUnlockedTokens(amount, claimable);
        }
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        _getStakeRewardReceiver(beneficiary).transferReward(msg.sender, amount);
        emit StakingRewardsClaimed(beneficiary, amount);
    }

    /// @notice Returns the amount of stakeable tokens for the beneficiary
    /// @return The amount of stakeable tokens
    function getStakeableAmount() external view override returns (uint256) {
        // formula: allocation - unlocked - staked
        return _getStakeableAmount(beneficiary);
    }

    /// @notice Returns the amount of claimable unlocked tokens for a beneficiary
    /// @return The amount of claimable unlocked tokens
    function claimableUnlockedTokens() external view override returns (uint256) {
        return _claimableUnlockedTokens(beneficiary);
    }

    /// @notice Returns the amount of unlocked tokens for a beneficiary at a given timestamp
    /// @param timestamp The timestamp to check the unlocked amount
    /// @return unlockedAmount The amount of unlocked tokens
    function getUnlockedAmount(
        uint64 timestamp
    ) external view override returns (uint256 unlockedAmount) {
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
        return _claimableStakingRewards(beneficiary);
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
        return _getStakeRewardReceiverAddress(beneficiary);
    }

    /// @notice Returns the month of the timestamp since 2025 -01-01, 2025-01-01 is month 1, 2026-01-01 is month 13
    /// @param timestamp The timestamp to check the month
    /// @return month The month of the timestamp
    function getMonth(uint64 timestamp) public view returns (uint64) {
        uint8[61] memory MONTH_DURATIONS = _getMonthDurations();
        uint64 month = 0;
        uint64 duration = timestamp - START_2025;
        for (uint64 i = 0; i < MONTH_DURATIONS.length; i++) {
            if (duration >= MONTH_DURATIONS[i] * 1 days) {
                duration -= MONTH_DURATIONS[i] * 1 days;
                month++;
            } else {
                break;
            }
        }
        return month;
    }

    /// @notice Get the end timestamp of from startTimestamp after durationMonths.
    /// @dev example:
    /// from 2025-01-01 after 1 month is 2025-02-01  (31 days)
    /// from 2025-01-01 after 2 month is 2025-03-01  (31 days + 28 days)
    /// from 2025-01-01 after 3 month is 2025-04-01  (31 days + 28 days + 31 days)
    /// @param startTimestamp The start timestamp
    /// @param durationMonths The duration in months
    /// @return endTimestamp The end timestamp
    function getEndTimestamp(uint64 startTimestamp, uint64 durationMonths) public view returns (uint64) {
        uint8[61] memory MONTH_DURATIONS = _getMonthDurations();
        // get start month from startTimestamp
        // for each month, add the duration of the month to startTimestamp
        uint64 endTimestamp = startTimestamp;
        for (uint64 i = 0; i < durationMonths; i++) {
            endTimestamp += MONTH_DURATIONS[getMonth(endTimestamp)] * 1 days;
        }
        return endTimestamp;
    }

    /// @dev define an array of month durations for 2025-2029, 2025-01-01 is month 1, 2026-01-01 is month 13
    /// @return MONTH_DURATIONS The array of month durations
    function _getMonthDurations() internal pure returns (uint8[61] memory) {
        uint8[61] memory MONTH_DURATIONS = [
                    0,31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
                    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
                    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
                    31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31,
                    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
            ];
        return MONTH_DURATIONS;
    }

    /// @dev Create a new StakeRewardReceiver contract for the beneficiary
    /// @param beneficiary The address of the beneficiary
    /// @return receiver The StakeRewardReceiver contract
    function _createStakeRewardReceiver(bytes32 beneficiary) internal returns (IStakeRewardReceiver receiver) {
        if (_getStakeRewardReceiverAddress(beneficiary).code.length > 0) {
            revert StakeRewardReceiverAlreadyExists();
        }
        return
            IStakeRewardReceiver(
                payable(Create2.deploy(0, beneficiary, _getStakeRewardReceiverCreationCode(beneficiary)))
            );
    }

    /// @dev Unstake locked tokens, if force is true, the function will not check the stakeable amount
    /// @param amount The amount of locked tokens to unstake
    /// @param validator The address of the validator
    function _unstakeLockedTokens(uint256 amount, bytes calldata validator) internal {
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }

        bytes32 validatorHash = keccak256(validator);

        // delegation id is 0 for flexible staking
        stakingContract.unstake{ value: stakingContract.fee() }(
            validator,
            0,
            amount,
            ""
        );
        // Record the unstake request
        emit LockedTokensUnstakeRequested(beneficiary, validator, amount);
    }

    /// @dev Returns the amount of claimable unlocked tokens for a beneficiary
    /// @param beneficiary The address of the beneficiary
    function _claimableUnlockedTokens(bytes32 beneficiary) internal view returns (uint256 claimable) {
        // formular: claimbale = min[(unlocked - claimed), balance]
        uint256 unlockedSoFar = _getUnlockedAmount(beneficiary, uint64(block.timestamp));
        claimable = Math.min(unlockedSoFar - claimed, address(this).balance);
        return claimable;
    }

    /// @dev Returns the amount of claimable rewards for a beneficiary
    /// @param beneficiary The address of the beneficiary
    /// @return The amount of claimable rewards
    function _claimableStakingRewards(bytes32 beneficiary) internal view returns (uint256) {
        return _getStakeRewardReceiverAddress(beneficiary).balance;
    }

    /// @dev Returns the amount of stakeable tokens for a beneficiary
    /// @param beneficiary The address of the beneficiary
    /// @return The amount of stakeable tokens
    function _getStakeableAmount(bytes32 beneficiary) internal view returns (uint256) {
        // formula: balance - (unlocked - claimed)
        return address(this).balance - _getUnlockedAmount(beneficiary, uint64(block.timestamp)) - claimed;
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
        uint256 alloc = allocation;
        if (alloc == 0) {
            return 0;
        }

        if (timestamp >= unlocking.end) {
            // Fully unlocked
            return alloc;
        }

        uint64 elapsed = timestamp - unlocking.start;
        uint64 durationMonthsAfterCliff = unlocking.durationMonths - unlocking.cliffMonths;
        uint64 elapsedMonths = getMonth(timestamp) - getMonth(unlocking.start);
        uint64 wholeMonthsEnd = getEndTimestamp(unlocking.start, elapsedMonths);
        if (wholeMonthsEnd > timestamp) {
            elapsedMonths -= 1;
        }
        uint256 elapsedMonthsAfterCliff = elapsedMonths - unlocking.cliffMonths;
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
        unlockedAmount = ((alloc * unlocking.cliffPercentage * durationMonthsAfterCliff) +
            (alloc * (HUNDRED_PERCENT - unlocking.cliffPercentage) * elapsedMonthsAfterCliff)) /
            (durationMonthsAfterCliff * HUNDRED_PERCENT);

        if (unlockedAmount > alloc) {
            unlockedAmount = alloc;
        }
    }

    function _getStakeRewardReceiver(bytes32 beneficiary) internal view returns (IStakeRewardReceiver) {
        return IStakeRewardReceiver(payable(_getStakeRewardReceiverAddress(beneficiary)));
    }

    function _getStakeRewardReceiverAddress(bytes32 beneficiary) internal view returns (address) {
        return Create2.computeAddress(beneficiary, keccak256(_getStakeRewardReceiverCreationCode(beneficiary)));
    }

    function _getStakeRewardReceiverCreationCode(bytes32 beneficiary) internal view returns (bytes memory) {
        return
            abi.encodePacked(
                type(StakeRewardReceiver).creationCode,
                abi.encode(beneficiary, address(this), address(stakingContract))
            );
    }

    function _toHash(address addr) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(addr));
    }
}
