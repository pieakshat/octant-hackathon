### Here's what I have to build 

we use octant v2 Vault to take user deposits 

we are only doing it for WETH/USDC pairs on ethereum mainnet 

user deposits either of the token on out vaults

our vaults move those assets to aave to earn yields 

we are building a COW hook on uniswap-v4 

whenever an order is placed on our hook 

we do some computations/analysis (xyz) to see if its a suitable swap 

if yes 
    we pull the funds from aave --> provide liquidity for the swap with fee --> fee goes back to the vault --> the swapped asset comes back to aave

if no 
    we do nothing 