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

contract YieldMMEndToEndTest is Test, Deployers {
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

        deal(USDC, address(this), LIQUIDITY_USDC + STRATEGY_USDC);
        deal(WETH, address(this), LIQUIDITY_WETH + STRATEGY_WETH);
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
        // jsut used as stub
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

    function testEndToEndScenario() public {
        uint256 baseVaultAssets = usdcVault.totalAssets();
        uint256 baseGovernance = IERC20(USDC).balanceOf(hook.GOVERNANCE());

        address depositor = makeAddr("end-to-end-depositor");
        uint256 depositAmount = 500_000 * 1e6;
        uint256 expectedShares = usdcVault.convertToShares(depositAmount);

        deal(USDC, depositor, depositAmount);
        vm.startPrank(depositor);
        IERC20(USDC).forceApprove(address(usdcVault), depositAmount);
        uint256 mintedShares = usdcVault.deposit(depositAmount, depositor);
        vm.stopPrank();

        assertEq(mintedShares, expectedShares, "shares mismatch");
        assertEq(usdcVault.totalAssets(), baseVaultAssets + depositAmount, "assets mismatch after deposit");
        assertEq(usdcVault.balanceOf(depositor), mintedShares, "depositor should hold shares");

        // another user adds WETH to the paired strategyVault
        address wethDepositor = makeAddr("paired-weth-user");
        uint256 seedWeth = 1_500 * 1e18;
        deal(WETH, wethDepositor, seedWeth);
        vm.startPrank(wethDepositor);
        IERC20(WETH).forceApprove(address(wethVault), seedWeth);
        wethVault.deposit(seedWeth, wethDepositor);
        vm.stopPrank();

        // manually seed strategy liquidity for testing purposes
        // autoallocation is turned off 
        deal(WETH, address(wethStrategy), seedWeth);
        vm.prank(address(wethStrategy));
        IERC20(WETH).forceApprove(address(aavePool), seedWeth);
        vm.prank(address(wethStrategy));
        IPool(aavePool).supply(WETH, seedWeth, address(wethStrategy), 0);

        uint256 swapAmount = 2_000 * 1e6;
        uint256 hookFee = (swapAmount * 50) / 10_000;
        uint256 expectedDeposit = swapAmount - hookFee;

        address trader = makeAddr("end-to-end-trader");
        uint256 traderWethBefore = IERC20(WETH).balanceOf(trader);
        uint256 usdcStrategyBefore = usdcStrategy.totalManagedAssets();
        uint256 wethStrategyBefore = wethStrategy.totalManagedAssets();

        deal(USDC, trader, swapAmount);
        vm.startPrank(trader);
        IERC20(USDC).forceApprove(address(swapRouterNoChecks), swapAmount);
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouterNoChecks.swap(key, params);
        vm.stopPrank();

        uint256 traderWethAfter = IERC20(WETH).balanceOf(trader);
        uint256 usdcStrategyAfter = usdcStrategy.totalManagedAssets();
        uint256 wethStrategyAfter = wethStrategy.totalManagedAssets();
        uint256 governanceAfter = IERC20(USDC).balanceOf(hook.GOVERNANCE());

        assertGt(traderWethAfter, traderWethBefore, "trader should receive WETH");
        assertApproxEqAbs(
            usdcStrategyAfter,
            usdcStrategyBefore + expectedDeposit,
            2,
            "USDC redeposit mismatch"
        );
        assertApproxEqAbs(
            wethStrategyBefore - wethStrategyAfter,
            swapAmount,
            2,
            "WETH strategy outflow mismatch"
        );
        assertEq(governanceAfter - baseGovernance, hookFee, "fee escrow mismatch");

        uint256 depositorUsdcBefore = IERC20(USDC).balanceOf(depositor);
        address[] memory queue = new address[](0);

        vm.startPrank(depositor);
        usdcVault.redeem(mintedShares, depositor, depositor, 10_000, queue);
        vm.stopPrank();

        uint256 depositorUsdcAfter = IERC20(USDC).balanceOf(depositor);
        uint256 wethStrategyFinal = wethStrategy.totalManagedAssets();

        assertApproxEqAbs(
            depositorUsdcAfter - depositorUsdcBefore,
            depositAmount,
            10,
            "redeem amount mismatch"
        );
        assertEq(usdcVault.balanceOf(depositor), 0, "shares should be burned");
        assertApproxEqAbs(usdcVault.totalAssets(), baseVaultAssets, 10, "vault assets should revert");
        assertApproxEqAbs(
            wethStrategyFinal,
            wethStrategyAfter,
            2,
            "WETH strategy should remain unchanged after redemption"
        );
        assertEq(
            IERC20(USDC).balanceOf(hook.GOVERNANCE()),
            governanceAfter,
            "governance fee should remain"
        );
    }

}

