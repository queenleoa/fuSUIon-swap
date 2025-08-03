You can find the move package at : 
How it’s made

Sui Move package (escrow/)

Core objects

Wallet<T> (shared): funds + immutables — order_hash, salt, maker/taker strings, making_amount (start/high), taking_amount (end/low), duration, hashlock/Merkle root, allow_partial_fills, parts_amount, last_used_index, timelocks, created_at, is_active, and balances (token + SUI safety deposits).

EscrowSrc<T> / EscrowDst<T> (shared): per-resolver escrows with compact EscrowImmutables, token balance, safety deposit, created_at, status.

Timelocks: relative ms windows for staged withdraw/cancel: resolver-exclusive → public on both chains.

Lifecycle modules

escrow_create.move: create_wallet (maker pre-funds) and create_escrow_src (resolver debits Wallet). Validates Merkle proof or hashlock, current Dutch price, balances, and safety deposits, then emits events.

escrow_withdraw.move / escrow_cancel.move: stage-gated flows using clock::timestamp_ms + relative timelocks; full fills require secret; partial fills verify (leaf, proof, index) against the Wallet’s Merkle root; public phases unlock after grace windows.

escrow_rescue.move: post-public-cancel cleanup to reclaim storage rebates and tear down Wallet/Escrow.

escrow_utils.move: Dutch-auction math (1inch-style linear interpolation), get_making_amount/get_taking_amount, timelock validation (monotonicity + cross-chain ordering), stage computation, and immutables checks.

escrow_events.move: lightweight, copy-only events for creation/withdraw/cancel.

Testing

Move tests cover: multi-part partial fills (bucketed indices), Merkle proof validation, Dutch pricing at time t, resolver/public stage transitions, safety-deposit thresholds, cancel/withdraw correctness, and rescue.

Off-chain orchestration (TypeScript, tests/)

Sui PTB path (sui-integration.ts): builds Programmable Transaction Blocks to create wallets/escrows and execute withdraw/cancel per stage; signs with user/resolver keys; polls finality.

Order builder (cross-chain-order-builder.ts): generates secrets + keccak256 hashlocks, computes auction bounds; falls back to manual hashing when SDK imports aren’t available.

EVM helpers (evm-wallet.ts): ethers-based balance/approval/tx utilities. Destination leg interacts with Solidity contracts that use factory + minimal-proxy patterns for gas efficiency and isolation.

Integration spec (cross-chain-integration-spec.ts & test-complete-sui-flow.ts): end-to-end flow against Arbitrum mainnet and Sui testnet—build order → create Sui Wallet → resolver fills (Sui PTB + EVM call) → withdraw/cancel/rescue.

Why these design decisions are better on Sui

Pre-funded shared Wallet<T> instead of replayable signed PTBs.
Sui PTBs are tied to object versions; a pre-funded Wallet avoids stale signatures while enabling asynchronous resolver competition. It guarantees liveness with the maker offline and gives one canonical balance/nonce/parts map to enforce fills.

Relative timelocks + on-chain stage machine.
Using relative ms windows and deriving absolute gates from clock::timestamp_ms keeps the immutables compact and avoids “creation-time drift.” It cleanly separates resolver-exclusive and public phases on both chains.

Dutch pricing computed in Move (no oracle).
The module recomputes the current taking/making amount from created_at+duration deterministically, so every resolver faces the same price curve—no off-chain disputes, no desync.

Merkle-root partial fills with index discipline.
Compresses N secrets to one root; each fill proves membership and advances last_used_index. This makes partial fills cheap, parallelizable, and abuse-resistant without minting per-part objects.

Safety deposits & rescue path.
Deposits align incentives (discourage spam/abandonment) and rescue reclaims storage, so long-lived orders don’t turn into permanent state bloat—a direct fit for Sui’s storage-rebate model.

Right primitive per chain.
Sui uses PTBs to mutate objects atomically at submission time; EVM uses Solidity contracts + proxies to settle fills with the familiar allowance/permit tooling. Each side leverages its chain’s strengths.