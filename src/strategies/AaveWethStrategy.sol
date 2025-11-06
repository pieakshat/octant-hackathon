// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {BaseHealthCheck} from "octant-v2-core/strategies/periphery/BaseHealthCheck.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAToken} from "aave-v3-origin/contracts/interfaces/IAToken.sol";
import {IPool} from "aave-v3-origin/contracts/interfaces/IPool.sol";


contract AaveWethStrategy is BaseHealthCheck {
    using SafeERC20 for IERC20;

    address public immutable aavePool; 

    address public immutable aToken; 

    address public cowHook; 

    error UnauthorizedCaller(); 
    error AssetMismatch(); 
    error InvalidAddress(); 

    event CowHookUpdated(address indexed newCowHook); 
    event LiquidityProvided(uint256 amount, address indexed token); 
    event LiquidityReturned(uint256 amount); 

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
        address _cowHook
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

        require(IAToken(_aToken).UNDERLYING_ASSET_ADDRESS() == _asset, AssetMismatch());

        aavePool = _aavePool;
        aToken = _aToken;
        cowHook = _cowHook;

        IERC20(_asset).forceApprove(_aavePool, type(uint256).max); 
    }


    function _deployFunds(uint256 _amount) internal override {
        // Supply WETH 
        IPool(aavePool).supply(
            address(asset), 
            _amount, 
            address(this), 
            0
        ); 
    }

    function _freeFunds(uint256 _amount) internal override {
        IPool(aavePool).withdraw(
            address(asset), 
            _amount, 
            address(this)
        ); 
    }

    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {

        uint256 aaveBalance = IERC20(aToken).balanceOf(address(this)); 

        uint256 idleBalance = IERC20(asset).balanceOf(address(this)); 

        _totalAssets = aaveBalance + idleBalance; 

        return _totalAssets; 
    }

    function setCowHook(address _cowHook) external onlyManagement {
        require(_cowHook != address(0), InvalidAddress());
        cowHook = _cowHook;
        emit CowHookUpdated(_cowHook);
    }

    function getAvailableLiquidityForSwap() external view returns (uint256 availableLiquidity) {
        availableLiquidity = IERC20(aToken).balanceOf(address(this)); 
    }

    // need to write one more function maybe with callback patterns to 
    // allow hhok to pull tokens and stuff

}