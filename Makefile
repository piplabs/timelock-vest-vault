-include .env

.PHONY: all test clean

all: clean install build

# function: generate abi for given contract name (key)
# requires contract name to match the file name
define generate_abi
    $(eval $@_CONTRACT_NAME = $(1))
		$(eval $@_CONTRACT_PATH = $(2))
		forge inspect --optimize --optimizer-runs 20000 contracts/${$@_CONTRACT_PATH}/${$@_CONTRACT_NAME}.sol:${$@_CONTRACT_NAME} abi > abi/${$@_CONTRACT_NAME}.json
endef



# Clean the repo
forge-clean  :; forge clean
clean  :; npx hardhat clean

# Remove modules
forge-remove :; rm -rf .gitmodules && rm -rf .git/modules/* && rm -rf lib && touch .gitmodules && git add . && git commit -m "modules"

install :; npm install

# Update Dependencies
forge-update:; forge update

forge-build:; forge build
build :; npx hardhat compile

test :; forge test

snapshot :; forge snapshot

slither :; slither ./contracts

format :; npx prettier --write contracts/**/*.sol && npx prettier --write contracts/*.sol

# solhint should be installed globally
lint :; npx solhint contracts/**/*.sol && npx solhint contracts/*.sol

deploy-goerli :; npx hardhat run ./script/deploy-reveal-engine.js --network goerli
verify-goerli :; npx hardhat verify --network goerli ${contract}

anvil :; anvil -m 'test test test test test test test test test test test junk'

abi:
	rm -rf abi
	mkdir -p abi
	@$(call generate_abi,"StakeRewardReceiver",".")
	@$(call generate_abi,"TimelockVestVault",".")
	@$(call generate_abi,"ValidatorWhitelist",".")

