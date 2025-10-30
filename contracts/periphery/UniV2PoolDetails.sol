// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
}

contract UniV2PoolDetails {
    struct PoolInfo {
        address token0;
        address token1;
        address factory;
    }

    function getPoolDetails(
        address[] calldata pools
    ) external view returns (PoolInfo[] memory) {
        PoolInfo[] memory poolInfos = new PoolInfo[](pools.length);

        for (uint256 i = 0; i < pools.length; i++) {
            IUniswapV2Pair pair = IUniswapV2Pair(pools[i]);
            poolInfos[i] = PoolInfo({
                token0: pair.token0(),
                token1: pair.token1(),
                factory: pair.factory()
            });
        }

        return poolInfos;
    }
}
