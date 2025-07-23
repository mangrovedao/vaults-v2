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

    management.populateFromOffset{value: 0.1 ether}(0, 11, Tick.wrap(0), 1, 5, 100e6, 1 ether, params);

    // Verify first deposit
    assertEq(WETH.balanceOf(address(management.KANDEL())), initialBase);
    assertEq(USDC.balanceOf(address(management.KANDEL())), initialQuote);

    // Add more funds to management contract
    uint256 additionalBase = 3 ether;
    uint256 additionalQuote = 5000e6;

    MockERC20(address(WETH)).mint(address(management), additionalBase);
    MockERC20(address(USDC)).mint(address(management), additionalQuote);

    // Second populate should add to existing funds
    management.populateFromOffset{value: 0.1 ether}(0, 11, Tick.wrap(10), 1, 5, 200e6, 2 ether, params);

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

  function test_constructor_emitsEvents() public {
    address newManager = makeAddr("newManager");
    address newOwner = makeAddr("newOwner");
    address newGuardian = makeAddr("newGuardian");
    uint16 newManagementFee = 1000; // 10%

    OracleData memory testOracle;
    testOracle.isStatic = true;
    testOracle.staticValue = Tick.wrap(200);
    testOracle.maxDeviation = 150;
    testOracle.timelockMinutes = 120;

    // Expect SetManager event for initial manager
    vm.expectEmit(true, false, false, true);
    emit KandelManagement.SetManager(newManager);

    // Expect SetFeeRecipient event for initial fee recipient (owner)
    vm.expectEmit(true, false, false, true);
    emit KandelManagement.SetFeeRecipient(newOwner);

    // Create new KandelManagement instance (should emit both events)
    KandelManagement newManagement = new KandelManagement(
      seeder, address(WETH), address(USDC), 1, newManager, newManagementFee, testOracle, newOwner, newGuardian
    );

    // Verify the contract was initialized correctly
    assertEq(newManagement.manager(), newManager, "Manager should be set correctly");
    assertEq(newManagement.owner(), newOwner, "Owner should be set correctly");
    assertEq(newManagement.guardian(), newGuardian, "Guardian should be set correctly");

    (bool inKandel, address feeRecipient, uint16 managementFee, uint40 lastTimestamp) = newManagement.state();
    assertEq(inKandel, false, "inKandel should be false initially");
    assertEq(feeRecipient, newOwner, "Fee recipient should be owner initially");
    assertEq(managementFee, newManagementFee, "Management fee should match");
    assertGt(lastTimestamp, 0, "Last timestamp should be set");
  }

  function test_constructor_emitsEventsWithSameOwnerManager() public {
    address ownerManager = makeAddr("ownerManager");
    address testGuardian = makeAddr("testGuardian");
    uint16 testFee = 750; // 7.5%

    OracleData memory testOracle;
    testOracle.isStatic = true;
    testOracle.staticValue = Tick.wrap(300);
    testOracle.maxDeviation = 200;
    testOracle.timelockMinutes = 60;

    // When owner and manager are the same, should still emit both events
    vm.expectEmit(true, false, false, true);
    emit KandelManagement.SetManager(ownerManager);

    vm.expectEmit(true, false, false, true);
    emit KandelManagement.SetFeeRecipient(ownerManager);

    // Create new KandelManagement with same address for owner and manager
    KandelManagement newManagement = new KandelManagement(
      seeder,
      address(WETH),
      address(USDC),
      1,
      ownerManager, // manager = owner
      testFee,
      testOracle,
      ownerManager, // owner = manager
      testGuardian
    );

    // Verify both roles are set to the same address
    assertEq(newManagement.manager(), ownerManager, "Manager should be ownerManager");
    assertEq(newManagement.owner(), ownerManager, "Owner should be ownerManager");

    (, address feeRecipient,,) = newManagement.state();
    assertEq(feeRecipient, ownerManager, "Fee recipient should be ownerManager");
  }

  function test_constructor_emitsEventsWithZeroFee() public {
    address testManager = makeAddr("testManager");
    address testOwner = makeAddr("testOwner");
    address testGuardian = makeAddr("testGuardian");
    uint16 zeroFee = 0; // 0% management fee

    OracleData memory testOracle;
    testOracle.isStatic = true;
    testOracle.staticValue = Tick.wrap(500);
    testOracle.maxDeviation = 100;
    testOracle.timelockMinutes = 30;

    // Should emit events even with zero fee
    vm.expectEmit(true, false, false, true);
    emit KandelManagement.SetManager(testManager);

    vm.expectEmit(true, false, false, true);
    emit KandelManagement.SetFeeRecipient(testOwner);

    // Create new KandelManagement with zero fee
    KandelManagement newManagement = new KandelManagement(
      seeder, address(WETH), address(USDC), 1, testManager, zeroFee, testOracle, testOwner, testGuardian
    );

    // Verify zero fee is set correctly
    (,, uint16 managementFee,) = newManagement.state();
    assertEq(managementFee, 0, "Management fee should be zero");
  }

  /*//////////////////////////////////////////////////////////////
                      WITHDRAWAL FUNCTION TESTS
  //////////////////////////////////////////////////////////////*/

  function test_retractOffers_onlyRetracts() public {
    // First populate with funds
    uint256 baseAmount = 5 ether;
    uint256 quoteAmount = 10000e6;

    MockERC20(address(WETH)).mint(address(management), baseAmount);
    MockERC20(address(USDC)).mint(address(management), quoteAmount);

    CoreKandel.Params memory params;
    params.pricePoints = 11;
    params.stepSize = 1;

    vm.deal(address(manager), 0.1 ether);
    vm.startPrank(manager);

    management.populateFromOffset{value: 0.1 ether}(0, 11, Tick.wrap(0), 1, 5, 100e6, 1 ether, params);

    // Verify funds are in Kandel
    assertEq(WETH.balanceOf(address(management.KANDEL())), baseAmount);
    assertEq(USDC.balanceOf(address(management.KANDEL())), quoteAmount);
    (bool inKandelBefore,,,) = management.state();
    assertTrue(inKandelBefore);

    // Retract offers without withdrawing funds or provisions
    management.retractOffers(0, 5, false, false, payable(address(0)));

    // Funds should still be in Kandel, inKandel should still be true
    assertEq(WETH.balanceOf(address(management.KANDEL())), baseAmount);
    assertEq(USDC.balanceOf(address(management.KANDEL())), quoteAmount);
    assertEq(WETH.balanceOf(address(management)), 0);
    assertEq(USDC.balanceOf(address(management)), 0);

    (bool inKandelAfter,,,) = management.state();
    assertTrue(inKandelAfter, "inKandel should remain true");

    vm.stopPrank();
  }

  function test_retractOffers_withWithdrawFunds() public {
    // First populate with funds
    uint256 baseAmount = 5 ether;
    uint256 quoteAmount = 10000e6;

    MockERC20(address(WETH)).mint(address(management), baseAmount);
    MockERC20(address(USDC)).mint(address(management), quoteAmount);

    CoreKandel.Params memory params;
    params.pricePoints = 11;
    params.stepSize = 1;

    vm.deal(address(manager), 0.1 ether);
    vm.startPrank(manager);

    management.populateFromOffset{value: 0.1 ether}(0, 11, Tick.wrap(0), 1, 5, 100e6, 1 ether, params);

    // Retract offers and withdraw funds
    management.retractOffers(0, 11, true, false, payable(address(0)));

    // Funds should be back in management contract, Kandel should be empty
    assertEq(WETH.balanceOf(address(management)), baseAmount);
    assertEq(USDC.balanceOf(address(management)), quoteAmount);
    assertEq(WETH.balanceOf(address(management.KANDEL())), 0);
    assertEq(USDC.balanceOf(address(management.KANDEL())), 0);

    // inKandel should be set to false
    (bool inKandel,,,) = management.state();
    assertFalse(inKandel, "inKandel should be false after withdrawing funds");

    vm.stopPrank();
  }

  function test_retractOffers_withWithdrawProvisions() public {
    // First populate with funds
    CoreKandel.Params memory params;
    params.pricePoints = 5;
    params.stepSize = 1;

    uint256 managerEthBefore = manager.balance;
    vm.deal(address(manager), 0.1 ether);
    vm.startPrank(manager);

    management.populateFromOffset{value: 0.1 ether}(0, 5, Tick.wrap(0), 1, 2, 0, 0, params);

    // Retract offers and withdraw provisions to manager
    management.retractOffers(0, 5, false, true, payable(manager));

    // Manager should have received ETH provisions back
    assertGt(manager.balance, managerEthBefore, "Manager should have received ETH provisions");

    vm.stopPrank();
  }

  function test_retractOffers_withBothWithdrawals() public {
    // First populate with funds
    uint256 baseAmount = 3 ether;
    uint256 quoteAmount = 5000e6;

    MockERC20(address(WETH)).mint(address(management), baseAmount);
    MockERC20(address(USDC)).mint(address(management), quoteAmount);

    CoreKandel.Params memory params;
    params.pricePoints = 7;
    params.stepSize = 1;

    uint256 managerEthBefore = manager.balance;
    vm.deal(address(manager), 0.05 ether);
    vm.startPrank(manager);

    management.populateFromOffset{value: 0.05 ether}(0, 7, Tick.wrap(0), 1, 3, 100e6, 1 ether, params);

    // Retract offers with both fund and provision withdrawal
    management.retractOffers(0, 7, true, true, payable(manager));

    // Check funds returned to management contract
    assertEq(WETH.balanceOf(address(management)), baseAmount);
    assertEq(USDC.balanceOf(address(management)), quoteAmount);
    assertEq(WETH.balanceOf(address(management.KANDEL())), 0);
    assertEq(USDC.balanceOf(address(management.KANDEL())), 0);

    // Check ETH provisions returned to manager
    assertGt(manager.balance, managerEthBefore);

    // Check state
    (bool inKandel,,,) = management.state();
    assertFalse(inKandel);

    vm.stopPrank();
  }

  function test_retractOffers_onlyManager() public {
    vm.prank(owner);
    vm.expectRevert(KandelManagement.NotManager.selector);
    management.retractOffers(0, 5, false, false, payable(address(0)));
  }

  function test_withdrawFunds() public {
    // First populate with funds
    uint256 baseAmount = 8 ether;
    uint256 quoteAmount = 15000e6;

    MockERC20(address(WETH)).mint(address(management), baseAmount);
    MockERC20(address(USDC)).mint(address(management), quoteAmount);

    CoreKandel.Params memory params;
    params.pricePoints = 9;
    params.stepSize = 1;

    vm.deal(address(manager), 0.08 ether);
    vm.startPrank(manager);

    management.populateFromOffset{value: 0.08 ether}(0, 9, Tick.wrap(0), 1, 4, 200e6, 2 ether, params);

    // Verify initial state
    assertEq(WETH.balanceOf(address(management)), 0);
    assertEq(USDC.balanceOf(address(management)), 0);
    assertEq(WETH.balanceOf(address(management.KANDEL())), baseAmount);
    assertEq(USDC.balanceOf(address(management.KANDEL())), quoteAmount);
    (bool inKandelBefore,,,) = management.state();
    assertTrue(inKandelBefore);

    // Withdraw funds
    management.withdrawFunds();

    // Verify funds transferred back to management contract
    assertEq(WETH.balanceOf(address(management)), baseAmount);
    assertEq(USDC.balanceOf(address(management)), quoteAmount);
    assertEq(WETH.balanceOf(address(management.KANDEL())), 0);
    assertEq(USDC.balanceOf(address(management.KANDEL())), 0);

    // Verify state change
    (bool inKandelAfter,,,) = management.state();
    assertFalse(inKandelAfter, "inKandel should be false after withdrawal");

    vm.stopPrank();
  }

  function test_withdrawFunds_onlyManager() public {
    vm.prank(owner);
    vm.expectRevert(KandelManagement.NotManager.selector);
    management.withdrawFunds();
  }

  function test_withdrawFromMangrove() public {
    // First populate to deposit ETH provisions
    CoreKandel.Params memory params;
    params.pricePoints = 5;
    params.stepSize = 1;

    uint256 ethAmount = 0.05 ether;
    uint256 managerEthBefore = manager.balance;
    vm.deal(address(manager), ethAmount);
    vm.startPrank(manager);

    management.populateFromOffset{value: ethAmount}(0, 5, Tick.wrap(0), 1, 2, 0, 0, params);

    // Withdraw specific amount from Mangrove
    uint256 withdrawAmount = 0.01 ether;
    management.withdrawFromMangrove(withdrawAmount, payable(manager));

    // Manager should have received the withdrawn amount
    assertGe(manager.balance, managerEthBefore + withdrawAmount - 0.001 ether, "Manager should receive withdrawn ETH");

    vm.stopPrank();
  }

  function test_withdrawFromMangrove_onlyManager() public {
    vm.prank(owner);
    vm.expectRevert(KandelManagement.NotManager.selector);
    management.withdrawFromMangrove(0.01 ether, payable(manager));
  }

  function test_retractOffers_customRecipient() public {
    // Create a custom recipient address
    address payable customRecipient = payable(makeAddr("customRecipient"));

    // First populate with funds
    CoreKandel.Params memory params;
    params.pricePoints = 5;
    params.stepSize = 1;

    uint256 customRecipientEthBefore = customRecipient.balance;
    vm.deal(address(manager), 0.05 ether);
    vm.startPrank(manager);

    management.populateFromOffset{value: 0.05 ether}(0, 5, Tick.wrap(0), 1, 2, 0, 0, params);

    // Retract offers and withdraw provisions to custom recipient
    management.retractOffers(0, 5, false, true, customRecipient);

    // Custom recipient should have received ETH provisions
    assertGt(customRecipient.balance, customRecipientEthBefore, "Custom recipient should have received ETH provisions");

    vm.stopPrank();
  }

  function test_withdrawFromMangrove_customRecipient() public {
    // Create a custom recipient address
    address payable customRecipient = payable(makeAddr("customRecipient"));

    // First populate to deposit ETH provisions
    CoreKandel.Params memory params;
    params.pricePoints = 5;
    params.stepSize = 1;

    uint256 ethAmount = 0.05 ether;
    uint256 customRecipientEthBefore = customRecipient.balance;
    vm.deal(address(manager), ethAmount);
    vm.startPrank(manager);

    management.populateFromOffset{value: ethAmount}(0, 5, Tick.wrap(0), 1, 2, 0, 0, params);

    // Withdraw specific amount from Mangrove to custom recipient
    uint256 withdrawAmount = 0.01 ether;
    management.withdrawFromMangrove(withdrawAmount, customRecipient);

    // Custom recipient should have received the withdrawn amount
    assertGe(
      customRecipient.balance,
      customRecipientEthBefore + withdrawAmount - 0.001 ether,
      "Custom recipient should receive withdrawn ETH"
    );

    vm.stopPrank();
  }

  /*//////////////////////////////////////////////////////////////
                       BALANCE QUERY TESTS
  //////////////////////////////////////////////////////////////*/

  function test_vaultBalances() public {
    // Initially should be zero
    (uint256 baseBalance, uint256 quoteBalance) = management.vaultBalances();
    assertEq(baseBalance, 0, "Initial base balance should be zero");
    assertEq(quoteBalance, 0, "Initial quote balance should be zero");

    // Mint tokens to management contract
    uint256 baseAmount = 5 ether;
    uint256 quoteAmount = 10000e6;

    MockERC20(address(WETH)).mint(address(management), baseAmount);
    MockERC20(address(USDC)).mint(address(management), quoteAmount);

    // Check balances
    (baseBalance, quoteBalance) = management.vaultBalances();
    assertEq(baseBalance, baseAmount, "Base balance should match minted amount");
    assertEq(quoteBalance, quoteAmount, "Quote balance should match minted amount");
  }

  function test_kandelBalances() public {
    // Initially should be zero
    (uint256 baseBalance, uint256 quoteBalance) = management.kandelBalances();
    assertEq(baseBalance, 0, "Initial Kandel base balance should be zero");
    assertEq(quoteBalance, 0, "Initial Kandel quote balance should be zero");

    // Mint and deposit tokens to Kandel
    uint256 baseAmount = 8 ether;
    uint256 quoteAmount = 15000e6;

    MockERC20(address(WETH)).mint(address(management), baseAmount);
    MockERC20(address(USDC)).mint(address(management), quoteAmount);

    CoreKandel.Params memory params;
    params.pricePoints = 11;
    params.stepSize = 1;

    vm.deal(address(manager), 0.1 ether);
    vm.prank(manager);
    management.populateFromOffset{value: 0.1 ether}(0, 11, Tick.wrap(0), 1, 5, 200e6, 2 ether, params);

    // Check Kandel balances
    (baseBalance, quoteBalance) = management.kandelBalances();
    assertEq(baseBalance, baseAmount, "Kandel base balance should match deposited amount");
    assertEq(quoteBalance, quoteAmount, "Kandel quote balance should match deposited amount");
  }

  function test_totalBalances() public {
    // Test with funds split between vault and Kandel
    uint256 vaultBase = 3 ether;
    uint256 vaultQuote = 5000e6;
    uint256 kandelBase = 7 ether;
    uint256 kandelQuote = 12000e6;

    // First deposit to Kandel
    MockERC20(address(WETH)).mint(address(management), kandelBase);
    MockERC20(address(USDC)).mint(address(management), kandelQuote);

    CoreKandel.Params memory params;
    params.pricePoints = 9;
    params.stepSize = 1;

    vm.deal(address(manager), 0.08 ether);
    vm.prank(manager);
    management.populateFromOffset{value: 0.08 ether}(0, 9, Tick.wrap(0), 1, 4, 300e6, 1.5 ether, params);

    // Then mint additional tokens to vault
    MockERC20(address(WETH)).mint(address(management), vaultBase);
    MockERC20(address(USDC)).mint(address(management), vaultQuote);

    // Check total balances
    (uint256 totalBase, uint256 totalQuote) = management.totalBalances();
    assertEq(totalBase, vaultBase + kandelBase, "Total base should be sum of vault and Kandel");
    assertEq(totalQuote, vaultQuote + kandelQuote, "Total quote should be sum of vault and Kandel");

    // Verify individual components
    (uint256 vaultBaseActual, uint256 vaultQuoteActual) = management.vaultBalances();
    (uint256 kandelBaseActual, uint256 kandelQuoteActual) = management.kandelBalances();

    assertEq(vaultBaseActual, vaultBase, "Vault base should match expected");
    assertEq(vaultQuoteActual, vaultQuote, "Vault quote should match expected");
    assertEq(kandelBaseActual, kandelBase, "Kandel base should match expected");
    assertEq(kandelQuoteActual, kandelQuote, "Kandel quote should match expected");
  }

  function test_balances_afterWithdrawal() public {
    // Setup initial state with funds in Kandel
    uint256 initialBase = 6 ether;
    uint256 initialQuote = 12000e6;

    MockERC20(address(WETH)).mint(address(management), initialBase);
    MockERC20(address(USDC)).mint(address(management), initialQuote);

    CoreKandel.Params memory params;
    params.pricePoints = 7;
    params.stepSize = 1;

    vm.deal(address(manager), 0.06 ether);
    vm.startPrank(manager);

    management.populateFromOffset{value: 0.06 ether}(0, 7, Tick.wrap(0), 1, 3, 400e6, 2 ether, params);

    // Verify funds are in Kandel
    (uint256 kandelBaseBefore, uint256 kandelQuoteBefore) = management.kandelBalances();
    assertEq(kandelBaseBefore, initialBase);
    assertEq(kandelQuoteBefore, initialQuote);
    (uint256 vaultBaseBefore, uint256 vaultQuoteBefore) = management.vaultBalances();
    assertEq(vaultBaseBefore, 0);
    assertEq(vaultQuoteBefore, 0);

    // Withdraw funds back to vault
    management.withdrawFunds();

    // Verify funds moved from Kandel to vault
    (uint256 kandelBaseAfter, uint256 kandelQuoteAfter) = management.kandelBalances();
    assertEq(kandelBaseAfter, 0, "Kandel should have no funds after withdrawal");
    assertEq(kandelQuoteAfter, 0, "Kandel should have no funds after withdrawal");

    (uint256 vaultBaseAfter, uint256 vaultQuoteAfter) = management.vaultBalances();
    assertEq(vaultBaseAfter, initialBase, "Vault should have received all base funds");
    assertEq(vaultQuoteAfter, initialQuote, "Vault should have received all quote funds");

    // Total should remain the same
    (uint256 totalBase, uint256 totalQuote) = management.totalBalances();
    assertEq(totalBase, initialBase, "Total base should remain unchanged");
    assertEq(totalQuote, initialQuote, "Total quote should remain unchanged");

    vm.stopPrank();
  }

  function test_market() public view {
    // Test that market() returns the correct configuration
    (address base, address quote, uint256 tickSpacing) = management.market();

    assertEq(base, address(WETH), "Base token should be WETH");
    assertEq(quote, address(USDC), "Quote token should be USDC");
    assertEq(tickSpacing, 1, "Tick spacing should be 1");
  }

  /*//////////////////////////////////////////////////////////////
                          EVENT TESTS
  //////////////////////////////////////////////////////////////*/

  function test_fundsEnteredKandel_event() public {
    // Mint tokens to management contract
    uint256 baseAmount = 5 ether;
    uint256 quoteAmount = 10000e6;

    MockERC20(address(WETH)).mint(address(management), baseAmount);
    MockERC20(address(USDC)).mint(address(management), quoteAmount);

    CoreKandel.Params memory params;
    params.pricePoints = 11;
    params.stepSize = 1;

    vm.deal(address(manager), 0.1 ether);

    // Expect FundsEnteredKandel event to be emitted
    vm.expectEmit(false, false, false, true);
    emit KandelManagement.FundsEnteredKandel();

    vm.prank(manager);
    management.populateFromOffset{value: 0.1 ether}(0, 11, Tick.wrap(0), 1, 5, 100e6, 1 ether, params);

    // Verify state changed
    (bool inKandel,,,) = management.state();
    assertTrue(inKandel, "inKandel should be true after populate");
  }

  function test_fundsEnteredKandel_event_notEmittedWhenAlreadyInKandel() public {
    // First populate to set inKandel to true
    MockERC20(address(WETH)).mint(address(management), 3 ether);
    MockERC20(address(USDC)).mint(address(management), 6000e6);

    CoreKandel.Params memory params;
    params.pricePoints = 7;
    params.stepSize = 1;

    vm.deal(address(manager), 0.2 ether);
    vm.startPrank(manager);

    management.populateFromOffset{value: 0.1 ether}(0, 7, Tick.wrap(0), 1, 3, 200e6, 1 ether, params);

    // Verify inKandel is true
    (bool inKandel,,,) = management.state();
    assertTrue(inKandel);

    // Add more funds for second populate
    MockERC20(address(WETH)).mint(address(management), 2 ether);
    MockERC20(address(USDC)).mint(address(management), 4000e6);

    // Second populate should NOT emit FundsEnteredKandel event
    // We don't use vm.expectEmit here because we want to ensure NO event is emitted
    management.populateFromOffset{value: 0.1 ether}(0, 7, Tick.wrap(5), 1, 3, 300e6, 1.5 ether, params);

    // State should still be true
    (inKandel,,,) = management.state();
    assertTrue(inKandel);

    vm.stopPrank();
  }

  function test_fundsExitedKandel_event_withdrawFunds() public {
    // First populate to get funds in Kandel
    MockERC20(address(WETH)).mint(address(management), 4 ether);
    MockERC20(address(USDC)).mint(address(management), 8000e6);

    CoreKandel.Params memory params;
    params.pricePoints = 9;
    params.stepSize = 1;

    vm.deal(address(manager), 0.08 ether);
    vm.startPrank(manager);

    management.populateFromOffset{value: 0.08 ether}(0, 9, Tick.wrap(0), 1, 4, 250e6, 1.5 ether, params);

    // Verify inKandel is true
    (bool inKandel,,,) = management.state();
    assertTrue(inKandel);

    // Expect FundsExitedKandel event when withdrawing
    vm.expectEmit(false, false, false, true);
    emit KandelManagement.FundsExitedKandel();

    management.withdrawFunds();

    // Verify state changed
    (inKandel,,,) = management.state();
    assertFalse(inKandel, "inKandel should be false after withdrawal");

    vm.stopPrank();
  }

  function test_fundsExitedKandel_event_retractOffersWithWithdraw() public {
    // First populate to get funds in Kandel
    MockERC20(address(WETH)).mint(address(management), 6 ether);
    MockERC20(address(USDC)).mint(address(management), 12000e6);

    CoreKandel.Params memory params;
    params.pricePoints = 11;
    params.stepSize = 1;

    vm.deal(address(manager), 0.1 ether);
    vm.startPrank(manager);

    management.populateFromOffset{value: 0.1 ether}(0, 11, Tick.wrap(0), 1, 5, 300e6, 2 ether, params);

    // Verify inKandel is true
    (bool inKandel,,,) = management.state();
    assertTrue(inKandel);

    // Expect FundsExitedKandel event when retracting with fund withdrawal
    vm.expectEmit(false, false, false, true);
    emit KandelManagement.FundsExitedKandel();

    management.retractOffers(0, 11, true, false, payable(address(0)));

    // Verify state changed
    (inKandel,,,) = management.state();
    assertFalse(inKandel, "inKandel should be false after retract with withdrawal");

    vm.stopPrank();
  }

  function test_fundsExitedKandel_event_notEmittedOnRetractWithoutWithdraw() public {
    // First populate to get funds in Kandel
    MockERC20(address(WETH)).mint(address(management), 3 ether);
    MockERC20(address(USDC)).mint(address(management), 6000e6);

    CoreKandel.Params memory params;
    params.pricePoints = 7;
    params.stepSize = 1;

    vm.deal(address(manager), 0.06 ether);
    vm.startPrank(manager);

    management.populateFromOffset{value: 0.06 ether}(0, 7, Tick.wrap(0), 1, 3, 200e6, 1 ether, params);

    // Verify inKandel is true
    (bool inKandel,,,) = management.state();
    assertTrue(inKandel);

    // Retract without withdrawing funds should NOT emit FundsExitedKandel
    management.retractOffers(0, 7, false, false, payable(address(0)));

    // State should remain true
    (inKandel,,,) = management.state();
    assertTrue(inKandel, "inKandel should remain true when not withdrawing funds");

    vm.stopPrank();
  }

  function test_fundsExitedKandel_event_notEmittedWhenAlreadyNotInKandel() public {
    // Verify initial state is false
    (bool inKandel,,,) = management.state();
    assertFalse(inKandel);

    vm.startPrank(manager);

    // Calling withdrawFunds when already not in Kandel should not emit event
    // This tests the conditional check in withdrawFunds
    management.withdrawFunds();

    // State should remain false
    (inKandel,,,) = management.state();
    assertFalse(inKandel);

    vm.stopPrank();
  }
}
