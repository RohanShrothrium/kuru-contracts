# Kuru - A Fully Onchain Central Limit Order Book

Kuru is a fully onchain CLOB with backstop liquidity features. This combines the best of TradFi and DeFi together in order to trade both long-tail and short-tail assets seamlessly. 

## Scope

All contracts in the `contracts/` directory including files in the subdirectories, except [BitMath.sol](contracts/libraries/BitMath.sol) and [KuruUtils.sol](contracts/periphery/KuruUtils.sol).

## Architecture

The [Kuru Router](contracts/Router.sol) governs all the markets- it is the default owner of all markets and can be used to upgrade markets to a new implementation. It also stores market params for every market and hence can be easily used to route through markets. The [Kuru Margin Account](contracts/MarginAccount.sol) takes care of all accounting related to limit orders and backstop liquidity AMMs. 

Each market on Kuru comprises of an OrderBook and discretised AMM liquidity. Simply said, you can discretise a CPAMM and transform it into an OrderBook if you calculate the amount of tokens which have to flow in or out between two price points. The OrderBook contract treats the AMM liquidity as a first-class citizen, so it can aggregate between limit orders on the book and the AMM liquidity while maintaining price priority. 

All limit orders on Kuru maintain price-time priority, i.e, incoming orders match on the best price available, with first-in-first-out fill priority. The prices are stored in a bitmap-based [tree](contracts/libraries/TreeMath.sol) which allows us to fetch best price at O(1) complexity. All orders for a specific price point are stored in a double-linked-list, and therefore order matching is at O(n) complexity. 

Markets on Kuru need to be initialized with a given set of parameters which suit the base/quote pair. You will find recommendations on how to set these in the same repo. If you are going YOLO, please note that a low `sizePrecision` will wreck the backstop liquidity and wrong `pricePrecision` might make it impossible to place limit orders on certain pairs. 

Since matching is done fully onchain, taker orders essentially 'crank' maker orders and credit the outputs to the makers. Hence, to avoid potential DOS, we use the margin account for all debits and credits related to limit orders. However, taker orders can choose which path they want to take.

## Known Issues

### Accumulated rounding loss on fragmented flip order fills

This is a potential DOS vector only if the price and size precisions are unfavourably set. In a well-configured market, the cost of DOS will be well above the damage caused to makers, and hence, is not economically viable.

### Out of order execution user requests on KuruForwarder

The Kuru Forwarder contract allows users to pass requests which do not steadily increase by 1, i.e, users do not have to pass requests with nonces as 1,2,3...n. Instead, it allows any request as long as the request nonce is equal to or larger than the stored user nonce. This is intentional, as now makers can submit transactions without being nonce-aware by just setting the nonce as the current timestamp. 

### A market can be DOSed if a user spams it with a large number of orders

This is only feasible if the `minSize` of the market is set very low. A well-configured market should have a large enough `minSize` such that the market cannot be DOSed. 

### Vault can leak value to arbitrage due to deposit rebalancing

Since we do not reinvest fees generated from the backstop liquidity vault back into the pool like normal CPAMMs do, the vault can be imbalanced at times. Due to this, actors performing arbitrage can execute a zero-slippage swap by doing a deposit and withdraw. However, since this just makes the vault rebalance, we do not consider this an issue to the protocol. 

