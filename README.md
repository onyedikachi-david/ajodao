# AjoDAO

AjoDAO implements transparent, democratic savings circles on Polygon Mumbai using smart contracts and chainlink oracles.

Members pool funds in cycles, taking turns receiving payouts. The contract is upgradeable to integrate governance for treasury management. Built to enable communal crypto savings opportunities.

## Overview

BMembers pool funds in cycles, taking turns receiving payouts. The contract is upgradeable to integrate governance for treasury management. Built to enable communal crypto savings opportunities.

## Technologies

- Solidity - Core contract logic
- Chainlink VRF - Random winner selection
- Chainlink Automation - Auto state transitions
- Chainlink Price Feeds - On-chain price data
- Push Protocol - User notifications

## Joining AjoDAO

- Pay penalty fee (50% of contribution)
- Call joinAjoDAO() with contribution amount
- Receive notification when joined

## Contributing
- Wait for contribution period
- Call contribute() with specified amount
- Get notification on contribution

## Claiming
- If selected as winner by VRF, automatically receive funds
- Get push notification on claim


## Development
The contracts are developed using Hardhat and Solidity.

Key external libraries used:

- @chainlink - For integrating Chainlink functions
- @openzeppelin - Battle tested contracts as base
- @pushprotocol - Push notification SDK

## Token (eth main net)

- 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 USDC
- 0xdAC17F958D2ee523a2206206994597C13D831ec7 USDT
- 0x6B175474E89094C44Da98b954EedeAC495271d0F DAI
- 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599 WBTC
