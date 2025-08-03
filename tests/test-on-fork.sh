#!/bin/bash

echo "🍴 Starting Arbitrum Mainnet Fork..."

# Check if anvil is installed
if ! command -v anvil &> /dev/null; then
    echo "❌ Anvil not found. Please install Foundry:"
    echo "   curl -L https://foundry.paradigm.xyz | bash"
    exit 1
fi

# Kill any existing anvil process
pkill anvil 2>/dev/null

# Start Anvil fork with funded accounts
echo "Starting Anvil fork of Arbitrum..."

# Get private keys from .env
source .env

# Start anvil with pre-funded accounts
anvil \
    --fork-url $ARBITRUM_RPC \
    --port 8545 \
    --accounts 4 \
    --balance 1000 \
    --mnemonic "test test test test test test test test test test test junk" &

ANVIL_PID=$!

# Wait for anvil to start
sleep 3

echo "✅ Anvil started with PID: $ANVIL_PID"
echo ""
echo "📝 Pre-funded test accounts:"
echo "   Account 0: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
echo "   Private Key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
echo ""
echo "   Account 1: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
echo "   Private Key: 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
echo ""

# Create a temporary .env.fork file
cat > .env.fork << EOF
# Fork configuration
USE_FORK=true

# Copy from main .env
ARBITRUM_RPC=http://localhost:8545
SUI_RPC=$SUI_RPC
SUI_ESCROW_PACKAGE_ID=$SUI_ESCROW_PACKAGE_ID

# Use test accounts for fork
EVM_USER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
EVM_RESOLVER_PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d

# Keep Sui accounts from main .env
SUI_USER_PRIVATE_KEY=$SUI_USER_PRIVATE_KEY
SUI_RESOLVER_PRIVATE_KEY=$SUI_RESOLVER_PRIVATE_KEY
EOF

echo "🚀 Running demo on fork..."
echo ""

# Run the demo with fork environment
env $(grep -vE '^(#|$)' .env.fork | xargs) pnpm run demo:evm-to-sui

# Cleanup
kill $ANVIL_PID 2>/dev/null
rm .env.fork

echo ""
echo "🧹 Cleaned up fork environment"