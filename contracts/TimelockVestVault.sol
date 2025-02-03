// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ITimelockVestVault } from "./interfaces/ITimelockVestVault.sol";
import { IValidatorWhitelist } from "./interfaces/IValidatorWhitelist.sol";
import { IIPTokenStaking } from "./interfaces/IIPTokenStaking.sol";
import { IStakeAgent } from "./interfaces/IStakeAgent.sol";
import { IStakeRewardReceiver } from "./interfaces/IStakeRewardReceiver.sol";
import { StakeAgent } from "./StakeAgent.sol";
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
    // Reference to the deployed IPTokenStaking contract
    IIPTokenStakingWithFee private immutable stakingContract;

    // Reference to the validator whitelist
    IValidatorWhitelist private immutable whitelist;

    UnlockingSchedule private unlocking;

    uint64 private immutable stakingRewardStartTime;

    mapping(bytes32 beneficiary => uint256 allocatin) private allocations;
    mapping(bytes32 beneficiary => uint256 claimed) private claimeds;

    mapping(bytes32 beneficiary => uint256 totalStakedAmount) private totalStakedAmounts;
    mapping(bytes32 beneficiary => mapping(bytes32 validator => uint256 stakedAmount)) private validatorStakedAmounts;
    mapping(bytes32 beneficiary => uint256 totalUnstakeRequestedAmount) private totalUnstakeRequestedAmounts;

    mapping(bytes32 beneficiary => uint256 rewardClaimed) private rewardClaimeds;

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

    modifier onlyBeneficiary() {
        if (allocations[_toHash(msg.sender)] == 0) {
            revert NotBeneficiary();
        }
        _;
    }

    // Constructor can be designed to set up schedules & references
    constructor(
        address _stakingContract,
        address _validatorWhitelist,
        uint64 _startTime,
        uint64 _unlockDurationDays,
        uint64 _cliffDurationDays,
        uint64 _cliffPercentage,
        uint64 _stakingRewardStart,
        bytes32[] memory _beneficiaries,
        uint256[] memory _allocations
    ) payable {
        stakingContract = IIPTokenStakingWithFee(_stakingContract);
        whitelist = IValidatorWhitelist(_validatorWhitelist);

        unlocking = UnlockingSchedule({
            start: _startTime,
            duration: _unlockDurationDays * 1 days,
            end: _startTime + _unlockDurationDays * 1 days,
            cliff: _startTime + _cliffDurationDays * 1 days,
            cliffPercentage: _cliffPercentage
        });

        stakingRewardStartTime = _stakingRewardStart;

        if (_beneficiaries.length != _allocations.length) {
            revert InvalidInputLengths();
        }
        for (uint256 i = 0; i < _beneficiaries.length; i++) {
            allocations[_beneficiaries[i]] = _allocations[i];
            IStakeAgent stakeAgent = _createStakeAgent(_beneficiaries[i]);
            IStakeRewardReceiver receiver = _createStakeRewardReceiver(_beneficiaries[i]);
            stakeAgent.setUnstakeReceiverAddress{ value: stakingContract.fee() }(address(stakeAgent));
            stakeAgent.setRewardReceiverAddress{ value: stakingContract.fee() }(address(receiver));
            stakeAgent.setOperator{ value: stakingContract.fee() }(address(this));
        }
    }

    receive() external payable {}

    /// @notice claim unlocked tokens from vault to the caller, the caller should be a beneficiary
    /// @param amount The amount of unlocked tokens to claim
    function claimUnlockedTokens(uint256 amount) external override onlyBeneficiary nonReentrant {
        if (block.timestamp < unlocking.cliff) {
            revert TokensNotUnlockedYet();
        }
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }
        bytes32 beneficiary = _toHash(msg.sender);
        uint256 claimable = _claimableUnlockedTokens(beneficiary);
        uint256 claimed = claimeds[beneficiary];
        if (claimable < amount) {
            revert NotEnoughUnlockedTokens(amount, claimable);
        }
        claimeds[beneficiary] += amount;
        emit UnlockedTokensClaimed(beneficiary, amount);

        IStakeAgent stakeAgent = _getStakeAgent(beneficiary);
        uint256 unstaked = address(stakeAgent).balance;
        uint256 allocated = allocations[beneficiary];
        uint256 staked = totalStakedAmounts[beneficiary];
        uint256 availableInVault = allocated - staked - claimed;
        if (unstaked >= amount) {
            stakeAgent.transferToVault(amount);
        } else if (availableInVault < amount) {
            uint256 remaining = amount - availableInVault;
            if (unstaked > remaining) {
                stakeAgent.transferToVault(remaining);
            } else {
                revert NotEnoughUnlockedTokens(remaining, unstaked);
            }
        }
        // Transfer the unlocked tokens to the beneficiary
        Address.sendValue(payable(msg.sender), amount);
    }

    /// @notice Stake locked tokens
    /// @param amount The amount of locked tokens to stake
    /// @param validator The address of the validator
    function stakeLockedTokens(
        uint256 amount,
        bytes calldata validator
    ) external override onlyBeneficiary nonReentrant {
        if (!whitelist.isValidatorWhitelisted(validator)) {
            revert ValidatorNotWhitelisted();
        }
        bytes32 beneficiary = _toHash(msg.sender);
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

        // Increase staked amount
        totalStakedAmounts[beneficiary] += amount;
        validatorStakedAmounts[beneficiary][keccak256(validator)] += amount;

        emit LockedTokensStaked(beneficiary, validator, amount);
        stakingContract.stakeOnBehalf{ value: amount }(
            _getStakeAgentAddress(beneficiary),
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
    ) external override onlyBeneficiary nonReentrant {
        _unstakeLockedTokens(amount, validator, false);
    }

    /// @notice force Unstake locked tokens without checking the stakeable amount
    /// because unstake took 14 days to complete, and the unstaked amount might not equal to the requested amount
    /// the unstaked amount might larger than the requested amount when remaining staking balance on validator is less than 1024
    /// the unstaked amount might less than the requested if the remaining staking balance on validator is less than the requested amount
    function forceUnstakeLockedTokens(
        uint256 amount,
        bytes calldata validator
    ) external override onlyBeneficiary nonReentrant {
        _unstakeLockedTokens(amount, validator, true);
    }

    function getUnstakeableAmount(address beneficiary) external view override returns (uint256) {
        return _unstakeableAmount(_toHash(beneficiary));
    }

    function _unstakeableAmount(bytes32 beneficiary) internal view returns (uint256) {
        return totalStakedAmounts[beneficiary] - totalUnstakeRequestedAmounts[beneficiary];
    }

    /// @notice Claims the staking rewards
    /// @param amount The amount of staking rewards to claim
    function claimStakingRewards(uint256 amount) external override onlyBeneficiary nonReentrant {
        if (block.timestamp < stakingRewardStartTime) {
            revert StakingRewardsNotClaimableYet();
        }
        bytes32 beneficiary = _toHash(msg.sender);
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

    function _getStakeableAmount(bytes32 beneficiary) internal view returns (uint256) {
        // formula: allocation - unlocked - staked
        return
            allocations[beneficiary] -
            _getUnlockedAmount(beneficiary, uint64(block.timestamp)) -
            totalStakedAmounts[beneficiary];
    }

    function getStakeableAmount(address beneficiary) external view override returns (uint256) {
        // formula: allocation - unlocked - staked
        return _getStakeableAmount(_toHash(beneficiary));
    }
    /// @notice Returns the amount of claimable unlocked tokens for a beneficiary
    /// @param beneficiary The address of the beneficiary
    /// @return The amount of claimable unlocked tokens
    function claimableUnlockedTokens(address beneficiary) external view override returns (uint256) {
        return _claimableUnlockedTokens(_toHash(beneficiary));
    }

    /// @notice Returns the amount of unlocked tokens for a beneficiary at a given timestamp
    /// @param beneficiary The address of the beneficiary
    /// @param timestamp The timestamp to check the unlocked amount
    /// @return unlockedAmount The amount of unlocked tokens
    function getUnlockedAmount(
        address beneficiary,
        uint64 timestamp
    ) external view override returns (uint256 unlockedAmount) {
        return _getUnlockedAmount(_toHash(beneficiary), timestamp);
    }

    /// @notice Returns the amount of claimable rewards for a beneficiary,
    /// The staking rewards will be locked for the first 6 months.
    /// After the first 6 months block rewards withheld, all block rewards are unlocked.
    /// @param beneficiary The address of the beneficiary
    /// @return The amount of claimable rewards
    function claimableStakingRewards(address beneficiary) external view override returns (uint256) {
        if (block.timestamp < stakingRewardStartTime) {
            return 0;
        }
        return _claimableStakingRewards(_toHash(beneficiary));
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

    /// @notice get StakeAgent address for the beneficiary
    /// @param beneficiary The address of the beneficiary
    /// @return The address of the StakeAgent contract associate with the beneficiary
    function getStakeAgentAddress(address beneficiary) external view returns (address) {
        if (allocations[_toHash(beneficiary)] == 0) {
            revert NotBeneficiary();
        }
        return _getStakeAgentAddress(_toHash(beneficiary));
    }

    /// @notice get StakeRewardReceiver address for the beneficiary
    /// @param beneficiary The address of the beneficiary
    /// @return The address of the StakeRewardReceiver contract associate with the beneficiary
    function getStakeRewardReceiverAddress(address beneficiary) external view returns (address) {
        if (allocations[_toHash(beneficiary)] == 0) {
            revert NotBeneficiary();
        }
        return _getStakeRewardReceiverAddress(_toHash(beneficiary));
    }

    function _createStakeAgent(bytes32 beneficiary) internal returns (IStakeAgent stakeAgent) {
        if (_getStakeAgentAddress(beneficiary).code.length > 0) {
            revert StakeAgentAlreadyExists();
        }
        return IStakeAgent(payable(Create2.deploy(0, beneficiary, _getStakeAgentCreationCode(beneficiary))));
    }

    function _createStakeRewardReceiver(bytes32 beneficiary) internal returns (IStakeRewardReceiver receiver) {
        if (_getStakeRewardReceiverAddress(beneficiary).code.length > 0) {
            revert StakeRewardReceiverAlreadyExists();
        }
        return
            IStakeRewardReceiver(
                payable(Create2.deploy(0, beneficiary, _getStakeRewardReceiverCreationCode(beneficiary)))
            );
    }

    function _unstakeLockedTokens(uint256 amount, bytes calldata validator, bool force) internal {
        bytes32 beneficiary = _toHash(msg.sender);
        if (!force) {
            uint256 unstakeable = _unstakeableAmount(beneficiary);
            if (unstakeable < amount) {
                revert NotEnoughStakedTokens();
            }
        }
        if (amount == 0) {
            revert AmountMustBeGreaterThanZero();
        }

        bytes32 validatorHash = keccak256(validator);
        uint256 stakedForValidator = validatorStakedAmounts[beneficiary][validatorHash];
        if (stakedForValidator < amount) {
            revert NotEnoughStakedTokens();
        }

        totalUnstakeRequestedAmounts[beneficiary] += amount;
        // delegation id is 0 for flexible staking
        stakingContract.unstakeOnBehalf{ value: stakingContract.fee() }(
            _getStakeAgentAddress(beneficiary),
            validator,
            0,
            amount,
            ""
        );
        // Record the unstake request
        emit LockedTokensUnstakeRequested(beneficiary, validator, amount);
    }

    function _claimableUnlockedTokens(bytes32 beneficiary) internal view returns (uint256 claimable) {
        // formular: claimbale = min[(unlocked - claimed), ((allocation - staked) + unstaked)]
        uint256 claimed = claimeds[beneficiary];
        uint256 unlockedSoFar = _getUnlockedAmount(beneficiary, uint64(block.timestamp));
        uint256 unstaked = _getStakeAgentAddress(beneficiary).balance;
        uint256 allocation = allocations[beneficiary];
        uint256 staked = totalStakedAmounts[beneficiary];
        claimable = Math.min(unlockedSoFar - claimed, allocation - staked + unstaked);
        return claimable;
    }

    function _claimableStakingRewards(bytes32 beneficiary) internal view returns (uint256) {
        return _getStakeRewardReceiverAddress(beneficiary).balance;
    }

    function _getUnlockedAmount(bytes32 beneficiary, uint64 timestamp) internal view returns (uint256 unlockedAmount) {
        if (timestamp < unlocking.cliff) {
            return 0;
        }
        uint256 alloc = allocations[beneficiary];
        if (alloc == 0) {
            return 0;
        }

        if (timestamp >= unlocking.end) {
            // Fully unlocked
            return alloc;
        }

        uint256 elapsed = timestamp - unlocking.start;
        uint256 durationAfterCliff = unlocking.end - unlocking.cliff;
        uint256 elapsedAfterCliff = timestamp - unlocking.cliff;
        // unlockedAmount = cliff unlock + monthly unlock * elapsed months after cliff
        // example:
        // unlockedAmount = (alloc * 25) / 100 + ((alloc * 75) / 100 / durationAfterCliff / 30 days) *
        //     (elapsedAfterCliff / 30 days)
        // The expression (elapsedAfterCliff / 30 days) represents the number of whole months that have passed
        // since the cliff, with any fractional part discarded due to floor rounding.
        //
        // Multiply by durationAfterCliff before dividing to mitigate precision loss from rounding.
        // unlockedAmount is calculated as:
        // unlockedAmount = ((alloc * 25 * durationAfterCliff) + (alloc * 75 * 30 days * (elapsedAfterCliff / 30 days)))
        //   / (durationAfterCliff * 100)
        // Although the formula can be simplified by factoring out 'alloc', it remains expanded for clarity.
        // unlockedAmount = alloc * 30 days * (elapsed / 30 days) / unlocking.duration; (if configurable cliff is not considered)
        unlockedAmount =
            ((alloc * unlocking.cliffPercentage * durationAfterCliff) +
                (alloc * (100 - unlocking.cliffPercentage) * 30 days * (elapsedAfterCliff / 30 days))) /
            durationAfterCliff /
            100;

        if (unlockedAmount > alloc) {
            unlockedAmount = alloc;
        }
    }

    function _getStakeAgent(bytes32 beneficiary) internal view returns (IStakeAgent) {
        return IStakeAgent(payable(_getStakeAgentAddress(beneficiary)));
    }

    function _getStakeRewardReceiver(bytes32 beneficiary) internal view returns (IStakeRewardReceiver) {
        return IStakeRewardReceiver(payable(_getStakeRewardReceiverAddress(beneficiary)));
    }

    function _getStakeAgentAddress(bytes32 beneficiary) internal view returns (address) {
        return Create2.computeAddress(beneficiary, keccak256(_getStakeAgentCreationCode(beneficiary)));
    }

    function _getStakeRewardReceiverAddress(bytes32 beneficiary) internal view returns (address) {
        return Create2.computeAddress(beneficiary, keccak256(_getStakeRewardReceiverCreationCode(beneficiary)));
    }

    function _getStakeAgentCreationCode(bytes32 beneficiary) internal view returns (bytes memory) {
        return
            abi.encodePacked(
                type(StakeAgent).creationCode,
                abi.encode(beneficiary, address(this), address(stakingContract))
            );
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
