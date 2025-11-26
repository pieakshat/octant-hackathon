## Yield MM

Yield MM is a market-making + lending strategy vault designed for users who want both lending yield and swap fees without manually managing liquidity. The system is built on:

- **Octant v2 multistrategy vaults** (one vault per asset),
- **Aave** for base yield, and
- **A Uniswap v4 CoW hook** that only provides liquidity when a large order arrives.

The current deployment targets the WETH/USDC pair on Ethereum mainnet, but the flow generalises to any pair the vault system supports.

### Core Flow

1. **Deposit** – Users supply USDC or WETH into the corresponding vault and receive ERC4626-style shares. Vaults route capital into Aave strategies for passive yield.
2. **CoW evaluation** – When Uniswap sees a large swap, the hook validates the order (size, token support, vault liquidity).
3. **Liquidity sourcing** – The hook instructs the out-strategy to withdraw just enough tokens from Aave (`pullFundsForSwap`). Idle balances avoid price impact.
4. **Filling the order** – The hook sends the requested asset to the trader, receives the counter-asset, charges a 50 bps fee, and deposits the net amount into the paired strategy.
5. **Settlement** – To preserve Uniswap pool invariants, the hook calls `poolManager.take` (repay input token) and `poolManager.sync/settle` (deliver output token). LP reserves and price remain unchanged; only vault balances move.
6. **Redeem** – When a depositor withdraws, vaults either return idle assets or use `ExactOutputSwapRouter` to swap the paired asset back, guaranteeing fast redemptions.

```
User               SwapRouter           PoolManager             CoWHook            Strategies (Aave)
 | swap X for Y        |                      |                       |                        |
 |-------------------->| unlock + swap        |---------------------->| beforeSwap check       |
 |                     |                      |                       | withdraw liquidity ----+
 |                     |                      |                       |<--- from paired strategy
 |                     |                      |                       | afterSwap settle        |
 |<--------------------| receive output       |<----------------------| take/sync + redeposit   |
```

### Design Considerations

- **Composability first** – The CoW hook, Octant vaults, and Aave strategies were implemented independently, then stitched together with integration tests (hook ↔ vault ↔ user ↔ vault).
- **Paired vault coordination** – Each asset has its own vault, but they operate as a pair. If USDC is depleted after a large swap, the WETH vault can swap back to USDC before honouring redemptions.
- **Withdrawal guarantees** – Early prototypes assumed idle USDC was sufficient. After feedback, an exact-output router was introduced so the WETH strategy can repurchase USDC deterministically before releasing funds to users.

Yield MM lets any depositor act like a professional market maker: capital earns Aave yield by default, steps in only when Uniswap needs large liquidity, and captures fees without harmful price impact.

## Repository Layout

- `src/`
  - `CoWHook/CoWHook.sol` – Uniswap v4 hook that orchestrates CoW fills, strategy withdrawals, fee accounting, and pool settlement.
  - `CoWHook/interfaces/IAaveStrategy.sol` – minimal interface used by the hook to interact with strategy contracts.
  - `strategies/AaveStrategy.sol` – Octant strategy wrapper responsible for supplying/withdrawing against Aave and coordinating with partner strategies.
  - `routers/ExactOutputSwapRouter.sol` – helper router used during withdrawals to source the paired asset with an exact-output swap.
  - `interfaces/IExactOutputSwapRouter.sol` – interface for the router above.
- `test/`
  - `fullTest.t.sol` – integration tests covering deposits, swaps, and rebalancing behaviour.
  - `EndToEnd.t.sol` – full mainnet-fork scenario that deposits users, runs a trader swap, and redeems shares through the entire pipeline.
- `foundry.toml` – Foundry configuration.

## Contracts Topology

```
                         +---------------------+
                         |        Users        |
                         +---------------------+
                           /               \
                          /                 \
                         v                   v
            +---------------------+   +---------------------+
            |  USDC Vault (ovUSDC)|   |  WETH Vault (ovWETH)|
            +---------------------+   +---------------------+
                      |                           |
                      v                           v
          +---------------------+     +----------------------+
          |  AaveStrategy USDC  |<--->|  AaveStrategy WETH   |
          +---------------------+     +----------------------+
                      \                           /
                       \                         /
                        v                       v
                         +---------------------+
                         |       CoW Hook      |
                         +---------------------+
                                       |
                                       v
                         +-----------------------------+
                         |   Uniswap v4 Pool Manager   |
                         +-----------------------------+
```

- Users deposit USDC/WETH into the relevant multistrategy vault.
- Vaults forward liquidity to their Aave strategies, which coordinate via the paired strategy link.
- When a swap hits the pool, the CoW hook decides whether it qualifies as “large”, pulls liquidity from the appropriate strategy, and settles everything back through the Uniswap v4 pool manager. 



User's router calls poolManager.swap()
Pool Manager calls hook.beforeSwap()
Hook returns BeforeSwapDelta:
deltaSpecified = +amountIn (in exact input) tells the pool not to swap input tokens
deltaUnspecified = -amountOut indicates the user should receive amountOut
Pool Manager modifies amountToSwap:
amountToSwap += deltaSpecified → becomes 0, so no pool swap
Pool Manager accounts a BalanceDelta to the user (they should receive amountOut)
Pool Manager calls hook.afterSwap()
Hook transfers output tokens to Pool Manager:
poolManager.sync() + transfer() + poolManager.settle()
User's router calls poolManager.take() to receive the tokens
User's router calls poolManager.settle() to pay input tokens
Why this works
BeforeSwapDelta sets accounting: the user will receive amountOut.
Hook supplies tokens: _afterSwap transfers tokens to Pool Manager.
Router collects: poolManager.take() transfers tokens to the user.
The hook effectively pre-executes the swap and ensures tokens are available when the router calls take().