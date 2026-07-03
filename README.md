# ETH Strategy Contracts

Core Solidity contracts for the ETH Strategy protocol.

This repository contains the on-chain components for STRAT, CDT, ETH-backed bond issuance, convertible notes, staking vaults, treasury lending, and redemption flows.

## Overview

ETH Strategy is a DeFi protocol built around ETH-denominated treasury strategies and STRAT-based convertible instruments. The contracts in this repository provide:

- `STRAT`, the protocol token.
- `CDT`, a debt receipt token used in bond and redemption flows.
- Short ETH bond contracts for issuing CDT positions.
- `EthStrategyConvertibleNote` (ESPN) and related redemption queue flows.
- `esETH`, an ETH-value accounting token for LST holdings.
- ERC-4626 vaults for STRAT staking.
- Treasury lending via `StratETHTreasuryLend`.
- Flash loan providers (e.g. Morpho Blue) used by redemption flows.
- Tripwire guards and controllers for emergency controls.
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

## Integration Tests

Integration tests fork mainnet to test against live protocols (e.g., Sky/MakerDAO flash loans).

To run integration tests (uses Tenderly mainnet fork by default):

```bash
yarn test:integration
```

To use a custom RPC:

```bash
FORK_URL=<your_mainnet_rpc_url> yarn test:integration
```

Integration tests are located in `test/integration/` and include:

- **esETHIntegrationTest.sol**: Tests getETHValue with real mainnet LST tokens
- **ESPNRedemptionQueueIntegrationTest.sol**: Tests ESPN cancellation with Sky flash loans

You will find other useful commands in the [`package.json`](./package.json) file.

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
