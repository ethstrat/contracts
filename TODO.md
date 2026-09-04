# ETH Strategy Protocol Testing & Review TODO

## Integration Testing
- **Full protocol integration test suite**: Create comprehensive tests that deploy all contracts together and test realistic user flows across the entire protocol (esETH, TreasuryLend, ESPN, ConvertibleNotes, RedemptionQueue)
- **Cross-contract interaction testing**: Test scenarios where users interact with multiple contracts in sequence (e.g., mint esETH, use as collateral in TreasuryLend)
- **Multi-user concurrent operations**: Test scenarios with multiple users performing operations simultaneously to check for race conditions and state consistency
- **Realistic deployment simulation**: Create tests that simulate real-world deployment sequence with proper initialization, approvals, and seeding

## Mainnet Fork Testing
- **esETH conversion accuracy**: Verify all LST conversion functions (wstETH, rETH, cETH, aETHv2, ankrETH) return correct ETH values on mainnet
- **Oracle price feeds**: Test with real Chainlink ETH/USD price feeds to ensure pricing calculations work correctly
- **TreasuryLend liquidation timing**: Test liquidation mechanics with real time passage to ensure expiry logic works
- **Flash loan dependencies**: Test ESPN redemption queue cancellation mechanics with real Sky flash loans
- **Token approvals and balances**: Verify all approval flows work with real token contracts

## Economic Model & Invariant Testing
- **Backing ratio maintenance**: Ensure esETH maintains proper backing across all operations (mint, redeem, harvest, burnExcess)
- **TreasuryLend solvency**: Verify that TreasuryLend can always service redemptions and liquidations even with extreme market conditions
- **Convertible note entitlements**: Verify conversion entitlements are calculated correctly and maintain value preservation
- **Yield harvesting accuracy**: Test yield harvesting captures exactly the right amount when backing exceeds supply
- **Redemption queue ordering**: Ensure FIFO ordering is maintained and queue position calculations are accurate

## Security & Edge Case Testing
- **Reentrancy attack vectors**: Comprehensive testing of all external calls, especially around token transfers and flash loans
- **Access control validation**: Test all privileged operations with unauthorized callers, including edge cases like ownership transfers
- **Input validation boundaries**: Test all functions with extreme values (zero, max uint256, negative values where possible)
- **Timing attacks**: Test operations at exact boundary times (timelock expiry, loan expiry, conversion windows)
- **Slippage protection**: Verify slippage checks work correctly and protect users from unfavorable executions
- **Flash loan callback security**: Test flash loan integrations handle failures, reentrancy, and incorrect repayments
- **ERC721 transfer safety**: Test NFT transfers don't allow unauthorized settlement operations

## State Consistency & Invariant Checks
- **esETH supply invariants**: totalSupply = sum of all minted amounts for each token type
- **TreasuryLend position tracking**: Position balances match stored collateral and debt amounts
- **Convertible note balances**: Remaining entitlements and CDT owed are always consistent
- **ESPN vault accounting**: totalAssets accurately reflects underlying asset balance
- **Redemption queue totals**: totalQueued >= totalRedemptionsProcessed + totalCancellationsProcessed

## Real-World Scenario Testing
- **Large position handling**: Test with realistic ETH amounts ($100k+) to ensure precision isn't lost
- **Gas optimization review**: Measure and optimize gas costs for common operations
- **MEV opportunity analysis**: Review operations for sandwich attack potential and implement protections
- **Liquidity stress testing**: Test protocol behavior when external liquidity is low or expensive
- **Network congestion handling**: Test behavior during high gas periods and potential transaction failures

## Governance & Upgrade Testing
- **Parameter change effects**: Test how changing rates, caps, and other parameters affects existing positions
- **Ownership transfer safety**: Test ownership transfers don't break functionality or approvals
- **Emergency pause mechanisms**: Test pause/unpause functionality across all contracts
- **Upgrade path validation**: Test contract upgrades maintain state compatibility and don't break integrations

## User Experience & Integration Testing
- **Frontend integration helpers**: Test all view functions return correct data for UIs
- **Permit workflow testing**: Test ERC-2612 permit flows for gasless approvals
- **Multi-step transaction safety**: Test scenarios where users need to perform sequences of transactions
- **Error message clarity**: Verify all revert reasons are clear and actionable for users
- **Event emission completeness**: Ensure all state changes emit appropriate events for off-chain monitoring

## Protocol Lifecycle Testing
- **Bootstrap sequence**: Test initial protocol deployment and seeding
- **Normal operation steady state**: Test ongoing protocol operation with regular user activity
- **Stress scenarios**: Test protocol behavior during high volatility, mass redemptions, or liquidity events
- **Recovery mechanisms**: Test emergency procedures and protocol recovery from adverse states
- **Long-term sustainability**: Test protocol behavior over extended periods with compounding effects

## Audit Preparation & Formal Verification
- **Invariant documentation**: Document all protocol invariants that must hold
- **Slither/Certora setup**: Prepare codebase for automated security analysis tools
- **Test coverage metrics**: Achieve >95% test coverage across all contracts
- **Fuzz testing**: Implement fuzz tests for critical functions with complex logic
- **Symbolic execution**: Prepare key functions for formal verification

## Performance & Scalability
- **Batch operation testing**: Test batch versions of operations for efficiency
- **Storage optimization**: Review storage patterns for gas efficiency
- **Loop bounds analysis**: Ensure no unbounded loops in critical paths
- **Event optimization**: Minimize redundant event emissions

## External Dependency Testing
- **Oracle failure scenarios**: Test protocol behavior when price feeds fail or return stale data
- **Token contract edge cases**: Test with tokens that have unusual ERC20 implementations
- **Flash loan provider changes**: Test with different flash loan providers and fee structures
- **Network-specific behavior**: Test on different networks (mainnet, testnets) for consistency

## Documentation & Review
- **Code comment completeness**: Ensure all complex logic is well-documented
- **User story coverage review**: Verify all user stories have corresponding tests
- **Architecture documentation**: Create system architecture diagrams and flow documentation
- **Operational runbooks**: Document monitoring, alerting, and incident response procedures

