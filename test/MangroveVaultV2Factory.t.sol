// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MangroveVaultV2Factory} from "../src/MangroveVaultV2Factory.sol";
import {MangroveVaultV2, OracleData} from "../src/MangroveVaultV2.sol";
import {MangroveTest, MockERC20} from "./base/MangroveTest.t.sol";

contract MangroveVaultV2FactoryTest is MangroveTest {
  MangroveVaultV2Factory public factory;
  address public manager;
  address public guardian;
  address public owner;

  uint16 public constant MANAGEMENT_FEE = 500; // 5%
  uint8 public constant VAULT_DECIMALS = 18;
  uint8 public constant QUOTE_OFFSET_DECIMALS = 6;
  string public constant VAULT_NAME = "Test Mangrove Vault";
  string public constant VAULT_SYMBOL = "TMV";

  function setUp() public virtual override {
    super.setUp();

    factory = new MangroveVaultV2Factory();
    manager = makeAddr("manager");
    guardian = makeAddr("guardian");
    owner = makeAddr("owner");
  }

  function _getDefaultVaultParams() internal view returns (MangroveVaultV2.VaultInitParams memory) {
    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.maxDeviation = 1000;
    oracle.timelockMinutes = 60;

    return MangroveVaultV2.VaultInitParams({
      seeder: seeder,
      base: address(WETH),
      quote: address(USDC),
      tickSpacing: 1,
      manager: manager,
      managementFee: MANAGEMENT_FEE,
      oracle: oracle,
      owner: owner,
      guardian: guardian,
      name: VAULT_NAME,
      symbol: VAULT_SYMBOL,
      decimals: VAULT_DECIMALS,
      quoteOffsetDecimals: QUOTE_OFFSET_DECIMALS
    });
  }

  /*//////////////////////////////////////////////////////////////
                      DEPLOYMENT TESTS
  //////////////////////////////////////////////////////////////*/

  function test_deployVault_basic() public {
    MangroveVaultV2.VaultInitParams memory params = _getDefaultVaultParams();

    address deployedVault = factory.deployVault(params);

    // Verify vault was deployed
    assertNotEq(deployedVault, address(0));
    assertTrue(factory.isDeployedVault(deployedVault));
    assertEq(factory.getDeployedVaultCount(), 1);
    assertEq(factory.getDeployedVault(0), deployedVault);

    // Verify vault properties
    MangroveVaultV2 vault = MangroveVaultV2(deployedVault);
    assertEq(vault.name(), VAULT_NAME);
    assertEq(vault.symbol(), VAULT_SYMBOL);
    assertEq(vault.decimals(), VAULT_DECIMALS);
    assertEq(vault.manager(), manager);
  }

  function test_deployMultipleVaults() public {
    MangroveVaultV2.VaultInitParams memory params1 = _getDefaultVaultParams();
    params1.name = "Vault 1";
    params1.symbol = "V1";

    MangroveVaultV2.VaultInitParams memory params2 = _getDefaultVaultParams();
    params2.name = "Vault 2";
    params2.symbol = "V2";
    params2.manager = makeAddr("manager2");

    address vault1 = factory.deployVault(params1);
    address vault2 = factory.deployVault(params2);

    // Verify both vaults are tracked
    assertEq(factory.getDeployedVaultCount(), 2);
    assertTrue(factory.isDeployedVault(vault1));
    assertTrue(factory.isDeployedVault(vault2));
    assertEq(factory.getDeployedVault(0), vault1);
    assertEq(factory.getDeployedVault(1), vault2);

    // Verify vault properties are different
    assertEq(MangroveVaultV2(vault1).name(), "Vault 1");
    assertEq(MangroveVaultV2(vault2).name(), "Vault 2");
    assertEq(MangroveVaultV2(vault1).manager(), manager);
    assertEq(MangroveVaultV2(vault2).manager(), makeAddr("manager2"));
  }

  /*//////////////////////////////////////////////////////////////
                      VIEW FUNCTION TESTS
  //////////////////////////////////////////////////////////////*/

  function test_getDeployedVaultCount_empty() public {
    assertEq(factory.getDeployedVaultCount(), 0);
  }

  function test_getDeployedVault_revertsOnInvalidIndex() public {
    vm.expectRevert();
    factory.getDeployedVault(0);

    // Deploy one vault
    factory.deployVault(_getDefaultVaultParams());

    vm.expectRevert();
    factory.getDeployedVault(1);
  }

  function test_getAllDeployedVaults_empty() public {
    address[] memory vaults = factory.getAllDeployedVaults();
    assertEq(vaults.length, 0);
  }

  function test_getAllDeployedVaults_multiple() public {
    MangroveVaultV2.VaultInitParams memory params = _getDefaultVaultParams();

    address vault1 = factory.deployVault(params);
    params.name = "Vault 2";
    address vault2 = factory.deployVault(params);
    params.name = "Vault 3";
    address vault3 = factory.deployVault(params);

    address[] memory vaults = factory.getAllDeployedVaults();

    assertEq(vaults.length, 3);
    assertEq(vaults[0], vault1);
    assertEq(vaults[1], vault2);
    assertEq(vaults[2], vault3);
  }

  function test_isDeployedVault_falseForRandomAddress() public {
    assertFalse(factory.isDeployedVault(makeAddr("randomAddress")));
    assertFalse(factory.isDeployedVault(address(this)));
  }

  /*//////////////////////////////////////////////////////////////
                     INTEGRATION TESTS
  //////////////////////////////////////////////////////////////*/

  function test_multipleVaults_independentOperation() public {
    // Deploy two different vaults
    MangroveVaultV2.VaultInitParams memory params1 = _getDefaultVaultParams();
    params1.name = "Vault 1";
    params1.symbol = "V1";

    MangroveVaultV2.VaultInitParams memory params2 = _getDefaultVaultParams();
    params2.name = "Vault 2";
    params2.symbol = "V2";

    address vault1Address = factory.deployVault(params1);
    address vault2Address = factory.deployVault(params2);

    MangroveVaultV2 vault1 = MangroveVaultV2(vault1Address);
    MangroveVaultV2 vault2 = MangroveVaultV2(vault2Address);

    // Verify they are independent
    assertNotEq(vault1Address, vault2Address);
    assertEq(vault1.name(), "Vault 1");
    assertEq(vault2.name(), "Vault 2");

    // Both should be tracked by factory
    assertTrue(factory.isDeployedVault(vault1Address));
    assertTrue(factory.isDeployedVault(vault2Address));
  }

  /*//////////////////////////////////////////////////////////////
                         EDGE CASE TESTS
  //////////////////////////////////////////////////////////////*/

  function test_deployVault_withZeroManagementFee() public {
    MangroveVaultV2.VaultInitParams memory params = _getDefaultVaultParams();
    params.managementFee = 0;

    address vaultAddress = factory.deployVault(params);

    assertTrue(factory.isDeployedVault(vaultAddress));
    MangroveVaultV2 vault = MangroveVaultV2(vaultAddress);

    (uint256 managementFee,,) = vault.feeData();
    assertEq(managementFee, 0);
  }

  /*//////////////////////////////////////////////////////////////
                         FUZZ TESTS
  //////////////////////////////////////////////////////////////*/

  function testFuzz_deployVault_withDifferentFees(uint16 managementFee) public {
    managementFee = uint16(bound(managementFee, 0, 10000)); // 0-100%

    MangroveVaultV2.VaultInitParams memory params = _getDefaultVaultParams();
    params.managementFee = managementFee;

    address vaultAddress = factory.deployVault(params);

    assertTrue(factory.isDeployedVault(vaultAddress));
    MangroveVaultV2 vault = MangroveVaultV2(vaultAddress);

    (uint256 actualFee,,) = vault.feeData();
    assertEq(actualFee, managementFee);
  }

  function testFuzz_deployVault_withDifferentDecimals(uint8 decimals, uint8 quoteOffsetDecimals) public {
    decimals = uint8(bound(decimals, 6, 18));
    quoteOffsetDecimals = uint8(bound(quoteOffsetDecimals, 0, 12));

    MangroveVaultV2.VaultInitParams memory params = _getDefaultVaultParams();
    params.decimals = decimals;
    params.quoteOffsetDecimals = quoteOffsetDecimals;

    address vaultAddress = factory.deployVault(params);

    assertTrue(factory.isDeployedVault(vaultAddress));
    MangroveVaultV2 vault = MangroveVaultV2(vaultAddress);
    assertEq(vault.decimals(), decimals);
  }
}
