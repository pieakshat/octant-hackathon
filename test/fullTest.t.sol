// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolAddressesProvider} from "aave-v3-origin/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "aave-v3-origin/contracts/interfaces/IPool.sol";
import {DataTypes} from "aave-v3-origin/contracts/protocol/libraries/types/DataTypes.sol";

import {CoWHook} from "../src/CoWHook/CoWHook.sol";
import {AaveStrategy} from "../src/strategies/AaveStrategy.sol";
import {ExactOutputSwapRouter} from "../src/routers/ExactOutputSwapRouter.sol";
import {IExactOutputSwapRouter} from "../src/interfaces/IExactOutputSwapRouter.sol";
import {MultistrategyVault} from "octant-v2-core/core/MultistrategyVault.sol";
import {MultistrategyVaultFactory} from "octant-v2-core/factories/MultistrategyVaultFactory.sol";
import {YieldSkimmingTokenizedStrategy} from "octant-v2-core/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";

contract TestCoWHook is Test, Deployers {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant AAVE_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    uint256 internal constant LIQUIDITY_USDC = 10_000_000 * 1e6;
    uint256 internal constant LIQUIDITY_WETH = 5_000 * 1e18;
    uint256 internal constant STRATEGY_USDC = 40_000_000 * 1e6;
    uint256 internal constant STRATEGY_WETH = 20_000 * 1e18;

    uint256 internal constant TOTAL_USDC = LIQUIDITY_USDC + STRATEGY_USDC;
    uint256 internal constant TOTAL_WETH = LIQUIDITY_WETH + STRATEGY_WETH;

    Currency token0;
    Currency token1;

    CoWHook hook;
    ExactOutputSwapRouter exactOutputSwapRouter;

    AaveStrategy usdcStrategy;
    AaveStrategy wethStrategy;

    MultistrategyVault usdcVault;
    MultistrategyVault wethVault;

    IPool public aavePool;
    address public aTokenUsdc;
    address public aTokenWeth;

    YieldSkimmingTokenizedStrategy public tokenizedStrategyImplementation;

    bytes internal usdcToWethSwapData;
    bytes internal wethToUsdcSwapData;

    function setUp() public {
        _forkMainnet();
        deployFreshManagerAndRouters();
        _initializeCurrencies();
        _deployHookAndPool();
        _initializeAave();
        _deployVaultsAndStrategies();
        _configureHookRouting();
        _provideBaseLiquidity();
        _seedStrategies();
    }

    function _forkMainnet() internal {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
    }

    function _initializeCurrencies() internal {
        token0 = Currency.wrap(USDC);
        token1 = Currency.wrap(WETH);

        deal(USDC, address(this), TOTAL_USDC);
        deal(WETH, address(this), TOTAL_WETH);
    }

    function _deployHookAndPool() internal {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("src/CoWHook/CoWHook.sol:CoWHook", abi.encode(manager), hookAddress);
        hook = CoWHook(hookAddress);

        IERC20(USDC).forceApprove(hookAddress, type(uint256).max);
        IERC20(WETH).forceApprove(hookAddress, type(uint256).max);

        IERC20(USDC).forceApprove(address(modifyLiquidityRouter), type(uint256).max);
        IERC20(WETH).forceApprove(address(modifyLiquidityRouter), type(uint256).max);

        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);
    }

    function _initializeAave() internal {
        IPoolAddressesProvider provider = IPoolAddressesProvider(AAVE_ADDRESSES_PROVIDER);
        aavePool = IPool(provider.getPool());

        DataTypes.ReserveDataLegacy memory usdcReserve = aavePool.getReserveData(USDC);
        DataTypes.ReserveDataLegacy memory wethReserve = aavePool.getReserveData(WETH);

        aTokenUsdc = usdcReserve.aTokenAddress;
        aTokenWeth = wethReserve.aTokenAddress;
    }

    function _deployVaultsAndStrategies() internal {
        tokenizedStrategyImplementation = new YieldSkimmingTokenizedStrategy();

        MultistrategyVault vaultImplementation = new MultistrategyVault();
        MultistrategyVaultFactory factory =
            new MultistrategyVaultFactory("Octant Test Factory", address(vaultImplementation), address(this));

        usdcVault = MultistrategyVault(factory.deployNewVault(USDC, "Octant USDC Vault", "ovUSDC", address(this), 0));
        wethVault = MultistrategyVault(factory.deployNewVault(WETH, "Octant WETH Vault", "ovWETH", address(this), 0));

        usdcVault.setRole(address(this), type(uint256).max);
        wethVault.setRole(address(this), type(uint256).max);

        usdcVault.setDepositLimit(type(uint256).max, false);
        wethVault.setDepositLimit(type(uint256).max, false);

        address placeholderPair = address(1);
        address donationAddress = address(2);

        usdcStrategy = new AaveStrategy(
            USDC,
            address(aavePool),
            aTokenUsdc,
            "Aave USDC Strategy",
            address(this),
            address(this),
            address(this),
            donationAddress,
            false,
            address(tokenizedStrategyImplementation),
            address(hook),
            address(usdcVault),
            placeholderPair
        );

        wethStrategy = new AaveStrategy(
            WETH,
            address(aavePool),
            aTokenWeth,
            "Aave WETH Strategy",
            address(this),
            address(this),
            address(this),
            donationAddress,
            false,
            address(tokenizedStrategyImplementation),
            address(hook),
            address(wethVault),
            placeholderPair
        );

        usdcStrategy.setPairStrategyVault(address(wethStrategy));
        wethStrategy.setPairStrategyVault(address(usdcStrategy));

        usdcVault.addStrategy(address(usdcStrategy), true);
        wethVault.addStrategy(address(wethStrategy), true);

        usdcVault.updateMaxDebtForStrategy(address(usdcStrategy), type(uint256).max);
        wethVault.updateMaxDebtForStrategy(address(wethStrategy), type(uint256).max);

        exactOutputSwapRouter = new ExactOutputSwapRouter(manager);
    }

    function _configureHookRouting() internal {
        usdcStrategy.setWithdrawalRouter(address(exactOutputSwapRouter));
        wethStrategy.setWithdrawalRouter(address(exactOutputSwapRouter));

        ExactOutputSwapRouter.Route memory usdcRoute =
            ExactOutputSwapRouter.Route({poolKey: key, zeroForOne: true, hookData: ZERO_BYTES});
        ExactOutputSwapRouter.Route memory wethRoute =
            ExactOutputSwapRouter.Route({poolKey: key, zeroForOne: false, hookData: ZERO_BYTES});

        usdcToWethSwapData = abi.encode(usdcRoute);
        wethToUsdcSwapData = abi.encode(wethRoute);

        usdcStrategy.setWithdrawalSwapData(usdcToWethSwapData);
        wethStrategy.setWithdrawalSwapData(wethToUsdcSwapData);

        hook.setStrategyForToken(USDC, address(usdcStrategy));
        hook.setStrategyForToken(WETH, address(wethStrategy));
    }

    function _provideBaseLiquidity() internal {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: 1e12,
            salt: bytes32(0)
        });

        modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);
    }

    function _seedStrategies() internal {
        IERC20(USDC).forceApprove(address(usdcVault), type(uint256).max);
        usdcVault.deposit(STRATEGY_USDC, address(this));

        IERC20(WETH).forceApprove(address(wethVault), type(uint256).max);
        wethVault.deposit(STRATEGY_WETH, address(this));
    }

    function testDepositIntoVaultsViaUser() public {
        uint256 userUsdcAmount = 200_000 * 1e6;
        uint256 userWethAmount = 50 * 1e18;

        address user = makeAddr("user");

        deal(USDC, user, userUsdcAmount);
        deal(WETH, user, userWethAmount);

        uint256 usdcAssetsBefore = usdcVault.totalAssets();
        uint256 wethAssetsBefore = wethVault.totalAssets();

        uint256 expectedUsdcShares = usdcVault.convertToShares(userUsdcAmount);
        uint256 expectedWethShares = wethVault.convertToShares(userWethAmount);

        vm.startPrank(user);
        IERC20(USDC).forceApprove(address(usdcVault), userUsdcAmount);
        usdcVault.deposit(userUsdcAmount, user);

        IERC20(WETH).forceApprove(address(wethVault), userWethAmount);
        wethVault.deposit(userWethAmount, user);
        vm.stopPrank();

        assertEq(usdcVault.totalAssets(), usdcAssetsBefore + userUsdcAmount, "USDC assets mismatch");
        assertEq(wethVault.totalAssets(), wethAssetsBefore + userWethAmount, "WETH assets mismatch");

        assertEq(usdcVault.balanceOf(user), expectedUsdcShares, "USDC shares mismatch");
        assertEq(wethVault.balanceOf(user), expectedWethShares, "WETH shares mismatch");
    }

    function testSwapExactInputUsdcForWethThroughHook() public {
        address user = makeAddr("swap-user");
        uint256 amountIn = 100 * 1e6;

        deal(USDC, user, amountIn);

        uint256 wethBalanceBefore = IERC20(WETH).balanceOf(user);

        vm.startPrank(user);
        IERC20(USDC).forceApprove(address(swapRouterNoChecks), amountIn);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouterNoChecks.swap(key, params);

        vm.stopPrank();

        uint256 wethBalanceAfter = IERC20(WETH).balanceOf(user);

        assertGt(wethBalanceAfter, wethBalanceBefore, "User should receive WETH");
        assertEq(IERC20(USDC).balanceOf(user), 0, "USDC should be spent");
    }

    function testLargeSwapThroughHook() public {
        address strategyOperator = makeAddr("strategy-operator");
        uint256 initialVaultUsdc = 5_000_000 * 1e6;
        uint256 initialVaultWeth = 3_000 * 1e18;

        deal(USDC, strategyOperator, initialVaultUsdc);
        deal(WETH, strategyOperator, initialVaultWeth);

        vm.startPrank(strategyOperator);
        IERC20(USDC).forceApprove(address(usdcVault), initialVaultUsdc);
        IERC20(WETH).forceApprove(address(wethVault), initialVaultWeth);
        usdcVault.deposit(initialVaultUsdc, strategyOperator);
        wethVault.deposit(initialVaultWeth, strategyOperator);
        vm.stopPrank();

        uint256 wethBuffer = 50 * 1e18;
        deal(WETH, address(wethStrategy), wethBuffer);
        vm.startPrank(address(wethStrategy));
        IPool(aavePool).supply(WETH, wethBuffer, address(wethStrategy), 0);
        vm.stopPrank();

        address user = makeAddr("large-swapper");
        uint256 amountIn = 2000 * 1e6;


        deal(USDC, user, amountIn);
        vm.startPrank(user);
        IERC20(USDC).forceApprove(address(swapRouterNoChecks), amountIn);
        // IERC20(USDC).transfer(address(swapRouterNoChecks), scaledAmountIn);
        vm.stopPrank();

        uint256 usdcStrategyAssetsBefore = usdcStrategy.totalManagedAssets();
        uint256 wethStrategyAssetsBefore = wethStrategy.totalManagedAssets();
        uint256 governanceUsdcBefore = IERC20(USDC).balanceOf(hook.GOVERNANCE());
        uint256 userWethBefore = IERC20(WETH).balanceOf(user);

        console.log("--- Pre Swap Snapshot ---");
        console.logAddress(user);
        console.log("amountIn (USDC)", amountIn);
        console.log("usdcStrategyAssetsBefore", usdcStrategyAssetsBefore);
        console.log("wethStrategyAssetsBefore", wethStrategyAssetsBefore);
        console.log("governanceUsdcBefore", governanceUsdcBefore);
        console.log("userWethBefore", userWethBefore);

        vm.prank(address(swapRouterNoChecks));
        IERC20(USDC).forceApprove(address(hook), type(uint256).max);

        emit log_named_uint("amountIn", amountIn);

        vm.startPrank(user);
        // IERC20(USDC).transfer(address(swapRouterNoChecks), amountIn);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouterNoChecks.swap(key, params);
        vm.stopPrank();

        uint256 userWethAfter = IERC20(WETH).balanceOf(user);
        uint256 usdcStrategyAssetsAfter = usdcStrategy.totalManagedAssets();
        uint256 wethStrategyAssetsAfter = wethStrategy.totalManagedAssets();
        uint256 governanceUsdcAfter = IERC20(USDC).balanceOf(hook.GOVERNANCE());

        console.log("--- Post Swap Snapshot ---");
        console.log("usdcStrategyAssetsAfter", usdcStrategyAssetsAfter);
        console.log("wethStrategyAssetsAfter", wethStrategyAssetsAfter);
        console.log("governanceUsdcAfter", governanceUsdcAfter);
        console.log("userWethAfter", userWethAfter);

        uint256 expectedFee = (amountIn * 50) / 10_000;
        uint256 expectedDeposit = amountIn - expectedFee;

        console.log("--- Derived Values ---");
        console.log("expectedFee", expectedFee);
        console.log("expectedDeposit", expectedDeposit);
        console.log("actualStrategyDepositDelta", usdcStrategyAssetsAfter - usdcStrategyAssetsBefore);
        console.log("actualStrategyWithdrawDelta", wethStrategyAssetsBefore - wethStrategyAssetsAfter);
        console.log("actualGovernanceFeeDelta", governanceUsdcAfter - governanceUsdcBefore);
        console.log("netUserWethGain", userWethAfter - userWethBefore);

        assertGt(userWethAfter, userWethBefore, "User should receive WETH from strategy liquidity");
        assertApproxEqAbs(
            usdcStrategyAssetsAfter,
            usdcStrategyAssetsBefore + expectedDeposit,
            expectedDeposit / 100,
            "USDC strategy should receive deposit minus fee"
        );
        assertLt(wethStrategyAssetsAfter, wethStrategyAssetsBefore, "WETH strategy should have reduced assets");
        assertEq(governanceUsdcAfter - governanceUsdcBefore, expectedFee, "Governance should collect swap fee");
    }
}