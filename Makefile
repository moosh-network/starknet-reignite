# Makefile for moosh_id project

# --- Load Environment Variables ---
# This allows Starkli to pick up STARKNET_PRIVATE_KEY and STARKNET_RPC automatically
ifneq (,$(wildcard .env))
    include .env
    export
endif

# --- Configuration ---
VENV_DIR = .venv
FALCON_DIR = falcon
PYTHON = python3
VENV_PYTHON = $(VENV_DIR)/bin/python
VENV_PIP = $(VENV_DIR)/bin/pip
N = 512  # Default polynomial degree

# Starknet Config
PROJECT_DIR = moosh_id
# Update this filename if Scarb output differs (e.g. just moosh_id.contract_class.json)
SIERRA_FILE = $(PROJECT_DIR)/target/dev/moosh_id_FalconSignatureVerifier.contract_class.json
ACCOUNT_FILE = target/account.json

# Directories
TARGET_DIR = target
KEY_DIR = $(TARGET_DIR)/keys
MSG_DIR = $(TARGET_DIR)/messages
KEY_FILE = $(KEY_DIR)/key_n$(N).json
MSG_FILE = $(MSG_DIR)/msg_n$(N).json

.PHONY: all setup clean test key generate-arguments starkli-account starkli-deploy

# Create and setup virtual environment
venv:
	$(PYTHON) -m venv $(VENV_DIR)
	$(VENV_PIP) install --upgrade pip

# Install Python dependencies
install-deps: venv
	$(VENV_PIP) install --upgrade setuptools wheel
	$(VENV_PIP) install -r requirements.txt

# Alias setup to install-deps (fixes missing rule for 'key')
setup: install-deps

# Setup dependencies and build cairo
build: install-deps
	$(VENV_PIP) install -e $(FALCON_DIR)
	cd $(PROJECT_DIR) && scarb build

# Create necessary directories
$(KEY_DIR):
	mkdir -p $(KEY_DIR)

$(MSG_DIR):
	mkdir -p $(MSG_DIR)

# Generate key only
generate-arguments: $(KEY_DIR)
	$(VENV_PYTHON) scripts/generate_inputs.py --n 512 --num_signatures 1
	$(VENV_PYTHON) scripts/generate_inputs.py --n 1024 --num_signatures 1
	@echo "Key generated."

# Generate and register a key
key: setup
	cd $(PROJECT_DIR) && scarb test test_keyregistry

# Run all tests
test: key
	cd $(PROJECT_DIR) && scarb test

test-only:
	cd $(PROJECT_DIR) && scarb test

# Clean up
clean:
	rm -rf $(TARGET_DIR)
	rm -rf $(VENV_DIR)
	cd $(PROJECT_DIR) && scarb clean

python-shell:
	nix-shell -p python311

app:
	$(VENV_PYTHON) scripts/app.py

# --- Starknet Deployment (Targeted) ---

# 1. Fetch Account Config (Creates account.json using address from .env)
starkli-account:
	@if [ -z "$(STARKNET_ADDRESS)" ]; then echo "Error: STARKNET_ADDRESS not set in .env"; exit 1; fi
	starkli account fetch $(STARKNET_ADDRESS) --output $(ACCOUNT_FILE)

# 2. Deploy
# Usage: make starkli-deploy REGISTRY_ADDRESS=0x...
# Dependencies: Requires 'account.json' (make starkli-account) and the built Sierra file.
starkli-deploy:
	@if [ ! -f "$(SIERRA_FILE)" ]; then echo "Error: Sierra file not found at $(SIERRA_FILE). Run 'make build' first."; exit 1; fi
	@if [ -z "$(REGISTRY_ADDRESS)" ]; then echo "Error: REGISTRY_ADDRESS not set. Usage: make starkli-deploy REGISTRY_ADDRESS=0x..."; exit 1; fi
	@echo "--- Declaring Class ---"
	$(eval CLASS_HASH := $(shell starkli declare $(SIERRA_FILE) --account $(ACCOUNT_FILE) --watch | grep -o '0x[0-9a-fA-F]\{63,64\}' | tail -n 1))
	@echo "Class Hash: $(CLASS_HASH)"
	@echo "--- Deploying Contract ---"
	starkli deploy $(CLASS_HASH) $(REGISTRY_ADDRESS) --account $(ACCOUNT_FILE)