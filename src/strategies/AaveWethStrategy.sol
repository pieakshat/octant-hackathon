// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseHealthCheck} from "octant-v2-core/strategies/periphery/BaseHealthCheck.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAToken} from "aave-v3-origin/contracts/interfaces/IAToken.sol";
import {IPool} from "aave-v3-origin/contracts/interfaces/IPool.sol";

contract AaveWethStrategy is BaseHealthCheck {
    using SafeERC20 for IERC20;

    address public immutable UNDERLYING_ASSET;
    address public immutable AAVE_POOL; 

    address public immutable A_TOKEN; 

    address public cowHook; 

    error UnauthorizedCaller(); 
    error AssetMismatch(); 
    error InvalidAddress(); 
    error InsufficientLiquidity(); 
    error Unauthorized(); 
    error InvalidAmount(); 

    event CowHookUpdated(address indexed newCowHook); 
    event LiquidityProvided(uint256 amount, address indexed token); 
    event LiquidityReturned(uint256 amount); 

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
        address _multiStrategyVault
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
        IPool(AAVE_POOL).withdraw(
            address(asset), 
            _amount, 
            address(this)
        ); 
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
}