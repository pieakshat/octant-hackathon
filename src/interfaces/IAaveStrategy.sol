interface IAaveStrategy {
    function assetToken() external view returns (address);

    function getAvailableLiquidityForSwap() external view returns (uint256);

    function pullFundsForSwap(uint256 amount, uint256 maxLossBps) external returns (uint256);

    function pushAfterSwap(uint256 amount) external returns (uint256);

    function totalManagedAssets() external view returns (uint256);
}