// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";

// Import the updated TimelockVestVault contract from its stored location.
import "../../contracts/TimelockVestVault.sol";
import "../../contracts/StakeRewardReceiver.sol";

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
    IIPTokenStakingWithFee stakingContract;
    //    MockStaking mockStaking;
    MockWhitelist mockWhitelist;

    // --- Parameters ---
    // startTime: Jan 19 2025 (example)
    uint64 constant START_TIME = 1737273600;
    // Unlock duration and cliff are now expressed in days.
    uint64 constant UNLOCK_DURATION_DAYS = 1440; // 4 years = 1440 days
    uint64 constant CLIFF_DURATION_DAYS = 360; // 1 year = 360 days
    // Staking reward unlock start timestamp (example)
    uint64 constant STAKING_REWARD_UNLOCK_START = 1755673200;

    // For this test, assume each beneficiary is allocated 360 tokens.
    uint256 constant ALLOCATION = 36_000_000 ether;
    // Total funding is the sum of allocations for two beneficiaries.
    uint256 constant TOTAL_FUNDING = ALLOCATION * 2;

    // Two beneficiaries (their addresses are hashed for caller validation)
    bytes32 beneficiary1; // hash(address(this))
    bytes32 beneficiary2; // hash(user1)
    address user1;

    // A sample validator (as raw bytes) that will be whitelisted.
    bytes sampleValidator = hex"0381513466154dfc0e702d8325d7a45284bc395f60b813230da299fab640c1eb08";

    // --- Events (per ITimelockVestVault interface) ---
    event UnlockedTokensClaimed(bytes32 indexed beneficiary, uint256 amount);
    event LockedTokensStaked(bytes32 indexed beneficiary, bytes validator, uint256 amount);
    event LockedTokensUnstakeRequested(bytes32 indexed beneficiary, bytes validator, uint256 amount);
    event StakingRewardsClaimed(bytes32 indexed beneficiary, uint256 amount);

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

        // Prepare arrays for constructor.
        bytes32[] memory beneficiaries = new bytes32[](2);
        beneficiaries[0] = beneficiary1;
        beneficiaries[1] = beneficiary2;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = ALLOCATION;
        allocations[1] = ALLOCATION;

        // Deploy the vault. Note that _unlockDurationDays and _cliffDurationDays are passed as day counts.
        vm.deal(address(this), 6 ether);
        vault = new TimelockVestVault{ value: 6 ether }(
            address(stakingContract),
            address(mockWhitelist),
            START_TIME,
            UNLOCK_DURATION_DAYS,
            CLIFF_DURATION_DAYS,
            STAKING_REWARD_UNLOCK_START,
            beneficiaries,
            allocations
        );

        // Fund the vault with enough ether to simulate token transfers.
        vm.deal(address(vault), TOTAL_FUNDING);
    }

    // Test that a non-beneficiary (i.e. an address with no allocation) cannot call claimUnlockedTokens.
    function testNonBeneficiaryReverts() public {
        address nonBeneficiary = vm.addr(2);
        vm.prank(nonBeneficiary);
        vm.expectRevert(TimelockVestVault.NotBeneficiary.selector);
        vault.claimUnlockedTokens(1 ether);
    }

    // Test claiming unlocked tokens before the cliff time reverts.
    function testClaimUnlockedTokensBeforeCliff() public {
        // Warp to just before the cliff: START_TIME + CLIFF_DURATION_DAYS * 1 days - 1 day.
        vm.warp(START_TIME + CLIFF_DURATION_DAYS * 1 days - 1 days);
        vm.expectRevert(TimelockVestVault.TokensNotUnlockedYet.selector);
        vault.claimUnlockedTokens(1 ether);
    }

    // Test claiming unlocked tokens at the cliff time.
    function testClaimUnlockedTokensAtCliff() public {
        // Warp exactly to the cliff time.
        vm.warp(START_TIME + CLIFF_DURATION_DAYS * 1 days);
        // Expected unlocked at cliff = 25% of allocation = 36_000_000 * 25/100 = 9_000_000 ether.
        uint256 expectedUnlocked = (ALLOCATION * 25) / 100;
        uint256 claimAmount = 5_000_000 ether; // Claim an amount less than expected unlocked.
        uint256 initialBalance = address(this).balance;
        vm.expectEmit(true, false, false, true);
        emit UnlockedTokensClaimed(beneficiary1, claimAmount);
        vault.claimUnlockedTokens(claimAmount);
        uint256 finalBalance = address(this).balance;
        assertGe(finalBalance - initialBalance, claimAmount);
    }

    // Test the view function getUnlockedAmount for beneficiary1.
    function testGetUnlockedAmount() public {
        // Before the cliff, unlocked amount should be zero.
        uint256 unlockedBefore = vault.getUnlockedAmount(
            address(this),
            START_TIME + CLIFF_DURATION_DAYS * 1 days - 1 days
        );
        assertEq(unlockedBefore, 0);

        // At cliff time, expected unlocked = 25% of allocation.
        uint256 unlockedAtCliff = vault.getUnlockedAmount(address(this), START_TIME + CLIFF_DURATION_DAYS * 1 days);
        uint256 expectedAtCliff = (ALLOCATION * 25) / 100; // 9_000_000 ether.
        assertEq(unlockedAtCliff, expectedAtCliff);

        // At 18 months from start (18 * 30 days = 540 days),
        // elapsedAfterCliff = 540 days - 360 days = 180 days.
        // Expected unlocked = 13_500_000 ether (per contract formula).
        uint64 time18 = START_TIME + 18 * 30 days;
        uint256 unlockedAt18 = vault.getUnlockedAmount(address(this), time18);
        uint256 expectedAt18 = 13_500_000 ether;
        assertEq(unlockedAt18, expectedAt18);
    }

    // Test staking locked tokens before any tokens are claimed (beneficiary1).
    function testStakeLockedTokensSuccess() public {
        // Warp to a time well before the cliff so that unlocked = 0 and stakeable = allocation.
        vm.warp(START_TIME + 10 days);
        uint256 stakeAmount = 10_000_000 ether;
        vm.expectEmit(true, false, false, true);
        emit LockedTokensStaked(beneficiary1, sampleValidator, stakeAmount);
        vault.stakeLockedTokens(stakeAmount, sampleValidator);
    }

    // Test that staking fails when using a validator that is not whitelisted.
    function testStakeLockedTokensValidatorNotWhitelisted() public {
        bytes memory invalidValidator = "invalid";
        uint256 stakeAmount = 5_000_000 ether;
        vm.expectRevert(TimelockVestVault.ValidatorNotWhitelisted.selector);
        vault.stakeLockedTokens(stakeAmount, invalidValidator);
    }

    // Test unstaking locked tokens (beneficiary1).
    function testUnstakeLockedTokensSuccess() public {
        vm.warp(START_TIME + 10 days);
        uint256 stakeAmount = 10_000_000 ether;
        vault.stakeLockedTokens(stakeAmount, sampleValidator);

        uint256 unstakeAmount = 5_000_000 ether;
        vm.expectEmit(true, false, false, true);
        emit LockedTokensUnstakeRequested(beneficiary1, sampleValidator, unstakeAmount);
        vault.unstakeLockedTokens(unstakeAmount, sampleValidator);
    }

    // Test forced unstake behavior.
    function testForceUnstakeLockedTokens() public {
        vm.warp(START_TIME + 10 days);
        uint256 stakeAmount = 10_000_000 ether;
        vault.stakeLockedTokens(stakeAmount, sampleValidator);

        // Forcing an unstake of more than the staked amount should revert.
        uint256 excessiveUnstake = 12_000_000 ether;
        vm.expectRevert(TimelockVestVault.NotEnoughStakedTokens.selector);
        vault.forceUnstakeLockedTokens(excessiveUnstake, sampleValidator);

        // A valid forced unstake should succeed.
        uint256 validUnstake = 8_000_000 ether;
        vault.forceUnstakeLockedTokens(validUnstake, sampleValidator);
    }

    // Test that staking rewards cannot be claimed before the staking reward unlock time.
    function testClaimStakingRewardsBeforeUnlock() public {
        vm.warp(START_TIME + 200 days); // before STAKING_REWARD_UNLOCK_START
        vm.expectRevert(TimelockVestVault.StakingRewardsNotClaimableYet.selector);
        vault.claimStakingRewards(10 ether);
    }

    // Test successful claiming of staking rewards (beneficiary1).
    function testClaimStakingRewardsSuccess() public {
        vm.warp(STAKING_REWARD_UNLOCK_START + 1 days);
        // Compute the StakeRewardReceiver address via Create2.
        bytes memory receiverCreationCode = abi.encodePacked(
            type(StakeRewardReceiver).creationCode,
            abi.encode(beneficiary1, address(vault), address(stakingContract))
        );
        address rewardReceiverAddress = Create2.computeAddress(
            beneficiary1,
            keccak256(receiverCreationCode),
            address(vault)
        );
        assertEq(vault.getStakeRewardReceiverAddress(address(this)), rewardReceiverAddress);
        // Fund the reward receiver to simulate earned rewards.
        vm.deal(rewardReceiverAddress, 50 ether);
        assertEq(address(rewardReceiverAddress).balance, 50 ether);
        assertEq(vault.claimableStakingRewards(address(this)), 50 ether);
        uint256 claimAmount = 20 ether;
        uint256 initialBalance = address(this).balance;
        vault.claimStakingRewards(claimAmount);
        uint256 finalBalance = address(this).balance;
        assertEq(finalBalance - initialBalance, claimAmount);
        assertEq(vault.claimableStakingRewards(address(this)), 30 ether);
    }

    // Test view functions for stakeable and unstakeable amounts.
    function testViewStakeableAndUnstakeableAmounts() public {
        vm.warp(START_TIME + 10 days);
        // Initially, stakeable = allocation (since unlocked = 0 and no stake yet).
        uint256 stakeable = vault.getStakeableAmount(address(this));
        assertEq(stakeable, ALLOCATION);

        // Stake 100 ether.
        uint256 stakeAmount = 10_000_000 ether;
        vault.stakeLockedTokens(stakeAmount, sampleValidator);

        // Now, stakeable should equal ALLOCATION - staked.
        uint256 stakeableAfter = vault.getStakeableAmount(address(this));
        assertEq(stakeableAfter, ALLOCATION - stakeAmount);

        // Unstakeable amount should be equal to the staked amount (since no unstake requests yet).
        uint256 unstakeable = vault.getUnstakeableAmount(address(this));
        assertEq(unstakeable, stakeAmount);
    }

    // Test the view functions for the unlocking schedule.
    function testScheduleViewFunctions() public {
        TimelockVestVault.UnlockingSchedule memory sched = vault.getUnlockingSchedule();
        assertEq(sched.start, START_TIME);
        assertEq(sched.duration, UNLOCK_DURATION_DAYS * 1 days);
        assertEq(sched.cliff, START_TIME + CLIFF_DURATION_DAYS * 1 days);
        assertEq(sched.end, START_TIME + UNLOCK_DURATION_DAYS * 1 days);
        assertEq(vault.getStartTime(), START_TIME);
        assertEq(vault.getStakingRewardClaimableStartTime(), STAKING_REWARD_UNLOCK_START);
    }

    // Test actions for the second beneficiary using vm.prank.
    function testBeneficiary2Flow() public {
        // Before the cliff, claiming should revert.
        vm.warp(START_TIME + CLIFF_DURATION_DAYS * 1 days - 1 days);
        vm.prank(user1);
        vm.expectRevert(TimelockVestVault.TokensNotUnlockedYet.selector);
        vault.claimUnlockedTokens(1 ether);

        // Warp to the cliff time.
        vm.warp(START_TIME + CLIFF_DURATION_DAYS * 1 days);
        // Expected unlocked for beneficiary2 = 25% of allocation = 9_000_000 ether.
        uint256 expectedUnlocked = (ALLOCATION * 25) / 100;
        uint256 claimAmount = 3_000_000 ether;
        uint256 initialBalance = user1.balance;
        vm.prank(user1);
        vault.claimUnlockedTokens(claimAmount);
        uint256 finalBalance = user1.balance;
        assertGe(finalBalance - initialBalance, claimAmount);

        // Stake tokens.
        uint256 stakeAmount = 5_000_000 ether;
        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit LockedTokensStaked(_toHash(user1), sampleValidator, stakeAmount);
        vault.stakeLockedTokens(stakeAmount, sampleValidator);
    }
}
