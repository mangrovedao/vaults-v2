// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
  KandelManagement,
  OracleRange,
  AbstractKandelSeeder,
  Tick,
  CoreKandel,
  OracleData
} from "../../src/base/KandelManagement.sol";
import {MangroveTest, MockERC20} from "./MangroveTest.t.sol";

contract KandelManagementTest is MangroveTest {
  KandelManagement public management;
  address public manager;
  address public guardian;
  address public owner;
  uint16 public constant MANAGEMENT_FEE = 500; // 5%

  function setUp() public virtual override {
    super.setUp();
    manager = makeAddr("manager");
    guardian = makeAddr("guardian");
    owner = makeAddr("owner");
    OracleData memory oracle;
    oracle.isStatic = true;
    oracle.maxDeviation = 100;
    oracle.timelockMinutes = 60; // 1 hour
    management =
      new KandelManagement(seeder, address(WETH), address(USDC), 1, manager, MANAGEMENT_FEE, oracle, owner, guardian);
  }

  function test_checkTick() public {
    CoreKandel.Params memory params;
    params.pricePoints = 11;
    params.stepSize = 1;
    vm.deal(address(manager), 0.01 ether);
    vm.prank(manager);
    management.populateFromOffset{value: 0.01 ether}(0, 11, Tick.wrap(0), 1, 5, 100e6, 1 ether, params);
  }

  function test_invalidDistribution() public {
    OracleData memory oracle;
    oracle.staticValue = Tick.wrap(100);
    oracle.maxDeviation = 50;
    oracle.isStatic = true;
    vm.startPrank(owner);
    management.proposeOracle(oracle);
    vm.warp(block.timestamp + 61 minutes);
    management.acceptOracle();
    vm.stopPrank();

    CoreKandel.Params memory params;
    params.pricePoints = 3;
    vm.deal(address(manager), 0.01 ether);
    vm.prank(manager);
    vm.expectRevert(KandelManagement.InvalidDistribution.selector);
    // create 3 asks from tick 0 to tick 3 (current tick is 100 with max deviation of 50)
    management.populateFromOffset{value: 0.01 ether}(0, 3, Tick.wrap(0), 1, 0, 0, 1 ether, params);
  }

  function test_validDistributionWithinDeviation() public {
    OracleData memory oracle;
    oracle.staticValue = Tick.wrap(100);
    oracle.maxDeviation = 100;
    oracle.isStatic = true;
    vm.startPrank(owner);
    management.proposeOracle(oracle);
    vm.warp(block.timestamp + 61 minutes);
    management.acceptOracle();
    vm.stopPrank();

    CoreKandel.Params memory params;
    params.pricePoints = 3;
    vm.deal(address(manager), 0.01 ether);
    vm.prank(manager);
    management.populateFromOffset{value: 0.01 ether}(0, 3, Tick.wrap(0), 1, 0, 0, 1 ether, params);
  }



  /*//////////////////////////////////////////////////////////////
                    KANDEL MANAGEMENT TESTS
  //////////////////////////////////////////////////////////////*/

  function test_setManager() public {
    address newManager = makeAddr("newManager");

    vm.expectEmit(true, false, false, true);
    emit KandelManagement.SetManager(newManager);

    vm.prank(owner);
    management.setManager(newManager);

    assertEq(management.manager(), newManager);
  }

  function test_setManager_onlyOwner() public {
    vm.prank(manager);
    vm.expectRevert();
    management.setManager(makeAddr("newManager"));
  }

  function test_setFeeRecipient() public {
    address newFeeRecipient = makeAddr("newFeeRecipient");

    vm.expectEmit(true, false, false, true);
    emit KandelManagement.SetFeeRecipient(newFeeRecipient);

    vm.prank(owner);
    management.setFeeRecipient(newFeeRecipient);

    (, address feeRecipient,,) = management.state();
    assertEq(feeRecipient, newFeeRecipient);
  }

  function test_setFeeRecipient_onlyOwner() public {
    vm.prank(manager);
    vm.expectRevert();
    management.setFeeRecipient(makeAddr("newFeeRecipient"));
  }

  function test_initialState() public view {
    (bool inKandel, address feeRecipient, uint16 managementFee, uint40 lastTimestamp) = management.state();

    assertEq(inKandel, false);
    assertEq(feeRecipient, owner);
    assertEq(managementFee, MANAGEMENT_FEE);
    assertGt(lastTimestamp, 0);
  }

  function test_populateFromOffset_setsInKandel() public {
    CoreKandel.Params memory params;
    params.pricePoints = 5;
    params.stepSize = 1;

    vm.deal(address(manager), 0.01 ether);
    vm.prank(manager);
    management.populateFromOffset{value: 0.01 ether}(0, 5, Tick.wrap(0), 1, 2, 100e6, 1 ether, params);

    (bool inKandel,,,) = management.state();
    assertTrue(inKandel);
  }

  function test_populateFromOffset_onlyManager() public {
    CoreKandel.Params memory params;

    vm.prank(owner);
    vm.expectRevert(KandelManagement.NotManager.selector);
    management.populateFromOffset(0, 5, Tick.wrap(0), 1, 2, 100e6, 1 ether, params);
  }

  function test_populateFromOffset_withActualFunds() public {
    // Mint tokens to the management contract
    uint256 baseAmount = 10 ether; // 10 WETH
    uint256 quoteAmount = 20000e6; // 20,000 USDC
    
    MockERC20(address(WETH)).mint(address(management), baseAmount);
    MockERC20(address(USDC)).mint(address(management), quoteAmount);
    
    // Verify initial balances
    assertEq(WETH.balanceOf(address(management)), baseAmount);
    assertEq(USDC.balanceOf(address(management)), quoteAmount);
    assertEq(WETH.balanceOf(address(management.KANDEL())), 0);
    assertEq(USDC.balanceOf(address(management.KANDEL())), 0);
    
    // Check initial state
    (bool inKandelBefore,,,) = management.state();
    assertFalse(inKandelBefore);
    
    // Set up Kandel parameters
    CoreKandel.Params memory params;
    params.pricePoints = 11;
    params.stepSize = 1;
    
    // Provide ETH for offer provisioning
    vm.deal(address(manager), 0.1 ether);
    
    // Call populateFromOffset as manager
    vm.prank(manager);
    management.populateFromOffset{value: 0.1 ether}(
      0, // from
      11, // to
      Tick.wrap(0), // baseQuoteTickIndex0
      1, // baseQuoteTickOffset
      5, // firstAskIndex (5 bids, 6 asks)
      100e6, // bidGives (100 USDC per bid)
      1 ether, // askGives (1 WETH per ask)
      params
    );
    
    // Verify funds were transferred to Kandel
    assertEq(WETH.balanceOf(address(management)), 0, "Management should have no WETH left");
    assertEq(USDC.balanceOf(address(management)), 0, "Management should have no USDC left");
    assertEq(WETH.balanceOf(address(management.KANDEL())), baseAmount, "Kandel should have received all WETH");
    assertEq(USDC.balanceOf(address(management.KANDEL())), quoteAmount, "Kandel should have received all USDC");
    
    // Verify state changes
    (bool inKandelAfter,,,) = management.state();
    assertTrue(inKandelAfter, "inKandel should be set to true");
  }

  function test_populateFromOffset_withPartialFunds() public {
    // Mint only base tokens to test partial funding
    uint256 baseAmount = 5 ether; // 5 WETH, no USDC
    
    MockERC20(address(WETH)).mint(address(management), baseAmount);
    
    // Verify initial balances
    assertEq(WETH.balanceOf(address(management)), baseAmount);
    assertEq(USDC.balanceOf(address(management)), 0);
    
    // Set up Kandel parameters for asks only (since we only have base tokens)
    CoreKandel.Params memory params;
    params.pricePoints = 6;
    params.stepSize = 1;
    
    vm.deal(address(manager), 0.05 ether);
    
    vm.prank(manager);
    management.populateFromOffset{value: 0.05 ether}(
      5, // from (start from ask side)
      6, // to
      Tick.wrap(0), // baseQuoteTickIndex0
      1, // baseQuoteTickOffset
      5, // firstAskIndex (only asks, no bids)
      0, // bidGives (no bids)
      1 ether, // askGives
      params
    );
    
    // Verify only WETH was transferred (no USDC to transfer)
    assertEq(WETH.balanceOf(address(management)), 0);
    assertEq(USDC.balanceOf(address(management)), 0);
    assertEq(WETH.balanceOf(address(management.KANDEL())), baseAmount);
    assertEq(USDC.balanceOf(address(management.KANDEL())), 0);
    
    (bool inKandel,,,) = management.state();
    assertTrue(inKandel);
  }

  function test_populateFromOffset_withZeroFunds() public {
    // Test with no tokens minted (should still work for strategy setup)
    assertEq(WETH.balanceOf(address(management)), 0);
    assertEq(USDC.balanceOf(address(management)), 0);
    
    CoreKandel.Params memory params;
    params.pricePoints = 3;
    params.stepSize = 1;
    
    vm.deal(address(manager), 0.01 ether);
    
    vm.prank(manager);
    management.populateFromOffset{value: 0.01 ether}(
      0, // from
      3, // to
      Tick.wrap(0), // baseQuoteTickIndex0
      1, // baseQuoteTickOffset
      1, // firstAskIndex
      0, // bidGives
      0, // askGives (no funds to give)
      params
    );
    
    // Balances should remain zero
    assertEq(WETH.balanceOf(address(management)), 0);
    assertEq(USDC.balanceOf(address(management)), 0);
    assertEq(WETH.balanceOf(address(management.KANDEL())), 0);
    assertEq(USDC.balanceOf(address(management.KANDEL())), 0);
    
    // But inKandel should still be set
    (bool inKandel,,,) = management.state();
    assertTrue(inKandel);
  }

  function test_multiplePopulateFromOffset_accumulatesFunds() public {
    // First populate with some funds
    uint256 initialBase = 5 ether;
    uint256 initialQuote = 10000e6;
    
    MockERC20(address(WETH)).mint(address(management), initialBase);
    MockERC20(address(USDC)).mint(address(management), initialQuote);
    
    CoreKandel.Params memory params;
    params.pricePoints = 11;
    params.stepSize = 1;
    
    vm.deal(address(manager), 0.2 ether);
    vm.startPrank(manager);
    
    management.populateFromOffset{value: 0.1 ether}(
      0, 11, Tick.wrap(0), 1, 5, 100e6, 1 ether, params
    );
    
    // Verify first deposit
    assertEq(WETH.balanceOf(address(management.KANDEL())), initialBase);
    assertEq(USDC.balanceOf(address(management.KANDEL())), initialQuote);
    
    // Add more funds to management contract
    uint256 additionalBase = 3 ether;
    uint256 additionalQuote = 5000e6;
    
    MockERC20(address(WETH)).mint(address(management), additionalBase);
    MockERC20(address(USDC)).mint(address(management), additionalQuote);
    
    // Second populate should add to existing funds
    management.populateFromOffset{value: 0.1 ether}(
      0, 11, Tick.wrap(10), 1, 5, 200e6, 2 ether, params
    );
    
    vm.stopPrank();
    
    // Verify total funds accumulated in Kandel
    assertEq(WETH.balanceOf(address(management.KANDEL())), initialBase + additionalBase);
    assertEq(USDC.balanceOf(address(management.KANDEL())), initialQuote + additionalQuote);
    assertEq(WETH.balanceOf(address(management)), 0);
    assertEq(USDC.balanceOf(address(management)), 0);
  }

  function test_populateChunkFromOffset() public {
    // First populate to set up the Kandel
    CoreKandel.Params memory params;
    params.pricePoints = 10;
    params.stepSize = 1;

    vm.deal(address(manager), 0.01 ether);
    vm.startPrank(manager);
    management.populateFromOffset{value: 0.01 ether}(0, 10, Tick.wrap(0), 1, 5, 100e6, 1 ether, params);

    // Now test chunk populate
    management.populateChunkFromOffset(0, 5, Tick.wrap(10), 2, 200e6, 2 ether);
    vm.stopPrank();
  }

  function test_populateChunkFromOffset_onlyManager() public {
    vm.prank(owner);
    vm.expectRevert(KandelManagement.NotManager.selector);
    management.populateChunkFromOffset(0, 5, Tick.wrap(0), 2, 100e6, 1 ether);
  }

  function test_populateChunkFromOffset_invalidDistribution() public {
    // Set restrictive oracle
    OracleData memory restrictiveOracle;
    restrictiveOracle.staticValue = Tick.wrap(100);
    restrictiveOracle.maxDeviation = 10;
    restrictiveOracle.isStatic = true;
    restrictiveOracle.timelockMinutes = 60;

    vm.startPrank(owner);
    management.proposeOracle(restrictiveOracle);
    vm.warp(block.timestamp + 61 minutes);
    management.acceptOracle();
    vm.stopPrank();

    vm.prank(manager);
    vm.expectRevert(KandelManagement.InvalidDistribution.selector);
    management.populateChunkFromOffset(0, 3, Tick.wrap(0), 0, 0, 1 ether);
  }

  /*//////////////////////////////////////////////////////////////
                         EDGE CASE TESTS
  //////////////////////////////////////////////////////////////*/

  function test_constructor_initializesCorrectly() public view {
    assertEq(management.manager(), manager);
    assertEq(management.guardian(), guardian);
    assertEq(management.owner(), owner);

    // Check KANDEL was deployed
    assertTrue(address(management.KANDEL()) != address(0));
  }


}
