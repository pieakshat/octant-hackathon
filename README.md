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


## Contract architecture 

for every hook that we build on a particular pool 

there will be two strategy vaults(one vault per asset)....

here's an example (fulll flow)

lets say we are a hook on WETH/UDC pair 

users can come and deposit on either of the strategy vaults they get their respective pool share tokens 
these two strategyVaults don't have to maintain any ratio necessarily.... 

lets say there are 1000USDC and 2 weth in the strategyVaults respectively 

an order comes on our hook for 1000 usdc swap 

we detect it call pull 100 usdc from aave in our usdcStrategyContract onBehalfOf cof CoWHook 

hook completes the swap and we get weth in return(assume 1000usdc = 1 weth)

weth is then supplied back to aave from the hook contract only onBehalfOf WETH strategy vault address

new state 
usdcStrategyVault = 0usdc 
wethStrategyVault = 3 weth 

now les say a user comes to take out their 100 usdc that they deposited 
but usdcStrategyVault has 0 usdc 

so what we do is we pull funds from wethStrategyVault.... by swapping it back to usdc and sending funds to the user







