// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CoWHook, IAaveLiquidityStrategy, DirectSwapContext} from "../src/CoWHook/CoWHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockStrategy is IAaveLiquidityStrategy {
    using SafeERC20 for IERC20;

    address public immutable asset;
    uint256 public availableLiquidity;
    uint256 public managedAssets;

    uint256 public lastPulled;
    uint256 public lastPushed;

    constructor(address _asset) {
        asset = _asset;
    }

    function assetToken() external view returns (address) {
        return asset;
    }

    function getAvailableLiquidityForSwap() external view returns (uint256) {
        return availableLiquidity;
    }

    function pullFundsForSwap(uint256 amount, uint256) external returns (uint256 withdrawn) {
        uint256 toSend = amount > availableLiquidity ? availableLiquidity : amount;
        availableLiquidity -= toSend;
        managedAssets = managedAssets >= toSend ? managedAssets - toSend : 0;
        IERC20(asset).safeTransfer(msg.sender, toSend);
        lastPulled = toSend;
        return toSend;
    }

    function pushAfterSwap(uint256 amount) external returns (uint256 suppliedAmount) {
        suppliedAmount = amount;
        lastPushed += amount;
        managedAssets += amount;
    }

    function totalManagedAssets() external view returns (uint256) {
        return managedAssets;
    }

    // ======== Helpers for tests ========

    function seed(uint256 amount) external {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        availableLiquidity += amount;
        managedAssets += amount;
    }

    function setManagedAssets(uint256 amount) external {
        managedAssets = amount;
    }

    function setAvailableLiquidity(uint256 amount) external {
        availableLiquidity = amount;
    }
}

contract TestableCoWHook is CoWHook {
    constructor(IPoolManager manager) CoWHook(manager) {}

    function callExecuteDirectSwap(address sender, DirectSwapContext memory ctx)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return executeDirectSwap(sender, ctx);
    }

    function validateHookAddress(BaseHook) internal pure override {}
}

contract CoWHookTest is Test {
    using SafeERC20 for IERC20;

    TestableCoWHook hook;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    MockStrategy inStrategy;
    MockStrategy outStrategy;
    address user;

    function setUp() public {
        hook = new TestableCoWHook(IPoolManager(address(0)));

        tokenIn = new MockERC20("TokenIn", "TIN");
        tokenOut = new MockERC20("TokenOut", "TOUT");

        inStrategy = new MockStrategy(address(tokenIn));
        outStrategy = new MockStrategy(address(tokenOut));

        user = address(0xBEEF);
        vm.label(address(hook), "CoWHook");
        vm.label(address(inStrategy), "InStrategy");
        vm.label(address(outStrategy), "OutStrategy");
        vm.label(user, "User");
    }

    function testSetStrategyForTokenConfiguresMapping() public {
        hook.setStrategyForToken(address(tokenIn), address(inStrategy));
        hook.setStrategyForToken(address(tokenOut), address(outStrategy));

        assertEq(address(hook.strategies(address(tokenIn))), address(inStrategy), "strategy in mismatch");
        assertEq(address(hook.strategies(address(tokenOut))), address(outStrategy), "strategy out mismatch");
    }

    function testSetStrategyForTokenRevertsOnAssetMismatch() public {
        MockStrategy wrongStrategy = new MockStrategy(address(tokenOut));
        vm.expectRevert(CoWHook.StrategyAssetMismatch.selector);
        hook.setStrategyForToken(address(tokenIn), address(wrongStrategy));
    }

    function testSetStrategyForTokenOnlyGovernance() public {
        address nonGov = address(0xCAFE);
        vm.prank(nonGov);
        vm.expectRevert(CoWHook.NotGovernance.selector);
        hook.setStrategyForToken(address(tokenIn), address(inStrategy));
    }

    function testExecuteDirectSwapSuccess() public {
        hook.setStrategyForToken(address(tokenIn), address(inStrategy));
        hook.setStrategyForToken(address(tokenOut), address(outStrategy));

        uint256 amountIn = 1_000 ether;
        uint256 amountOut = 900 ether;

        tokenOut.mint(address(this), amountOut);
        tokenOut.safeApprove(address(outStrategy), amountOut);
        outStrategy.seed(amountOut);

        tokenIn.mint(user, amountIn);
        vm.prank(user);
        tokenIn.approve(address(hook), amountIn);

        DirectSwapContext memory ctx;
        ctx.isExactInput = true;
        ctx.amountIn = amountIn;
        ctx.amountOut = amountOut;
        ctx.currencyIn = address(tokenIn);
        ctx.currencyOut = address(tokenOut);

        vm.expectEmit(true, true, true, true);
        emit CoWHook.FeeCollected(address(tokenIn), amountIn * 50 / 10_000);

        (bytes4 selector, BeforeSwapDelta swapDelta, uint24 fee) =
            hook.callExecuteDirectSwap(user, ctx);

        assertEq(selector, IHooks.beforeSwap.selector, "selector mismatch");
        assertEq(fee, 0, "fee tier unexpectedly set");
        int128 specified = BeforeSwapDeltaLibrary.getSpecifiedDelta(swapDelta);
        int128 unspecified = BeforeSwapDeltaLibrary.getUnspecifiedDelta(swapDelta);
        assertEq(int256(specified), -int256(amountIn), "specified delta mismatch");
        assertEq(int256(unspecified), int256(amountOut), "unspecified delta mismatch");

        assertEq(tokenOut.balanceOf(user), amountOut, "user did not receive output token");
        assertEq(tokenIn.balanceOf(user), 0, "user input not fully spent");

        uint256 expectedFee = amountIn * 50 / 10_000;
        uint256 expectedDeposit = amountIn - expectedFee;

        assertEq(tokenIn.balanceOf(address(this)), expectedFee, "governance fee mismatch");
        assertEq(inStrategy.lastPushed(), expectedDeposit, "strategy deposit mismatch");
        assertEq(outStrategy.lastPulled(), amountOut, "strategy withdrawal mismatch");
    }

    function testExecuteDirectSwapRevertsWhenStrategyMissing() public {
        DirectSwapContext memory ctx;
        ctx.isExactInput = true;
        ctx.amountIn = 1e18;
        ctx.amountOut = 1e18;
        ctx.currencyIn = address(tokenIn);
        ctx.currencyOut = address(tokenOut);

        vm.expectRevert(CoWHook.StrategyNotConfigured.selector);
        hook.callExecuteDirectSwap(user, ctx);
    }

    function testExecuteDirectSwapRevertsWhenInsufficientLiquidity() public {
        hook.setStrategyForToken(address(tokenIn), address(inStrategy));
        hook.setStrategyForToken(address(tokenOut), address(outStrategy));

        uint256 amountIn = 1_000e18;
        uint256 amountOut = 900e18;

        tokenOut.mint(address(this), amountOut / 2);
        tokenOut.safeApprove(address(outStrategy), amountOut / 2);
        outStrategy.seed(amountOut / 2);

        DirectSwapContext memory ctx;
        ctx.isExactInput = true;
        ctx.amountIn = amountIn;
        ctx.amountOut = amountOut;
        ctx.currencyIn = address(tokenIn);
        ctx.currencyOut = address(tokenOut);

        vm.expectRevert(CoWHook.InsufficientStrategyLiquidity.selector);
        hook.callExecuteDirectSwap(user, ctx);
    }
}