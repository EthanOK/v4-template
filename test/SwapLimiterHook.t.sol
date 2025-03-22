// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks, CustomRevert} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager, IERC6909Claims} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {SwapLimiterHook} from "../src/SwapLimiterHook.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

contract SwapLimiterHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    SwapLimiterHook hook;
    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(Hooks.BEFORE_SWAP_FLAG) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager); // Add all the necessary constructor arguments from the hook
        deployCodeTo("SwapLimiterHook.sol:SwapLimiterHook", constructorArgs, flags);
        hook = SwapLimiterHook(flags);

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 100_000 * 1e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        uint256 currency0_before = currency0.balanceOf(address(this)) / 1e18;

        console2.log("User address: ", address(this));

        console2.log("User balance in currency0 before minting: ", currency0_before);

        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );

        console2.log("posm Token ID: ", tokenId);

        uint256 currency0_after = currency0.balanceOf(address(this)) / 1e18;

        console2.log("User balance in currency0 after minting: ", currency0_after);

        console2.log("mint pool Amount of currency0 spent: ", currency0_before - currency0_after);

        console2.log("User address: ", address(this));
        console2.log("SwapLimiterHook address: ", address(hook));
        console2.log("SwapRouter address: ", address(swapRouter));
        console2.log("PoolManager address: ", address(manager));
    }

    function testSwapHook() public {
        assertEq(hook.getRemainingSwaps(address(swapRouter)), 5);

        uint256 remainingSwaps;
        // Perform a test swap
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative number indicates exact input swap!

        address user = address(this);
        bytes memory hookData = abi.encode(user);

        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 100);
            // Perform a test swap //
            zeroForOne = !zeroForOne;
            amountSpecified = -1e18; // negative number indicates exact input swap!
            console2.log("Start Swap Number: ", i + 1);

            // SwapLimiterHookTest contract call swapRouter to swap
            swap(key, zeroForOne, amountSpecified, hookData);

            remainingSwaps = hook.getRemainingSwaps(address(user));

            console2.log("End Swap Time: ", block.timestamp);
            console2.log("Remaining Swap Count in 1 Hours: ", remainingSwaps);
            console2.log("-----------------");

            assertEq(remainingSwaps, 4 - i);
        }

        console2.log("Start Swap Number: ", uint256(5));
        vm.warp(block.timestamp + 100);

        vm.expectEmit(true, true, true, true);
        emit SwapLimiterHook.SwapLimitReached(address(user), block.timestamp);

        swap(key, zeroForOne, amountSpecified, hookData);

        remainingSwaps = hook.getRemainingSwaps(address(user));

        console2.log("End Swap Time: ", block.timestamp);
        console2.log("Remaining Swap Count in 1 Hours: ", remainingSwaps);
        console2.log("-----------------");

        assertEq(remainingSwaps, 0);

        console2.log("Start Swap Number: ", uint256(6));
        vm.warp(block.timestamp + 100);
        // error WrappedError(address target, bytes4 selector, bytes reason, bytes details);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hook,
                IHooks.beforeSwap.selector,
                abi.encodePacked(SwapLimiterHook.SwapLimitExceeded.selector),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );

        swap(key, zeroForOne, amountSpecified, hookData);

        console2.log("Revert SwapLimitExceeded");
        console2.log("-----------------");

        vm.warp(block.timestamp + 3600);
        console2.log("Wait For 1 Hour, Now Time: ", block.timestamp);

        remainingSwaps = hook.getRemainingSwaps(address(user));

        console2.log("Remaining Swap Count in 1 Hours: ", remainingSwaps);
        console2.log("-----------------");

        console2.log("Currency0 Swap To Currency1");
        console2.log("Set takeClaims to `true`, will Mint Currency1 ERC6909 To User");

        // takeClaims = true
        // mint ERC6909 Token to user, instead of transfer ERC20 Token to user

        zeroForOne = true;
        amountSpecified = 1e18;

        uint256 currency_id = currency1.toId();

        uint256 balance_erc6909_user_before = manager.balanceOf(user, currency_id);

        vm.expectEmit(true, true, true, true, address(manager));
        emit IERC6909Claims.Transfer(address(swapRouter), address(0), user, currency_id, uint256(amountSpecified));

        swapToken(key, zeroForOne, amountSpecified, hookData, true);

        uint256 balance_erc6909_user_after = manager.balanceOf(user, currency_id);

        console2.log(
            "Mint Currency1 ERC6909 To User Balance Change: ",
            uint256(balance_erc6909_user_after - balance_erc6909_user_before)
        );

        assertEq(balance_erc6909_user_after - balance_erc6909_user_before, uint256(amountSpecified));
    }

    /// @notice Helper function for a simple ERC20 swaps
    /// @param zeroForOne true if currency0 to currency1, false if currency1 to currency0
    /// @param amountSpecified the desired input amount if negative (exactIn), or the desired output amount if positive (exactOut)
    /// @param hookData The data to pass through to the swap hooks
    /// @param takeClaims true if mint ERC6909, false if transfer ERC20
    /// @return swapDelta The balance delta of the address swapping
    function swapToken(
        PoolKey memory _key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory hookData,
        bool takeClaims
    ) internal returns (BalanceDelta) {
        // allow native input for exact-input, guide users to the `swapNativeInput` function
        bool isNativeInput = zeroForOne && _key.currency0.isAddressZero();
        if (isNativeInput) require(0 > amountSpecified, "Use swapNativeInput() for native-token exact-output swaps");

        uint256 value = isNativeInput ? uint256(-amountSpecified) : 0;

        return swapRouter.swap{value: value}(
            _key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: takeClaims, settleUsingBurn: false}),
            hookData
        );
    }
}
