# Cross-Chain Swap Demo: Arbitrum → Sui

## Prerequisites

1. **Node.js** v18+ installed
2. **pnpm** installed (`npm install -g pnpm`)
3. **Foundry** installed (for fork testing): `curl -L https://foundry.paradigm.xyz | bash`
4. **Funded accounts** (see requirements below)
5. **Environment variables** configured

## Account Requirements

### Arbitrum Mainnet (REAL FUNDS!)
- **User Account**: 
  - 1+ USDC for swapping
  - 0.002+ ETH for gas fees
- **Resolver Account**:
  - 0.002+ ETH for gas fees (deployment + operations)

### Sui Testnet
- **User Account**: 
  - 0.1+ SUI for receiving funds
- **Resolver Account**:
  - 1+ SUI for gas and safety deposits

## Setup Steps

### 1. Install Dependencies
```bash
pnpm install
```

### 2. Configure Environment
Copy `.env.example` to `.env` and fill in:
```bash
# Arbitrum RPC (get from Alchemy/Infura)
ARBITRUM_RPC=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY

# Private keys (64 hex chars without 0x prefix)
EVM_USER_PRIVATE_KEY=...
EVM_RESOLVER_PRIVATE_KEY=...
SUI_USER_PRIVATE_KEY=...
SUI_RESOLVER_PRIVATE_KEY=...
```

### 3. Check Account Balances
```bash
pnpm run check-accounts
```
This will show you which accounts need funding.

## Testing on Fork First (Recommended!)

Before running on mainnet, test on a local fork:

```bash
pnpm run demo:fork
```

This will:
1. Start a local Arbitrum fork using Anvil
2. Fund test accounts automatically
3. Run the full demo without using real funds
4. Clean up when done

## Running on Mainnet

### 1. Fund Your Accounts

#### Arbitrum Mainnet:
1. Send ETH to both accounts from an exchange or bridge
2. Buy USDC on [Uniswap](https://app.uniswap.org) or bridge from Ethereum
3. USDC Contract: `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`

#### Sui Testnet:
1. Get SUI from the [testnet faucet](https://discord.gg/sui)
2. Or use the web faucet at https://sui.io/faucet

### 2. Compile Contracts (if needed)
```bash
# If you haven't compiled the EVM contracts yet
forge build
```

### 3. Run the Demo
```bash
pnpm run demo:evm-to-sui
```

## What Happens

1. **Contract Deployment** (first run only)
   - Deploys EscrowFactory and Resolver contracts on Arbitrum

2. **Order Creation**
   - User creates a 1 USDC swap order
   - Order is signed with EIP-712

3. **Source Escrow** (Arbitrum)
   - Resolver fills the order through 1inch LOP
   - Creates escrow locking the USDC

4. **Destination Escrow** (Sui)
   - Resolver creates matching escrow on Sui
   - Locks equivalent value

5. **Secret Sharing**
   - After both escrows are confirmed
   - Secret is revealed to enable withdrawals

6. **Withdrawals**
   - User receives funds on Sui
   - Resolver receives funds on Arbitrum

## Gas Costs (Approximate)

### Arbitrum Mainnet:
- Contract deployment: ~0.001 ETH (one time)
- Order fill + escrow: ~0.0005 ETH
- Withdrawal: ~0.0002 ETH
- **Total**: ~0.002 ETH per swap (after contracts deployed)

### Sui Testnet:
- Escrow creation: ~0.01 SUI
- Withdrawal: ~0.01 SUI

## Troubleshooting

### "Insufficient funds" error
- Run `pnpm run check-accounts` to see what's missing
- Make sure you have enough ETH/SUI for gas fees

### "Nonce too high" error
- Reset your nonce or wait for pending transactions

### Contract deployment fails
- Ensure resolver account has enough ETH (0.002+ recommended)

### Sui transaction fails
- Check that the package ID in .env matches your deployed package
- Ensure sufficient SUI balance for gas

### Fork testing issues
- Make sure Foundry is installed: `curl -L https://foundry.paradigm.xyz | bash`
- Check that Anvil is in your PATH
- Ensure your Arbitrum RPC URL is valid

## Important Notes

⚠️ **When using mainnet, this uses REAL FUNDS!**
- Only use amounts you can afford to lose
- Double-check all addresses
- Test with fork first!

## Scripts

- `pnpm run check-accounts` - Check all account balances
- `pnpm run demo:fork` - Test on local Arbitrum fork (no real funds)
- `pnpm run demo:evm-to-sui` - Run the mainnet demo
- `pnpm run compile` - Compile Solidity contracts (if using Foundry)

