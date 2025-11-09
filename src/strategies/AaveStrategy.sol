// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseHealthCheck} from "octant-v2-core/strategies/periphery/BaseHealthCheck.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAToken} from "aave-v3-origin/contracts/interfaces/IAToken.sol";
import {IPool} from "aave-v3-origin/contracts/interfaces/IPool.sol";
import {IExactOutputSwapRouter} from "../interfaces/IExactOutputSwapRouter.sol";

interface IAaveStrategyView {
    function totalManagedAssets() external view returns (uint256);
    function assetToken() external view returns (address);
}

interface IPairedStrategyLiquidity {
    function pullFundsForUser(uint256 amountOut, uint256 maxAmountIn) external returns (uint256);
}

contract AaveStrategy is BaseHealthCheck {
    using SafeERC20 for IERC20;

    address public immutable UNDERLYING_ASSET;
    address public immutable AAVE_POOL;

    address public immutable A_TOKEN;

    address public cowHook;
    address public pairStrategyVault; 
    address public withdrawalRouter;

    uint256 public withdrawSlippageBps = 300;
    bytes public withdrawalSwapData;

    error UnauthorizedCaller(); 
    error AssetMismatch(); 
    error InvalidAddress(); 
    error InsufficientLiquidity(); 
    error Unauthorized(); 
    error InvalidAmount(); 
    error RouterNotConfigured();
    error PairStrategyNotConfigured();

    event CowHookUpdated(address indexed newCowHook); 
    event LiquidityProvided(uint256 amount, address indexed token); 
    event LiquidityReturned(uint256 amount); 
    event PairStrategyVaultUpdated(address indexed newPairStrategyVault);
    event WithdrawalRouterUpdated(address indexed router);
    event WithdrawSlippageUpdated(uint256 slippageBps);
    event WithdrawalSwapDataUpdated(bytes data);

    modifier onlyCowHook() {
        _enforceCowHook();
        _;
    }

    function _enforceCowHook() internal view {
        if (msg.sender != cowHook) revert UnauthorizedCaller();
    }

    constructor(
        address _asset,
        address _aavePool,
        address _aToken,
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress,
        address _cowHook,
        address _multiStrategyVault,
        address _pairStrategyVault
    )
    BaseHealthCheck(
        _asset,
        _name,
        _management,
        _keeper,
        _emergencyAdmin,
        _donationAddress,
        _enableBurning,
        _tokenizedStrategyAddress
    ) {
        require(_aavePool != address(0), InvalidAddress());
        require(_aToken != address(0), InvalidAddress());
        require(_cowHook != address(0), InvalidAddress());
        require(_multiStrategyVault != address(0), InvalidAddress());

        require(IAToken(_aToken).UNDERLYING_ASSET_ADDRESS() == _asset, AssetMismatch());

        UNDERLYING_ASSET = _asset;
        AAVE_POOL = _aavePool;
        A_TOKEN = _aToken;
        cowHook = _cowHook;
        pairStrategyVault = _pairStrategyVault;

        IERC20(_asset).forceApprove(AAVE_POOL, type(uint256).max);
    }


    function _deployFunds(uint256 _amount) internal override {
        IPool(AAVE_POOL).supply(
            address(asset), 
            _amount, 
            address(this), 
            0
        ); 
    }

    function _freeFunds(uint256 _amount) internal override {
        if (_amount == 0) revert InvalidAmount();

        uint256 idleBalance = IERC20(asset).balanceOf(address(this));
        if (idleBalance >= _amount) {
            return;
        }

        uint256 remaining = _amount - idleBalance;

        uint256 aaveBalance = IERC20(A_TOKEN).balanceOf(address(this));
        if (aaveBalance > 0) {
            uint256 toWithdraw = remaining > aaveBalance ? aaveBalance : remaining;
            uint256 pulled = IPool(AAVE_POOL).withdraw(
                address(asset),
                toWithdraw,
                address(this)
            );

            idleBalance += pulled;
            if (idleBalance >= _amount) {
                return;
            }

            remaining = _amount - idleBalance;
        }

        if (remaining == 0) {
            return;
        }

        uint256 received = _pullFromPairStrategy(remaining);
        idleBalance = IERC20(asset).balanceOf(address(this));

        if (idleBalance < _amount || received < remaining) {
            revert InsufficientLiquidity();
        }
    }

    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {

        uint256 aaveBalance = IERC20(A_TOKEN).balanceOf(address(this)); 

        uint256 idleBalance = IERC20(asset).balanceOf(address(this)); 

        _totalAssets = aaveBalance + idleBalance; 

        return _totalAssets; 
    }

    function setCowHook(address _cowHook) external onlyManagement {
        require(_cowHook != address(0), InvalidAddress());
        cowHook = _cowHook;
        emit CowHookUpdated(_cowHook);
    }

    function setWithdrawalRouter(address _router) external onlyManagement {
        if (_router == address(0)) revert InvalidAddress();
        withdrawalRouter = _router;
        emit WithdrawalRouterUpdated(_router);
    }

    function setWithdrawSlippageBps(uint256 _slippageBps) external onlyManagement {
        require(_slippageBps <= MAX_BPS, InvalidAmount());
        withdrawSlippageBps = _slippageBps;
        emit WithdrawSlippageUpdated(_slippageBps);
    }

    function setWithdrawalSwapData(bytes calldata _data) external onlyManagement {
        withdrawalSwapData = _data;
        emit WithdrawalSwapDataUpdated(_data);
    }

    function getAvailableLiquidityForSwap() public view returns (uint256) {
        uint256 depositedBalance = IERC20(A_TOKEN).balanceOf(address(this));
        uint256 idleBalance = IERC20(UNDERLYING_ASSET).balanceOf(address(this));
        return depositedBalance + idleBalance;
    }

    function assetToken() external view returns (address) {
        return UNDERLYING_ASSET;
    }

    function pullFundsForSwap(uint256 _amount, uint256 maxLossBps) external onlyCowHook returns (uint256 withdrawn) {
        require(_amount > 0, InvalidAmount());
        require(maxLossBps <= MAX_BPS, InvalidAmount());

        uint256 availableAmountForSwap = getAvailableLiquidityForSwap();
        if (availableAmountForSwap == 0) {
            revert InsufficientLiquidity();
        }

        if (_amount > availableAmountForSwap) {
            _amount = availableAmountForSwap;
        }

        uint256 remaining = _amount;
        uint256 idleBalance = IERC20(UNDERLYING_ASSET).balanceOf(address(this));

        if (idleBalance > 0) {
            uint256 idleToSend = idleBalance > remaining ? remaining : idleBalance;
            IERC20(UNDERLYING_ASSET).safeTransfer(cowHook, idleToSend);
            withdrawn += idleToSend;
            remaining -= idleToSend;
        }

        if (remaining > 0) {
            uint256 fromAave = IPool(AAVE_POOL).withdraw(UNDERLYING_ASSET, remaining, cowHook);
            withdrawn += fromAave;
        }

        if (withdrawn == 0) {
            revert InsufficientLiquidity();
        }

        emit LiquidityProvided(withdrawn, UNDERLYING_ASSET);
    }

    function pushAfterSwap(uint256 _amount) external onlyCowHook returns (uint256 suppliedAmount) {
        require(_amount > 0, InvalidAmount());

        uint256 currentBalance = IERC20(UNDERLYING_ASSET).balanceOf(address(this));
        require(currentBalance >= _amount, InsufficientLiquidity());

        IPool(AAVE_POOL).supply(UNDERLYING_ASSET, _amount, address(this), 0);

        emit LiquidityReturned(_amount);
        suppliedAmount = _amount;
    }

    function setPairStrategyVault(address _pairStrategyVault) external onlyManagement {
        pairStrategyVault = _pairStrategyVault;
        emit PairStrategyVaultUpdated(_pairStrategyVault);
    }

    function totalManagedAssets() public view returns (uint256) {
        uint256 aaveBalance = IERC20(A_TOKEN).balanceOf(address(this));
        uint256 idleBalance = IERC20(asset).balanceOf(address(this));
        return aaveBalance + idleBalance;
    }

    function totalManagedAssetsWithPair()
        external
        view
        returns (uint256 thisStrategyAssets, uint256 pairStrategyAssets)
    {
        thisStrategyAssets = totalManagedAssets();
        if (pairStrategyVault != address(0)) {
            pairStrategyAssets = IAaveStrategyView(pairStrategyVault).totalManagedAssets();
        }
    }

    function pullFundsForUser(uint256 amountOut, uint256 maxAmountIn)
        external
        onlyPairStrategy
        returns (uint256 amountIn)
    {
        if (withdrawalRouter == address(0)) revert RouterNotConfigured();
        if (amountOut == 0 || maxAmountIn == 0) revert InvalidAmount();

        address outputToken = IAaveStrategyView(msg.sender).assetToken();

        uint256 idle = IERC20(UNDERLYING_ASSET).balanceOf(address(this));
        if (idle < maxAmountIn) {
            uint256 toWithdraw = maxAmountIn - idle;
            uint256 pulled = IPool(AAVE_POOL).withdraw(UNDERLYING_ASSET, toWithdraw, address(this));
            idle += pulled;
        }

        if (idle < maxAmountIn) {
            revert InsufficientLiquidity();
        }

        IERC20(UNDERLYING_ASSET).forceApprove(withdrawalRouter, 0);
        IERC20(UNDERLYING_ASSET).forceApprove(withdrawalRouter, maxAmountIn);

        amountIn = IExactOutputSwapRouter(withdrawalRouter).swapExactOutput(
            address(this),
            UNDERLYING_ASSET,
            outputToken,
            amountOut,
            maxAmountIn,
            msg.sender,
            withdrawalSwapData
        );

        IERC20(UNDERLYING_ASSET).forceApprove(withdrawalRouter, 0);

        if (amountIn > maxAmountIn) {
            revert InvalidAmount();
        }

        uint256 unused = maxAmountIn - amountIn;
        if (unused > 0) {
            IPool(AAVE_POOL).supply(UNDERLYING_ASSET, unused, address(this), 0);
        }
    }

    function _pullFromPairStrategy(uint256 amountNeeded) internal returns (uint256 received) {
        if (pairStrategyVault == address(0)) revert PairStrategyNotConfigured();
        if (withdrawalRouter == address(0)) revert RouterNotConfigured();

        uint256 maxInput = amountNeeded + ((amountNeeded * withdrawSlippageBps) / MAX_BPS);
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        IPairedStrategyLiquidity(pairStrategyVault).pullFundsForUser(amountNeeded, maxInput);

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        received = balanceAfter - balanceBefore;
    }

    modifier onlyPairStrategy() {
        if (msg.sender != pairStrategyVault) revert UnauthorizedCaller();
        _;
    }
}