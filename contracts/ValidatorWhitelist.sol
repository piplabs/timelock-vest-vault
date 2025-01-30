// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IValidatorWhitelist } from "./interfaces/IValidatorWhitelist.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title ValidatorWhitelist
/// @notice Manages a set of whitelisted validators for the network.
///         Controlled by an authorized owner or multisig for secure updates.
contract ValidatorWhitelist is IValidatorWhitelist, Ownable2Step {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    EnumerableSet.Bytes32Set private _whitelist;
    mapping(bytes32 => bytes) private _allValidators;

    constructor(address _admin) Ownable(_admin) {}

    /// @notice Checks if a validator address is whitelisted.
    /// @param validator The address of the validator.
    /// @return True if the validator is whitelisted.
    function isValidatorWhitelisted(bytes calldata validator) external view override returns (bool) {
        return _whitelist.contains(_bytesToHash(validator));
    }

    /// @notice Adds a validator to the whitelist.
    /// @param validator The address of the validator.
    function addValidator(bytes calldata validator) external override onlyOwner {
        bytes32 validatorHash = _bytesToHash(validator);
        require(!_whitelist.contains(validatorHash), "Validator already whitelisted");
        _whitelist.add(validatorHash);
        _allValidators[validatorHash] = validator;
        emit ValidatorAdded(validatorHash, validator);
    }

    /// @notice Removes a validator from the whitelist.
    /// @param validator The address of the validator.
    function removeValidator(bytes calldata validator) external override onlyOwner {
        bytes32 validatorHash = _bytesToHash(validator);
        require(_whitelist.contains(validatorHash), "Validator is not whitelisted");
        _whitelist.remove(validatorHash);
        delete _allValidators[validatorHash];
        emit ValidatorRemoved(validatorHash,validator);
    }

    /// @notice Returns all whitelisted validators.
    /// @return An array of validator addresses.
    function getAllWhitelistedValidators() external view override returns (bytes[] memory) {
        bytes[] memory validators = new bytes[](_whitelist.length());
        for (uint256 i = 0; i < _whitelist.length(); i++) {
            validators[i] = _allValidators[_whitelist.at(i)];
        }
        return validators;
    }

    function _bytesToHash(bytes memory b) internal pure returns (bytes32) {
        return keccak256(b);
    }
}