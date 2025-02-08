// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// Import the updated TimelockVestVault contract from its stored location.
import "../../contracts/TimelockVestVault.sol";
import "../../contracts/StakeRewardReceiver.sol";
import "../../contracts/interfaces/ITimelockVestVault.sol";

//
// Mocks
//

// Minimal mock for IValidatorWhitelist.
contract MockWhitelist is IValidatorWhitelist {
    mapping(bytes32 => bool) internal whitelisted;

    event ValidatorAdded(bytes validator);
    event ValidatorRemoved(bytes validator);

    function isValidatorWhitelisted(bytes calldata validator) external view override returns (bool) {
        return whitelisted[keccak256(validator)];
    }

    function addValidator(bytes calldata validator) external override {
        whitelisted[keccak256(validator)] = true;
        emit ValidatorAdded(validator);
    }

    function removeValidator(bytes calldata validator) external override {
        whitelisted[keccak256(validator)] = false;
        emit ValidatorRemoved(validator);
    }

    function getAllWhitelistedValidators() external view override returns (bytes[] memory) {
        // For testing purposes, an empty list is sufficient.
        bytes[] memory list;
        return list;
    }
}

//
// Test Contract
//

contract TimelockVestVaultTest is Test {
    TimelockVestVault vault;
    TimelockVestVault vault2;
    IIPTokenStakingWithFee stakingContract;
    //    MockStaking mockStaking;
    MockWhitelist mockWhitelist;

    // --- Parameters ---
    // startTime:  Feb 13 2025 (example)
    uint64 constant START_TIME = 1739404800;
    // Unlock duration and cliff are now expressed in days.
    uint64 constant UNLOCK_DURATION_MONTHS = 48; // 4 years = 48 months
    uint64 constant CLIFF_DURATION_MONTHS = 12; // 1 year = 12 months
    uint64 constant CLIFF_UNLOCK_PERCENTAGE = 2500; // 25% of allocation
    // Staking reward unlock start timestamp (example)
    // Wednesday, August 20, 2025 7:00:00 AM UTC
    uint64 constant STAKING_REWARD_UNLOCK_START = 1755673200;

    // For this test, assume each beneficiary is allocated 360 tokens.
    uint256 constant ALLOCATION = 36_000_000 ether;

    // Two beneficiaries (their addresses are hashed for caller validation)
    bytes32 beneficiary1; // hash(address(this))
    bytes32 beneficiary2; // hash(user1)
    address user1;

    // A sample validator (as raw bytes) that will be whitelisted.
    bytes sampleValidator = hex"0381513466154dfc0e702d8325d7a45284bc395f60b813230da299fab640c1eb08";

    receive() external payable {}

    // --- Helper ---
    function _toHash(address addr) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(addr));
    }

    function setUp() public {
        uint256 forkId = vm.createFork("https://aeneid.storyrpc.io");
        vm.selectFork(forkId);

        beneficiary1 = _toHash(address(this));
        user1 = vm.addr(1);
        beneficiary2 = _toHash(user1);

        stakingContract = IIPTokenStakingWithFee(address(0xCCcCcC0000000000000000000000000000000001));
        mockWhitelist = new MockWhitelist();

        // Whitelist our sample validator.
        mockWhitelist.addValidator(sampleValidator);

        // Deploy the vault. Note that _unlockDurationDays and _cliffDurationDays are passed as day counts.
        vm.deal(address(this), 1 ether);
        vault = new TimelockVestVault{ value: 1 ether }(
            address(stakingContract),
            address(mockWhitelist),
            UNLOCK_DURATION_MONTHS,
            CLIFF_DURATION_MONTHS,
            CLIFF_UNLOCK_PERCENTAGE,
            STAKING_REWARD_UNLOCK_START,
            beneficiary1,
            ALLOCATION
        );

        // Fund the vault with enough ether to simulate token transfers.
        vm.deal(address(vault), ALLOCATION);

        vm.deal(address(this), 1 ether);
        vault2 = new TimelockVestVault{ value: 1 ether }(
            address(stakingContract),
            address(mockWhitelist),
            UNLOCK_DURATION_MONTHS,
            CLIFF_DURATION_MONTHS,
            CLIFF_UNLOCK_PERCENTAGE,
            STAKING_REWARD_UNLOCK_START,
            beneficiary2,
            ALLOCATION
        );

        // Fund the vault with enough ether to simulate token transfers.
        vm.deal(address(vault2), ALLOCATION);
    }

    // Test that a non-beneficiary (i.e. an address with no allocation) cannot call claimUnlockedTokens.
    function testNonBeneficiaryReverts() public {
        address nonBeneficiary = vm.addr(2);
        vm.prank(nonBeneficiary);
        vm.expectRevert(TimelockVestVault.NotBeneficiary.selector);
        vault.withdrawUnlockedTokens(1 ether);
    }

    // Test claiming unlocked tokens before the cliff time reverts.
    function testClaimUnlockedTokensBeforeCliff() public {
        // Warp to just before the cliff: START_TIME + CLIFF_DURATION_DAYS * 1 days - 1 day.
        vm.warp(START_TIME + 365 * 1 days - 1 days);
        vm.expectRevert(TimelockVestVault.TokensNotUnlockedYet.selector);
        vault.withdrawUnlockedTokens(1 ether);
    }

    // Test claiming unlocked tokens at the cliff time.
    function testClaimUnlockedTokensAtCliff() public {
        // Warp exactly to the cliff time.
        vm.warp(START_TIME + 365 * 1 days);
        // Expected unlocked at cliff = 25% of allocation = 36_000_000 * 25/100 = 9_000_000 ether.
        uint256 expectedUnlocked = (ALLOCATION * 25) / 100;
        uint256 claimAmount = 5_000_000 ether; // Claim an amount less than expected unlocked.
        uint256 initialBalance = address(this).balance;
        vm.expectEmit(true, false, false, true);
        emit ITimelockVestVault.UnlockedTokensWithdrawn(beneficiary1, claimAmount);
        vault.withdrawUnlockedTokens(claimAmount);
        uint256 finalBalance = address(this).balance;
        assertGe(finalBalance - initialBalance, claimAmount);
    }

    function testGetElapsedMonths() public {
        uint64 timestamp = 1737273600; // Jan 19 2025
        uint64 month = vault.getElapsedMonths(timestamp);
        assertEq(month, 0);

        timestamp = START_TIME; // Feb 13 2025
        month = vault.getElapsedMonths(timestamp);
        assertEq(month, 0);

        timestamp = START_TIME + 27 days; // Mar 12 2025
        month = vault.getElapsedMonths(timestamp);
        assertEq(month, 0);

        timestamp = START_TIME + 28 days; // Mar 13 2025
        month = vault.getElapsedMonths(timestamp);
        assertEq(month, 1);

        timestamp = START_TIME + 28 days + 30 days; // Apr 12 2025
        month = vault.getElapsedMonths(timestamp);
        assertEq(month, 1);

        timestamp = START_TIME + 28 days + 31 days; // Apr 13 2025
        month = vault.getElapsedMonths(timestamp);
        assertEq(month, 2);

        timestamp = START_TIME + 28 days + 32 days; // Apr 14 2025
        month = vault.getElapsedMonths(timestamp);
        assertEq(month, 2);

        timestamp = START_TIME + 365 days; // Feb 13 2026
        month = vault.getElapsedMonths(timestamp);
        assertEq(month, 12);

        timestamp = START_TIME + 365 days * 3; // Feb 14 2026
        month = vault.getElapsedMonths(timestamp);
        assertEq(month, 36);

        // Leap year
        timestamp = START_TIME + 365 days * 3 + 28 days; // Mar 12 2028
        month = vault.getElapsedMonths(timestamp);
        assertEq(month, 36);

        timestamp = START_TIME + 365 days * 3 + 29 days; // Mar 13 2028
        month = vault.getElapsedMonths(timestamp);
        assertEq(month, 37);

        timestamp = START_TIME + 365 days * 4; // Mar 12 2029
        month = vault.getElapsedMonths(timestamp);
        assertEq(month, 47);

        timestamp = START_TIME + 365 days * 4 + 1 days; // Mar 13 2029
        month = vault.getElapsedMonths(timestamp);
        assertEq(month, 48);

        timestamp = START_TIME + 365 days * 5; // Mar 13 2029
        month = vault.getElapsedMonths(timestamp);
        assertEq(month, 48);

    }

    function testGetEndTimestamp() public {
        uint64 endTimestamp = vault.getEndTimestamp(12);
        assertEq(endTimestamp, START_TIME + 365 * 1 days);

        endTimestamp = vault.getEndTimestamp(2);
        assertEq(endTimestamp, START_TIME + 31 days + 28 days);

        endTimestamp = vault.getEndTimestamp(3);
        assertEq(endTimestamp, START_TIME + 31 days + 28 days + 30 days);

        endTimestamp = vault.getEndTimestamp(4);
        assertEq(endTimestamp, START_TIME + 31 days + 28 days + 31 days + 30 days);

        endTimestamp = vault.getEndTimestamp(13);
        assertEq(endTimestamp, START_TIME + 365 * 1 days + 28 days);

        endTimestamp = vault.getEndTimestamp(14);
        assertEq(endTimestamp, START_TIME + 365 * 1 days + 31 days + 28 days);

        endTimestamp = vault.getEndTimestamp(36);
        assertEq(endTimestamp, START_TIME + 365 * 3 days);

        endTimestamp = vault.getEndTimestamp(48);
        assertEq(endTimestamp, START_TIME + 365 * 4 days + 1 days); // 4 years, including leap year.

        endTimestamp = vault.getEndTimestamp(36);
        assertEq(endTimestamp, START_TIME + 365 * 3 days); // 3 years, including leap year but not pass leap month.

        endTimestamp = vault.getEndTimestamp(37);
        assertEq(endTimestamp, START_TIME + 365 * 3 days + 29 days); // 3 years, including leap year.
    }

    // Test the view function getUnlockedAmount for beneficiary1.
    function testGetUnlockedAmount() public {
        // Before the cliff, unlocked amount should be zero.
        uint256 unlockedBefore = vault.getUnlockedAmount(
            START_TIME + 365 * 1 days - 1 days
        );
        assertEq(unlockedBefore, 0);

        // At cliff time, expected unlocked = 25% of allocation.
        uint256 unlockedAtCliff = vault.getUnlockedAmount(START_TIME + 365 * 1 days);
        uint256 expectedAtCliff = (ALLOCATION * 25) / 100; // 9_000_000 ether.
        assertEq(unlockedAtCliff, expectedAtCliff);

        // At 18 months from start
        // elapsedAfterCliff = 6 months
        // Expected unlocked = 13_500_000 ether (per contract formula).
        uint64 time18 = START_TIME + 365 days + 31 days + 28 days + 31 days + 30 days + 31 days + 30 days;
        uint256 unlockedAt18 = vault.getUnlockedAmount(time18);
        uint256 expectedAt18 = 13_500_000 ether;
        assertEq(unlockedAt18, expectedAt18);
    }

    // Test staking locked tokens before any tokens are claimed (beneficiary1).
    function testStakeLockedTokensSuccess() public {
        // Warp to a time well before the cliff so that unlocked = 0 and stakeable = allocation.
        vm.warp(START_TIME + 10 days);
        uint256 stakeAmount = 10_000_000 ether;
        vm.expectEmit(true, false, false, true);
        emit ITimelockVestVault.TokensStaked(beneficiary1, sampleValidator, stakeAmount);
        vault.stakeTokens(stakeAmount, sampleValidator);
    }

    // Test that staking fails when using a validator that is not whitelisted.
    function testStakeLockedTokensValidatorNotWhitelisted() public {
        bytes memory invalidValidator = "invalid";
        uint256 stakeAmount = 5_000_000 ether;
        vm.expectRevert(TimelockVestVault.ValidatorNotWhitelisted.selector);
        vault.stakeTokens(stakeAmount, invalidValidator);
    }

    // Test unstaking locked tokens (beneficiary1).
    function testUnstakeLockedTokensSuccess() public {
        vm.warp(START_TIME + 10 days);
        uint256 stakeAmount = 10_000_000 ether;
        vault.stakeTokens(stakeAmount, sampleValidator);

        uint256 unstakeAmount = 5_000_000 ether;
        vm.expectEmit(true, false, false, true);
        emit ITimelockVestVault.TokensUnstakeRequested(beneficiary1, sampleValidator, unstakeAmount);
        vm.deal(address(this), 1 ether);
        vault.unstakeTokens{value: 1 ether}(unstakeAmount, sampleValidator);
    }

    // Test that staking rewards cannot be claimed before the staking reward unlock time.
    function testClaimStakingRewardsBeforeUnlock() public {
        vm.warp(START_TIME + 100 days); // before STAKING_REWARD_UNLOCK_START
        vm.expectRevert(TimelockVestVault.StakingRewardsNotClaimableYet.selector);
        vault.claimStakingRewards(10 ether);
    }

    // Test successful claiming of staking rewards (beneficiary1).
    function testClaimStakingRewardsSuccess() public {
        vm.warp(STAKING_REWARD_UNLOCK_START + 1 days);
        // Fund the reward receiver to simulate earned rewards.
        vm.deal(vault.getStakeRewardReceiverAddress(), 50 ether);
        assertEq(address(vault.getStakeRewardReceiverAddress()).balance, 50 ether);
        assertEq(vault.claimableStakingRewards(), 50 ether);
        uint256 claimAmount = 20 ether;
        uint256 initialBalance = address(this).balance;
        vault.claimStakingRewards(claimAmount);
        uint256 finalBalance = address(this).balance;
        assertEq(finalBalance - initialBalance, claimAmount);
        assertEq(vault.claimableStakingRewards(), 30 ether);
    }

    // Test the view functions for the unlocking schedule.
    function testScheduleViewFunctions() public {
        TimelockVestVault.UnlockingSchedule memory sched = vault.getUnlockingSchedule();
        assertEq(sched.start, START_TIME);
        assertEq(sched.durationMonths, UNLOCK_DURATION_MONTHS);
        assertEq(sched.cliff, START_TIME + 365 * 1 days);
        assertEq(sched.cliffMonths, CLIFF_DURATION_MONTHS);
        assertEq(sched.end, START_TIME + 365 * 4 * 1 days + 1 days);
        assertEq(vault.getStartTime(), START_TIME);
        assertEq(vault.getStakingRewardClaimableStartTime(), STAKING_REWARD_UNLOCK_START);
    }

    // Test actions for the second beneficiary using vm.prank.
    function testBeneficiary2Flow() public {
        // Before the cliff, claiming should revert.
        vm.warp(START_TIME + 365 * 1 days - 1 days);
        vm.prank(user1);
        vm.expectRevert(TimelockVestVault.TokensNotUnlockedYet.selector);
        vault2.withdrawUnlockedTokens(1 ether);

        // Warp to the cliff time.
        vm.warp(START_TIME + 365 * 1 days);
        // Expected unlocked for beneficiary2 = 25% of allocation = 9_000_000 ether.
        uint256 expectedUnlocked = (ALLOCATION * 25) / 100;
        uint256 claimAmount = 3_000_000 ether;
        uint256 initialBalance = user1.balance;
        vm.prank(user1);
        vault2.withdrawUnlockedTokens(claimAmount);
        uint256 finalBalance = user1.balance;
        assertGe(finalBalance - initialBalance, claimAmount);

        // Stake tokens.
        uint256 stakeAmount = 5_000_000 ether;
        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit ITimelockVestVault.TokensStaked(_toHash(user1), sampleValidator, stakeAmount);
        vault2.stakeTokens(stakeAmount, sampleValidator);
    }

    // test user can withdraw all balance of vault after unlock time
    function testWithdrawAllBalance() public {
        vm.warp(START_TIME + 365 * 4 * 1 days + 1 days);
        uint256 initialBalance = address(this).balance;
        vault.withdrawUnlockedTokens(ALLOCATION);
        uint256 finalBalance = address(this).balance;
        assertEq(finalBalance - initialBalance, ALLOCATION);
    }

    // test user can withdraw all balance of vault after unlock time, even when the balance over the unlocked amount
    function testWithdrawAllBalanceOverUnlocked() public {
        vm.deal(address(vault), ALLOCATION + 1 ether);
        vm.warp(START_TIME + 365 * 4 * 1 days + 1 days);
        uint256 initialBalance = address(this).balance;
        vault.withdrawUnlockedTokens(ALLOCATION + 1 ether);
        uint256 finalBalance = address(this).balance;
        assertEq(finalBalance - initialBalance, ALLOCATION + 1 ether);
    }
}
