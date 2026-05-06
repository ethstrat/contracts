# ETH Strategy Contracts

Core Solidity contracts for the ETH Strategy protocol.

This repository contains the on-chain components for STRAT, CDT, oSTRAT options, ETH-backed bond issuance, treasury operations, staking vaults, presale redemption flows, and the ETH Strategy Perpetual Note system.

## Overview

ETH Strategy is a DeFi protocol built around ETH-denominated treasury strategies and STRAT-based convertible instruments. The contracts in this repository provide:

- `STRAT`, the protocol token.
- `CDT`, a debt receipt token used in bond and redemption flows.
- `oSTRAT`, ERC-721 option tokens representing STRAT conversion rights.
- Long and short ETH bond contracts for issuing CDT and oSTRAT positions.
- Treasury contracts for tracking and staging ETH liquidity.
- ERC-4626 vaults for STRAT staking, ESPN notes, and ESPN LP staking.
- Presale, vesting, and redemption helpers for early oSTRAT holders.
- Oracle helpers for ETH/USD and STRAT/ETH pricing.

## Development

Install dependencies:

```sh
yarn
```

Build contracts:

```sh
yarn build
```

Run the test suite:

```sh
yarn test
```

Format Solidity files:

```sh
yarn lint:fix
```

## Project Structure

```text
src/          Protocol contracts, interfaces, and libraries
test/         Foundry tests, mocks, and test helpers
foundry.toml  Foundry configuration
package.json  Development scripts
```

## Security

These contracts are provided for review and development. Before using them in production, complete independent security review, deployment verification, and operational testing.

If you discover a vulnerability, please report it privately to the maintainers before public disclosure.

## License

See `LICENSE` and individual Solidity SPDX headers for licensing details.
