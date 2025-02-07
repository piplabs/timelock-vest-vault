// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
/* solhint-disable no-console */

import { Script, stdJson } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { TimelockVestVault } from "../contracts/TimelockVestVault.sol";
import { ValidatorWhitelist } from "../contracts/ValidatorWhitelist.sol";

contract DeployVaults is Script {
    using stdJson for string;

    string private output;
    address private constant VALIDATOR_WHITELIST = address(0xC8D451cd5BA38af9F72E628da0998D8AB4b206A6);
    address private constant STAKING_CONTRACT = address(0xCCcCcC0000000000000000000000000000000001);
    // Unlock duration and cliff are now expressed in days.
    uint64 constant UNLOCK_DURATION_MONTHS = 48; // 4 years = 48 months
    uint64 constant CLIFF_DURATION_MONTHS = 12; // 1 year = 12 months
    uint64 constant CLIFF_UNLOCK_PERCENTAGE = 2500; // 25% of allocation
    // Staking reward unlock start timestamp (example)
    uint64 constant STAKING_REWARD_UNLOCK_START = 1755673200;

    struct Allocation {
        address beneficiary;
        uint256 lockedAmount;
    }

    struct AllocationBundle {
        Allocation[] allocations;
        string name;
    }

    uint256 private privateKey = vm.envUint("STORY_PRIVATEKEY");
    string private allocationJson = vm.envString("STORY_ALLOCATIONS_INPUT");
    string private allocationOutput = vm.envString("STORY_ALLOCATIONS_OUTPUT");
    Allocation[] public allocations;


    function run() public {
        AllocationBundle memory bundle = _readAllocations();
        vm.startBroadcast(privateKey);
        _deploy(bundle.allocations);
        vm.stopBroadcast();
    }

    function _deploy(Allocation[] memory allocations) internal {
        for (uint256 i = 0; i < allocations.length; i++) {
            Allocation memory allocation = allocations[i];
            bytes32 beneficiaryHash = _toHash(allocation.beneficiary);
            TimelockVestVault vault = new TimelockVestVault{ value: 1 ether }(
                STAKING_CONTRACT,
                VALIDATOR_WHITELIST,
                UNLOCK_DURATION_MONTHS,
                CLIFF_DURATION_MONTHS,
                CLIFF_UNLOCK_PERCENTAGE,
                STAKING_REWARD_UNLOCK_START,
                beneficiaryHash,
                allocation.lockedAmount * 1e18
            );
            output = vm.serializeAddress("", vm.toString(allocation.beneficiary), address(vault));
            console2.log("Vault deployed: ", address(vault));
        }
        vm.writeJson(output, allocationOutput, ".results");

    }

    function _readAllocations() internal returns (AllocationBundle memory) {
        console2.log("Reading allocation file: ", allocationJson);
        string memory json = vm.readFile(allocationJson);
        bytes memory data = vm.parseJson(json);
        AllocationBundle memory bundle = abi.decode(data, (AllocationBundle));
        return bundle;
    }

    function _toHash(address addr) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(addr));
    }
}

contract DeployValidatorWhitelist is Script {
    uint256 private privateKey = vm.envUint("STORY_PRIVATEKEY");
    string private validatorJson = vm.envString("STORY_VALIDATORS_INPUT");
    address private validatorListOwner = vm.envAddress("STORY_DEPLOYER_ADDRESS");


    function run() public {
        vm.startBroadcast(privateKey);
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        ValidatorWhitelist whitelist = new ValidatorWhitelist(validatorListOwner);
        console2.log("Whitelist deployed: ", address(whitelist));


        console2.log("Reading validators list file: ", validatorJson);
        string memory json = vm.readFile(validatorJson);
        bytes[] memory validators = vm.parseJsonBytesArray(json, ".validators");
        for (uint256 i = 0; i < validators.length; i++) {
            whitelist.addValidator(validators[i]);
            console2.log("Validator added: ", vm.toString(validators[i]));
        }

    }

}