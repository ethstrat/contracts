# ETH Strategy

## Getting Started

Install dependencies: `yarn`

Run forge tests: `yarn test`

## Integration Tests

Integration tests fork mainnet to test against live protocols (e.g., Sky/MakerDAO flash loans).

To run integration tests:
```bash
FORK_URL=<your_mainnet_rpc_url> yarn test:integration
```

Example with Alchemy:
```bash
FORK_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY yarn test:integration
```

Integration tests are located in `test/integration/` and include:
- **esETHIntegrationTest.sol**: Tests getETHValue with real mainnet LST tokens
- **ESPNRedemptionQueueIntegrationTest.sol**: Tests ESPN cancellation with Sky flash loans

You will find other useful commands in the [`package.json`](./package.json) file.
