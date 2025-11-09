// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IPoolAddressesProvider} from "aave-v3-origin/contracts/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "aave-v3-origin/contracts/interfaces/IPool.sol";
import {DataTypes} from "aave-v3-origin/contracts/protocol/libraries/types/DataTypes.sol";

import {CoWHook} from "../src/CoWHook/CoWHook.sol";
import {AaveStrategy} from "../src/strategies/AaveStrategy.sol";
import {ExactOutputSwapRouter} from "../src/routers/ExactOutputSwapRouter.sol";
import {MultistrategyVault} from "octant-v2-core/core/MultistrategyVault.sol";
import {MultistrategyVaultFactory} from "octant-v2-core/factories/MultistrategyVaultFactory.sol";
import {YieldSkimmingTokenizedStrategy} from "octant-v2-core/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";

contract DeployYieldMM is Script {
    using CurrencyLibrary for Currency;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address governance = vm.envAddress("GOVERNANCE");
        address poolManagerAddr = vm.envAddress("POOL_MANAGER");
        address aaveProviderAddr = vm.envAddress("AAVE_ADDRESSES_PROVIDER");
        address modifyLiquidityRouter = vm.envAddress("V4_MODIFY_LIQUIDITY_ROUTER");

        address usdc = vm.envAddress("USDC");
        address weth = vm.envAddress("WETH");
        uint24 poolFee = uint24(vm.envUint("POOL_FEE")); // e.g. 3000
        int24 tickSpacing = int24(int256(vm.envInt("TICK_SPACING"))); // e.g. 60

        vm.startBroadcast(deployerKey);

        // --- Uniswap CoW Hook ---
        CoWHook hook = new CoWHook(IPoolManager(poolManagerAddr));

        // --- Aave context ---
        IPoolAddressesProvider provider = IPoolAddressesProvider(aaveProviderAddr);
        IPool aavePool = IPool(provider.getPool());

        DataTypes.ReserveDataLegacy memory usdcReserve = aavePool.getReserveData(usdc);
        DataTypes.ReserveDataLegacy memory wethReserve = aavePool.getReserveData(weth);
        address aTokenUsdc = usdcReserve.aTokenAddress;
        address aTokenWeth = wethReserve.aTokenAddress;

        // --- Vaults ---
        YieldSkimmingTokenizedStrategy tokenizedImpl = new YieldSkimmingTokenizedStrategy();
        MultistrategyVaultFactory factory =
            new MultistrategyVaultFactory("YieldMM Factory", address(new MultistrategyVault()), address(this));

        MultistrategyVault usdcVault =
            MultistrategyVault(factory.deployNewVault(usdc, "YieldMM USDC Vault", "ymUSDC", governance, 0));
        MultistrategyVault wethVault =
            MultistrategyVault(factory.deployNewVault(weth, "YieldMM WETH Vault", "ymWETH", governance, 0));

        usdcVault.setRole(governance, type(uint256).max);
        wethVault.setRole(governance, type(uint256).max);
        usdcVault.setDepositLimit(type(uint256).max, false);
        wethVault.setDepositLimit(type(uint256).max, false);

        // --- Exact output router (used for rebalancing on withdrawals) ---
        ExactOutputSwapRouter exactRouter = new ExactOutputSwapRouter(IPoolManager(poolManagerAddr));

        // --- Strategies ---
        AaveStrategy usdcStrategy = new AaveStrategy(
            usdc,
            address(aavePool),
            aTokenUsdc,
            "YieldMM USDC Strategy",
            governance,
            governance,
            governance,
            governance,
            false,
            address(tokenizedImpl),
            address(hook),
            address(usdcVault),
            address(wethVault) // placeholder pair strategy; overwritten below
        );

        AaveStrategy wethStrategy = new AaveStrategy(
            weth,
            address(aavePool),
            aTokenWeth,
            "YieldMM WETH Strategy",
            governance,
            governance,
            governance,
            governance,
            false,
            address(tokenizedImpl),
            address(hook),
            address(wethVault),
            address(usdcVault)
        );

        usdcStrategy.setPairStrategyVault(address(wethStrategy));
        wethStrategy.setPairStrategyVault(address(usdcStrategy));

        usdcVault.addStrategy(address(usdcStrategy), true);
        wethVault.addStrategy(address(wethStrategy), true);
        usdcVault.updateMaxDebtForStrategy(address(usdcStrategy), type(uint256).max);
        wethVault.updateMaxDebtForStrategy(address(wethStrategy), type(uint256).max);

        usdcStrategy.setWithdrawalRouter(address(exactRouter));
        wethStrategy.setWithdrawalRouter(address(exactRouter));

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(usdc),
            currency1: Currency.wrap(weth),
            fee: poolFee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });

        bytes memory usdcToWethData =
            abi.encode(ExactOutputSwapRouter.Route({poolKey: poolKey, zeroForOne: true, hookData: bytes("")}));
        bytes memory wethToUsdcData =
            abi.encode(ExactOutputSwapRouter.Route({poolKey: poolKey, zeroForOne: false, hookData: bytes("")}));

        usdcStrategy.setWithdrawalSwapData(usdcToWethData);
        wethStrategy.setWithdrawalSwapData(wethToUsdcData);

        hook.setStrategyForToken(usdc, address(usdcStrategy));
        hook.setStrategyForToken(weth, address(wethStrategy));

        vm.stopBroadcast();

        console.log("CoW Hook deployed at:", address(hook));
        console.log("USDC Vault deployed at:", address(usdcVault));
        console.log("WETH Vault deployed at:", address(wethVault));
        console.log("USDC Strategy deployed at:", address(usdcStrategy));
        console.log("WETH Strategy deployed at:", address(wethStrategy));
        console.log("Exact Output Router deployed at:", address(exactRouter));
        console.log("Remember to configure Uniswap pool + permissions for hook address bits.");
    }
}

