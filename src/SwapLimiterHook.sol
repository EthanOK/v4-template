// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {Hooks, CustomRevert} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

contract SwapLimiterHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CustomRevert for bytes4;

    error SwapLimitExceeded();

    uint256 public constant MAX_SWAPS_PER_HOUR = 5;
    uint256 public constant HOUR = 3600;

    event SwapLimitReached(address indexed user, uint256 timestamp);

    mapping(address => uint256) public lastResetTime;
    mapping(address => uint256) public swapCount;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeSwap(
        address, /* sender */
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 currentTime = block.timestamp;

        (address sender) = abi.decode(hookData, (address));

        if (currentTime - lastResetTime[sender] > HOUR) {
            swapCount[sender] = 0;
            lastResetTime[sender] = currentTime;
        }

        // require(swapCount[sender] < MAX_SWAPS_PER_HOUR, "Swap limit exceeded");
        if (swapCount[sender] >= MAX_SWAPS_PER_HOUR) {
            revert SwapLimitExceeded();
        }

        swapCount[sender]++;

        if (swapCount[sender] == MAX_SWAPS_PER_HOUR) {
            emit SwapLimitReached(sender, currentTime);
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function getRemainingSwaps(address user) public view returns (uint256) {
        uint256 currentTime = block.timestamp;
        if (currentTime - lastResetTime[user] > HOUR) {
            return MAX_SWAPS_PER_HOUR;
        }
        return MAX_SWAPS_PER_HOUR - swapCount[user];
    }
}
