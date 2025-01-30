// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IValidatorWhitelist {
    // Events
    event ValidatorAdded(bytes32 indexed validatorHash, bytes validator);
    event ValidatorRemoved(bytes32 indexed validatorHash,bytes validator);

    // Functions
    /// @notice Returns true if the validator is whitelisted
    /// @param validator The 33 bytes compressed public key of the validator
    /// @return true if the validator is whitelisted otherwise false
    function isValidatorWhitelisted(bytes calldata validator) external view returns (bool);

    /// @notice Adds a validator to the whitelist
    /// @param validator The 33 bytes compressed public key of the validator
    function addValidator(bytes calldata validator) external;

    /// @notice Removes a validator from the whitelist
    /// @param validator The33 bytes compressed public key of the validator
    function removeValidator(bytes calldata validator) external;

    /// @notice Returns all whitelisted validators
    /// @return all whitelisted validators
    function getAllWhitelistedValidators() external view returns (bytes[] memory);
}