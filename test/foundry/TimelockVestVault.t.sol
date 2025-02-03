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

// Minimal mock for IIPTokenStakingWithFee.
// This mock implements all functions from IIPTokenStaking so that it can be deployed.
// For functions not used in tests (such as createValidator, stake, updateValidatorCommission, etc.)
// the implementation simply reverts.
contract MockStaking is IIPTokenStakingWithFee {
    uint256 public override fee;

    event StakeOnBehalfCalled(address indexed delegator, bytes validator, uint256 stakingPeriod, bytes data);
    event UnstakeOnBehalfCalled(address indexed delegator, bytes validator, uint256 delegationId, uint256 amount, bytes data);

    constructor(uint256 _fee) {
        fee = _fee;
    }

    // Functions used in tests:
    function stakeOnBehalf(
        address delegator,
        bytes calldata validator,
        IIPTokenStaking.StakingPeriod stakingPeriod,
        bytes calldata data
    ) external payable override returns (uint256 delegationId) {
        emit StakeOnBehalfCalled(delegator, validator, uint256(stakingPeriod), data);
        return 0;
    }

    function unstakeOnBehalf(
        address delegator,
        bytes calldata validator,
        uint256 delegationId,
        uint256 amount,
        bytes calldata data
    ) external payable override {
        emit UnstakeOnBehalfCalled(delegator, validator, delegationId, amount, data);
    }

    // --- Dummy implementations for the rest of IIPTokenStaking functions ---
    function createValidator(
        bytes calldata,
        string calldata,
        uint32,
        uint32,
        uint32,
        bool,
        bytes calldata
    ) external payable override {
        revert("Not implemented");
    }

    function stake(
        bytes calldata validatorCmpPubkey,
        IIPTokenStaking.StakingPeriod stakingPeriod,
        bytes calldata data
    ) external payable override returns (uint256 delegationId) {
        revert("Not implemented");
    }

    function updateValidatorCommission(
        bytes calldata validatorCmpPubkey,
        uint32 commissionRate
    ) external payable override {
        revert("Not implemented");
    }

    function redelegate(
        bytes calldata,
        bytes calldata,
        uint256,
        uint256
    ) external payable override {
        revert("Not implemented");
    }

    function redelegateOnBehalf(
        address,
        bytes calldata,
        bytes calldata,
        uint256,
        uint256
    ) external payable override {
        revert("Not implemented");
    }

    function roundedStakeAmount(uint256) external view override returns (uint256, uint256) {
        revert("Not implemented");
    }

    function setOperator(address) external payable override {
//        revert("Not implemented");
    }

    function unsetOperator() external payable override {
        revert("Not implemented");
    }

    function setWithdrawalAddress(address) external payable override {
//        revert("Not implemented");
    }

    function setRewardsAddress(address) external payable override {
//        revert("Not implemented");
    }

    function unstake(
        bytes calldata,
        uint256,
        uint256,
        bytes calldata
    ) external payable override {
        revert("Not implemented");
    }

    function unjail(
        bytes calldata,
        bytes calldata
    ) external payable override {
        revert("Not implemented");
    }
}

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
    MockStaking mockStaking;
    MockWhitelist mockWhitelist;

    // --- Parameters ---
    // startTime: Jan 19 2025 (example)
    uint64 constant START_TIME = 1737273600;
    // Unlock duration and cliff are now expressed in days.
    uint64 constant UNLOCK_DURATION_DAYS = 1440; // 4 years = 1440 days
    uint64 constant CLIFF_DURATION_DAYS = 360;     // 1 year = 360 days
    // Staking reward unlock start timestamp (example)
    uint64 constant STAKING_REWARD_UNLOCK_START = 1755673200;

    // For this test, assume each beneficiary is allocated 360 tokens.
    uint256 constant ALLOCATION = 360 ether;
    // Total funding is the sum of allocations for two beneficiaries.
    uint256 constant TOTAL_FUNDING = ALLOCATION * 2;

    // Two beneficiaries (their addresses are hashed for caller validation)
    bytes32 beneficiary1; // hash(address(this))
    bytes32 beneficiary2; // hash(user1)
    address user1;

    // A sample validator (as raw bytes) that will be whitelisted.
    bytes sampleValidator = "validator1";

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
        beneficiary1 = _toHash(address(this));
        user1 = vm.addr(1);
        beneficiary2 = _toHash(user1);

        mockStaking = new MockStaking(0.01 ether);
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
        vault = new TimelockVestVault(
            address(mockStaking),
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
        // Expected unlocked at cliff = 25% of allocation = 360 * 25/100 = 90 ether.
        uint256 expectedUnlocked = ALLOCATION * 25 / 100;
        uint256 claimAmount = 50 ether; // Claim an amount less than expected unlocked.
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
        uint256 unlockedBefore = vault.getUnlockedAmount(address(this), START_TIME + CLIFF_DURATION_DAYS * 1 days - 1 days);
        assertEq(unlockedBefore, 0);

        // At cliff time, expected unlocked = 25% of allocation.
        uint256 unlockedAtCliff = vault.getUnlockedAmount(address(this), START_TIME + CLIFF_DURATION_DAYS * 1 days);
        uint256 expectedAtCliff = ALLOCATION * 25 / 100; // 90 ether.
        assertEq(unlockedAtCliff, expectedAtCliff);

        // At 18 months from start (18 * 30 days = 540 days),
        // elapsedAfterCliff = 540 days - 360 days = 180 days.
        // Expected unlocked = 135 ether (per contract formula).
        uint64 time18 = START_TIME + 18 * 30 days;
        uint256 unlockedAt18 = vault.getUnlockedAmount(address(this), time18);
        uint256 expectedAt18 = 135 ether;
        assertEq(unlockedAt18, expectedAt18);
    }

    // Test staking locked tokens before any tokens are claimed (beneficiary1).
    function testStakeLockedTokensSuccess() public {
        // Warp to a time well before the cliff so that unlocked = 0 and stakeable = allocation.
        vm.warp(START_TIME + 10 days);
        uint256 stakeAmount = 100 ether;
        vm.expectEmit(true, false, false, true);
        emit LockedTokensStaked(beneficiary1, sampleValidator, stakeAmount);
        vault.stakeLockedTokens(stakeAmount, sampleValidator);
    }

    // Test that staking fails when using a validator that is not whitelisted.
    function testStakeLockedTokensValidatorNotWhitelisted() public {
        bytes memory invalidValidator = "invalid";
        uint256 stakeAmount = 50 ether;
        vm.expectRevert(TimelockVestVault.ValidatorNotWhitelisted.selector);
        vault.stakeLockedTokens(stakeAmount, invalidValidator);
    }

    // Test unstaking locked tokens (beneficiary1).
    function testUnstakeLockedTokensSuccess() public {
        vm.warp(START_TIME + 10 days);
        uint256 stakeAmount = 100 ether;
        vault.stakeLockedTokens(stakeAmount, sampleValidator);

        uint256 unstakeAmount = 50 ether;
        vm.expectEmit(true, false, false, true);
        emit LockedTokensUnstakeRequested(beneficiary1, sampleValidator, unstakeAmount);
        vault.unstakeLockedTokens(unstakeAmount, sampleValidator);
    }

    // Test forced unstake behavior.
    function testForceUnstakeLockedTokens() public {
        vm.warp(START_TIME + 10 days);
        uint256 stakeAmount = 100 ether;
        vault.stakeLockedTokens(stakeAmount, sampleValidator);

        // Forcing an unstake of more than the staked amount should revert.
        uint256 excessiveUnstake = 120 ether;
        vm.expectRevert(TimelockVestVault.NotEnoughStakedTokens.selector);
        vault.forceUnstakeLockedTokens(excessiveUnstake, sampleValidator);

        // A valid forced unstake should succeed.
        uint256 validUnstake = 80 ether;
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
            abi.encode(beneficiary1, address(vault), address(mockStaking))
        );
        address rewardReceiverAddress = Create2.computeAddress(beneficiary1, keccak256(receiverCreationCode), address(vault));
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
        uint256 stakeAmount = 100 ether;
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
        // Expected unlocked for beneficiary2 = 25% of allocation = 90 ether.
        uint256 expectedUnlocked = ALLOCATION * 25 / 100;
        uint256 claimAmount = 30 ether;
        uint256 initialBalance = user1.balance;
        vm.prank(user1);
        vault.claimUnlockedTokens(claimAmount);
        uint256 finalBalance = user1.balance;
        assertGe(finalBalance - initialBalance, claimAmount);

        // Stake tokens.
        uint256 stakeAmount = 50 ether;
        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit LockedTokensStaked(_toHash(user1), sampleValidator, stakeAmount);
        vault.stakeLockedTokens(stakeAmount, sampleValidator);
    }
}