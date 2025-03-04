# Time-Lock Vest Vault (TLV2)

Time-Lock Vest Vault (TLV2) provides a secure and flexible solution for time-locked token vesting by deploying an individual vault contract for each beneficiary. This design enhances control over vesting schedules while supporting validator whitelisting to secure the process. Detailed insights into the architecture and implementation can be found in the [Design Document](https://storyprotocol.notion.site/Time-Lock-Vest-Vault-TLV2-Design-Document-177051299a54805681bbe3072bfbc088).

## Features

- **Individual Vault Contracts:** Each beneficiary receives a dedicated vault contract to enforce customized vesting schedules.
- **Validator Whitelisting:** A secure whitelist mechanism ensures that only approved validators participate in the system.
- **Scripted Deployment:** Deployment is automated via Foundry scripts, minimizing manual intervention and potential errors.
- **Environment-Driven Configuration:** Easily manage deployment settings and contract parameters using environment variables.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) (forge) for compiling and deploying smart contracts.
- A Unix-based terminal or compatible shell environment.
- Basic familiarity with Ethereum development and contract deployment.

## Repository Setup

1. **Clone the Repository**

   ```bash
   git clone https://github.com/piplabs/timelock-vest-vault.git
   cd timelock-vest-vault
   ```

2. **Install Dependencies** Follow Foundry's [installation guidelines](https://book.getfoundry.sh/getting-started/installation) to set up forge and any other necessary tools.

3. **Configure Environment Variables** Duplicate the provided environment template:

   ```bash
   cp .env.example .env
   ```

   Update the variables in your `.env` file as needed:

    - `STORY_DEPLOYER_ADDRESS`: Your deployer address.
    - `STORY_PRIVATEKEY`: Private key for signing transactions.
    - `STORY_ALLOCATIONS_INPUT`: Path to the JSON file containing beneficiary allocations (e.g., `allocations/sample-allocations.json`).
    - `STORY_ALLOCATIONS_OUTPUT`: Path for output data after processing allocations (e.g., `allocations/sample-allocations-output.json`).
    - `STORY_VALIDATORS_INPUT`: Path to the JSON file with validator details (e.g., `allocations/sample-validators.json`).
    - `STORY_RPC`: RPC endpoint (e.g., `https://aeneid.storyrpc.io`).
    - `VERIFIER_URL`: URL for contract verification (e.g., `https://aeneid.storyscan.xyz/api`).

## Deployment Instructions

### 1. Deploy Validator Whitelist

This step deploys the validator whitelist contract, ensuring only approved validators can interact with the system.

Run the following command:

```bash
forge script script/Deploy.s.sol:DeployValidatorWhitelist \
  --fork-url ${STORY_RPC} \
  --broadcast \
  --priority-gas-price 1 \
  --slow \
  --legacy \
  --verify \
  --verifier=blockscout \
  --verifier-url=${VERIFIER_URL}
```

- **Parameters Explained:**
    - `--fork-url ${STORY_RPC}`: Connects to the specified RPC endpoint.
    - `--broadcast`: Sends the transaction to the network.
    - `--priority-gas-price 1`: Sets the priority gas price.
    - `--slow` and `--legacy`: Adjust transaction parameters for network conditions.
    - `--verify`: Enables contract verification.
    - `--verifier=blockscout` and `--verifier-url=${VERIFIER_URL}`: Specifies the verification service.

### 2. Deploy Vault Contracts

Deploy vault contracts for each beneficiary using the allocation data provided in the environment variables.

Execute the command:

```bash
forge script script/Deploy.s.sol:DeployVaults \
  --fork-url ${STORY_RPC} \
  --broadcast \
  --priority-gas-price 1 \
  --slow \
  --legacy \
  --verify \
  --verifier=blockscout \
  --verifier-url=${VERIFIER_URL}
```

- **Key Points:**
    - Each beneficiary defined in the allocation JSON file receives its own vault contract.
    - The deployment script reads the input data, processes allocations, and outputs results to the specified file.
    - The configuration ensures that vesting schedules are correctly enforced as per the updated design.

## Testing and Interaction

- **Testing:** Run the built-in tests with:
  ```bash
  forge test
  ```
- **Interacting with Deployed Contracts:** Use Ethereum interaction libraries like Ethers.js or web3.js to interact with the deployed vault contracts. The individual contracts allow for detailed management of each beneficiary's vesting schedule.

## Additional Information

For further technical details and rationale behind architectural decisions, consult the [TLV2 Design Document](https://storyprotocol.notion.site/Time-Lock-Vest-Vault-TLV2-Design-Document-177051299a54805681bbe3072bfbc088). This document provides insights into the design changes and benefits of having a vault contract per beneficiary.

## Contributing

Contributions are welcome. Follow standard Git workflows and ensure that tests pass before opening a pull request.

## License

This project is released under the [MIT License](LICENSE).

## Application

An website has been developed to facilitate the operation of the vault. https://tlv.story.foundation

A screenshot of the website is here. ![screencapture-tlv-story-foundation-0xF1388F2F2aBb479819573150188A6524027498f4-2025-02-22-21_54_30](https://github.com/user-attachments/assets/a639e37c-98ab-44ee-aeaa-3e195bfed797)
