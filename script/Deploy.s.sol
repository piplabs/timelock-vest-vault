// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
/* solhint-disable no-console */

import { Script, stdJson } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { TimelockVestVault } from "../contracts/TimelockVestVault.sol";
import { ValidatorWhitelist } from "../contracts/ValidatorWhitelist.sol";
import { TimelockVestVaultFactory } from "../contracts/TimelockVestVaultFactory.sol";

contract DeployVaults is Script {
    using stdJson for string;

    string internal output;

    struct Allocation {
        address beneficiary;
        uint256 lockedAmount;
    }

    struct AllocationBundle {
        Allocation[] allocations;
        string name;
    }

    uint256 internal privateKey = vm.envUint("STORY_PRIVATEKEY");
    string internal allocationJson = vm.envString("STORY_ALLOCATIONS_INPUT");
    string internal allocationOutput = vm.envString("STORY_ALLOCATIONS_OUTPUT");

    address internal VALIDATOR_WHITELIST = address(0xC33edB539FF6Ae84f7e394E556B952bb22164760);
    address internal STAKING_CONTRACT = address(0xCCcCcC0000000000000000000000000000000001);
    uint64 internal UNLOCK_DURATION_MONTHS = uint64(vm.envUint("STORY_UNLOCK_DURATION_MONTHS"));
    uint64 internal CLIFF_DURATION_MONTHS = uint64(vm.envUint("STORY_CLIFF_DURATION_MONTHS"));
    uint64 internal CLIFF_UNLOCK_PERCENTAGE = uint64(vm.envUint("STORY_CLIFF_UNLOCK_PERCENTAGE"));
    // August 13, 2025 0:00:00
    uint64 internal STAKING_REWARD_UNLOCK_START = 1755043200;

    Allocation[] public allocations;

    function run() public virtual {
        AllocationBundle memory bundle = _readAllocations();
        vm.startBroadcast(privateKey);
        _deploy(bundle.allocations);
        vm.stopBroadcast();
    }

    function _deploy(Allocation[] memory allocations) internal virtual {
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

contract DeployVaultFactory is DeployVaults {
    using stdJson for string;

    function run() public override {
        vm.startBroadcast(privateKey);
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        TimelockVestVaultFactory factory = new TimelockVestVaultFactory(
            STAKING_CONTRACT,
            VALIDATOR_WHITELIST,
            UNLOCK_DURATION_MONTHS,
            CLIFF_DURATION_MONTHS,
            CLIFF_UNLOCK_PERCENTAGE,
            STAKING_REWARD_UNLOCK_START
        );
        console2.log("Factory deployed: ", address(factory));
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

contract AddValidatorWhitelist is Script {
    uint256 private privateKey = vm.envUint("STORY_PRIVATEKEY");
    string private validatorJson = vm.envString("STORY_VALIDATORS_INPUT");
    address private validatorListOwner = vm.envAddress("STORY_DEPLOYER_ADDRESS");
    address private VALIDATOR_WHITELIST = vm.envAddress("STORY_VALIDATOR_WHITELIST");

    function run() public {
        vm.startBroadcast(privateKey);
        _deploy();
        vm.stopBroadcast();
    }

    function _deploy() internal {
        console2.log("Whitelist Address: ", VALIDATOR_WHITELIST);
        ValidatorWhitelist whitelist = ValidatorWhitelist(VALIDATOR_WHITELIST);

        console2.log("Reading validators list file: ", validatorJson);
        string memory json = vm.readFile(validatorJson);
        bytes[] memory validators = vm.parseJsonBytesArray(json, ".validators");
        for (uint256 i = 0; i < validators.length; i++) {
            whitelist.addValidator(validators[i]);
            console2.log("Validator added: ", vm.toString(validators[i]));
        }
    }
}

contract DeployVaultsWithFactory is DeployVaults {
    using stdJson for string;

    TimelockVestVaultFactory private factory = TimelockVestVaultFactory(_getFactoryAddress());

    function _deploy(Allocation[] memory allocations) internal override {
        for (uint256 i = 0; i < allocations.length; i++) {
            Allocation memory allocation = allocations[i];
            bytes32 beneficiaryHash = _toHash(allocation.beneficiary);
            address vault = factory.createVault{ value: 1 ether }(beneficiaryHash, allocation.lockedAmount);
            output = vm.serializeAddress("", vm.toString(allocation.beneficiary), address(vault));
            console2.log("Vault deployed: ", address(vault));
        }
        vm.writeJson(output, allocationOutput, ".results");
    }

    function _getFactoryAddress() internal view virtual returns (address) {
        return vm.envAddress("STORY_VAULT_FACTORY");
    }
}