# MangroveVaultV2

**MangroveVaultV2** is a sophisticated DeFi vault that enables users to deposit funds and participate in automated market making through Kandel strategies on the Mangrove decentralized exchange.

## Overview

Mangrove Vault v2 is a vault that enables people to deposit funds in a vault that manages a Kandel position on Mangrove. **Kandel** is an Automated Market Maker (AMM) built on top of **Mangrove**, a CLOB.

### Key Features

- 🏦 **ERC20 Vault Token**: Users receive transferable shares representing their proportional ownership
- 🤖 **Automated Market Making**: Manages Kandel strategies for continuous liquidity provision
- 🔮 **Oracle Integration**: Supports both static and dynamic price oracles with deviation controls
- 🛡️ **Security Features**: Guardian oversight, timelocks, and whitelisted rebalancing
- 💰 **Fee Management**: Built-in management fee accrual system
- ⚖️ **Rebalancing**: Automated portfolio rebalancing through whitelisted protocols

## Architecture

The vault is built using **Solady** libraries for gas-efficient and secure implementations of:
- `ERC20` - Token standard implementation
- `FixedPointMathLib` - Precise mathematical operations
- `SafeTransferLib` - Secure token transfers
- `ReentrancyGuardTransient` - Reentrancy protection

### Contract Structure

```
MangroveVaultV2 (Main Vault Contract)
├── KandelManagementRebalancing
│   ├── KandelManagement  
│   │   └── OracleRange
│   └── ReentrancyGuardTransient
└── ERC20
```

## Core Components

### 1. MangroveVaultV2.sol
The main vault contract that combines ERC20 functionality with Kandel strategy management.

**Key Functions:**
- `mint()` - Deposit tokens to receive vault shares
- `burn()` - Redeem shares for underlying tokens  
- `getMintAmounts()` - Calculate optimal deposit amounts
- `feeData()` - View current fee configuration and pending fees

### 2. Base Contracts

#### OracleRange.sol
Manages oracle updates with a timelock mechanism and guardian oversight.

**Features:**
- Two-step oracle update process (propose → accept)
- Guardian can reject malicious proposals
- Supports both static price values and dynamic oracle feeds
- Configurable timelock periods for security

**Key Functions:**
- `proposeOracle()` - Propose new oracle configuration
- `acceptOracle()` - Accept proposal after timelock
- `rejectOracle()` - Guardian can reject proposals
- `getCurrentTickInfo()` - Get current price, oracle type, and deviation limits

#### KandelManagement.sol
Manages Kandel market-making strategies with oracle-based position validation.

**Features:**
- Deploys and manages GeometricKandel instances
- Validates all positions against oracle constraints
- Separates operational control (manager) from governance (owner)
- Tracks funds in vault vs. active in Kandel strategy

**Key Functions:**
- `populateFromOffset()` - Deploy Kandel offers with oracle validation
- `retractOffers()` - Remove offers and optionally withdraw funds
- `withdrawFunds()` - Move funds from Kandel back to vault
- `totalBalances()` - View combined vault + Kandel balances

#### KandelManagementRebalancing.sol
Extends KandelManagement with whitelist functionality for authorized rebalancing operations.

**Features:**
- Timelock-based address whitelisting system
- Guardian oversight for whitelist proposals
- Secure rebalancing through approved protocols
- Oracle-validated trade execution

**Key Functions:**
- `proposeWhitelistAddress()` - Propose address for whitelisting
- `acceptWhitelistAddress()` - Accept after timelock period
- `rebalance()` - Execute trades through whitelisted protocols

### 3. Libraries

#### OracleLib.sol
Comprehensive library for oracle data management and price validation.

**Features:**
- Supports both static and dynamic price oracles
- Multiple validation methods (`accepts()`, `withinDeviation()`)
- Timelock enforcement for oracle updates
- Gas-optimized packed struct design

### 4. Interfaces

#### IOracle.sol
Standard interface for external price oracle integration.

## Usage Examples

### Deploying a Vault

```solidity
MangroveVaultV2.VaultInitParams params = MangroveVaultV2.VaultInitParams({
    seeder: kandelSeeder,
    base: baseToken,
    quote: quoteToken,
    tickSpacing: 1,
    manager: managerAddress,
    managementFee: 200, // 2% annual fee
    oracle: initialOracleConfig,
    owner: ownerAddress,
    guardian: guardianAddress,
    name: "Mangrove ETH-USDC Vault",
    symbol: "mgvETH-USDC",
    decimals: 18,
    quoteOffsetDecimals: 6
});

MangroveVaultV2 vault = new MangroveVaultV2(params);
```

### User Interactions

```solidity
// Deposit tokens and receive vault shares
(uint256 shares, uint256 baseIn, uint256 quoteIn) = vault.mint(
    user,
    1000e18,  // max base tokens
    2000e6,   // max quote tokens  
    950e18    // min shares out
);

// Redeem shares for underlying tokens
(uint256 baseOut, uint256 quoteOut) = vault.burn(
    user,
    recipient,
    500e18,   // shares to burn
    400e18,   // min base out
    800e6     // min quote out
);
```

## Development

### Build

```shell
forge build
```

### Test

```shell
forge test
```

### Format

```shell
forge fmt
```

### Gas Snapshots

```shell
forge snapshot
```

## Security Features

- **Guardian System**: Multi-signature guardian can reject malicious oracle proposals
- **Timelock Mechanisms**: All sensitive operations have configurable delays
- **Oracle Validation**: All trading positions validated against price oracles
- **Whitelisted Rebalancing**: Only approved protocols can be used for rebalancing
- **Reentrancy Protection**: Uses Solady's transient reentrancy guard
- **Management Separation**: Operational control separated from governance

## License

MIT License - see [LICENSE](LICENSE) for details.
