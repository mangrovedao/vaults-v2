// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OracleLib, OracleData} from "../../src/libraries/OracleLib.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";
import {Tick, TickLib} from "@mgv/lib/core/TickLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/**
 * @title MockOracle
 * @notice Mock oracle contract for testing purposes
 */
contract MockOracle is IOracle {
  Tick private _tick;
  bool private _shouldRevert;

  function setTick(Tick tick_) external {
    _tick = tick_;
  }

  function setShouldRevert(bool shouldRevert) external {
    _shouldRevert = shouldRevert;
  }

  function tick() external view override returns (Tick) {
    if (_shouldRevert) {
      revert("MockOracle: reverted");
    }
    return _tick;
  }
}

/**
 * @title OracleLibTestContract
 * @notice Test contract that uses OracleLib to expose internal functions for testing
 */
contract OracleLibTestContract {
  using OracleLib for OracleData;

  function tick(OracleData memory self) external view returns (Tick) {
    return self.tick();
  }

  function withinDeviation(OracleData memory self, Tick _tick) external view returns (bool) {
    return self.withinDeviation(_tick);
  }

  function accepts(OracleData memory self, Tick _tick) external view returns (bool) {
    return self.accepts(_tick);
  }

  function acceptsTwo(OracleData memory self, Tick askTick, Tick bidTick) external view returns (bool) {
    return self.accepts(askTick, bidTick);
  }

  function timelocked(OracleData memory self, uint40 start) external view returns (bool) {
    return self.timelocked(start);
  }

  function isValid(OracleData memory self) external view returns (bool) {
    return self.isValid();
  }

  function acceptsTrade(OracleData memory self, bool isSell, uint256 received, uint256 sent)
    external
    view
    returns (bool)
  {
    return OracleLib.acceptsTrade(self, isSell, received, sent);
  }

  function acceptsInitialMint(OracleData memory self, uint256 baseAmount, uint256 quoteAmount)
    external
    view
    returns (bool)
  {
    return OracleLib.acceptsInitialMint(self, baseAmount, quoteAmount);
  }
}

/**
 * @title OracleLibTest
 * @notice Comprehensive test suite for OracleLib library
 */
contract OracleLibTest is Test {
  using TickLib for Tick;
  using FixedPointMathLib for uint256;

  OracleLibTestContract public testContract;
  MockOracle public mockOracle;

  // Test constants
  Tick constant ZERO_TICK = Tick.wrap(0);
  Tick constant POSITIVE_TICK = Tick.wrap(1000);
  Tick constant NEGATIVE_TICK = Tick.wrap(-1000);
  Tick constant MAX_TICK = Tick.wrap(887272);
  Tick constant MIN_TICK = Tick.wrap(-887272);

  function setUp() public {
    testContract = new OracleLibTestContract();
    mockOracle = new MockOracle();
  }

  /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  function createStaticOracle(Tick staticTick, uint16 maxDev) internal pure returns (OracleData memory) {
    return OracleData({
      isStatic: true,
      oracle: IOracle(address(0)),
      staticValue: int24(Tick.unwrap(staticTick)),
      maxDeviation: maxDev,
      proposedAt: 0,
      timelockMinutes: 60
    });
  }

  function createDynamicOracle(IOracle oracle_, uint16 maxDev) internal pure returns (OracleData memory) {
    return OracleData({
      isStatic: false,
      oracle: oracle_,
      staticValue: int24(0),
      maxDeviation: maxDev,
      proposedAt: 0,
      timelockMinutes: 60
    });
  }

  /*//////////////////////////////////////////////////////////////
                            TICK TESTS
  //////////////////////////////////////////////////////////////*/

  function test_tick_static() public view {
    OracleData memory oracle = createStaticOracle(POSITIVE_TICK, 100);
    Tick result = testContract.tick(oracle);
    assertEq(Tick.unwrap(result), Tick.unwrap(POSITIVE_TICK));
  }

  function test_tick_dynamic() public {
    mockOracle.setTick(NEGATIVE_TICK);
    OracleData memory oracle = createDynamicOracle(mockOracle, 100);

    Tick result = testContract.tick(oracle);
    assertEq(Tick.unwrap(result), Tick.unwrap(NEGATIVE_TICK));
  }

  function testFuzz_tick_static(int24 tickValue) public view {
    vm.assume(tickValue >= -887272 && tickValue <= 887272); // Valid tick range

    Tick inputTick = Tick.wrap(tickValue);
    OracleData memory oracle = createStaticOracle(inputTick, 100);

    Tick result = testContract.tick(oracle);
    assertEq(Tick.unwrap(result), Tick.unwrap(inputTick));
  }

  function testFuzz_tick_dynamic(int24 tickValue) public {
    vm.assume(tickValue >= -887272 && tickValue <= 887272);

    Tick inputTick = Tick.wrap(tickValue);
    mockOracle.setTick(inputTick);
    OracleData memory oracle = createDynamicOracle(mockOracle, 100);

    Tick result = testContract.tick(oracle);
    assertEq(Tick.unwrap(result), Tick.unwrap(inputTick));
  }

  function test_tick_dynamicReverts() public {
    mockOracle.setShouldRevert(true);
    OracleData memory oracle = createDynamicOracle(mockOracle, 100);

    vm.expectRevert("MockOracle: reverted");
    testContract.tick(oracle);
  }

  /*//////////////////////////////////////////////////////////////
                       WITHIN DEVIATION TESTS
  //////////////////////////////////////////////////////////////*/

  function test_withinDeviation_exactMatch() public view {
    OracleData memory oracle = createStaticOracle(ZERO_TICK, 100);
    assertTrue(testContract.withinDeviation(oracle, ZERO_TICK));
  }

  function test_withinDeviation_withinRange() public view {
    OracleData memory oracle = createStaticOracle(ZERO_TICK, 100);
    assertTrue(testContract.withinDeviation(oracle, Tick.wrap(50)));
    assertTrue(testContract.withinDeviation(oracle, Tick.wrap(-50)));
    assertTrue(testContract.withinDeviation(oracle, Tick.wrap(100)));
    assertTrue(testContract.withinDeviation(oracle, Tick.wrap(-100)));
  }

  function test_withinDeviation_outsideRange() public view {
    OracleData memory oracle = createStaticOracle(ZERO_TICK, 100);
    assertFalse(testContract.withinDeviation(oracle, Tick.wrap(101)));
    assertFalse(testContract.withinDeviation(oracle, Tick.wrap(-101)));
  }

  function testFuzz_withinDeviation(int24 oracleTick, int24 testTick, uint16 maxDev) public view {
    vm.assume(oracleTick >= -887272 && oracleTick <= 887272);
    vm.assume(testTick >= -887272 && testTick <= 887272);
    vm.assume(maxDev <= 50000); // Reasonable max deviation

    OracleData memory oracle = createStaticOracle(Tick.wrap(oracleTick), maxDev);
    bool result = testContract.withinDeviation(oracle, Tick.wrap(testTick));

    uint256 expectedDistance = FixedPointMathLib.dist(int256(oracleTick), int256(testTick));
    bool expectedResult = expectedDistance <= uint256(maxDev);

    assertEq(result, expectedResult);
  }

  /*//////////////////////////////////////////////////////////////
                          ACCEPTS TESTS
  //////////////////////////////////////////////////////////////*/

  function test_accepts_singleTick_exactMatch() public view {
    OracleData memory oracle = createStaticOracle(ZERO_TICK, 100);
    assertTrue(testContract.accepts(oracle, ZERO_TICK));
  }

  function test_accepts_singleTick_withinRange() public view {
    OracleData memory oracle = createStaticOracle(Tick.wrap(1000), 100);
    assertTrue(testContract.accepts(oracle, Tick.wrap(900))); // oracle - tick = 100
    assertTrue(testContract.accepts(oracle, Tick.wrap(1000))); // oracle - tick = 0
  }

  function test_accepts_singleTick_outsideRange() public view {
    OracleData memory oracle = createStaticOracle(Tick.wrap(1000), 100);
    assertFalse(testContract.accepts(oracle, Tick.wrap(899))); // oracle - tick = 101 (outside since worst price)
    assertTrue(testContract.accepts(oracle, Tick.wrap(1001))); // oracle - tick = -1 (within since better price)
  }

  function testFuzz_accepts_singleTick(int24 oracleTick, int24 testTick, uint16 maxDev) public view {
    vm.assume(oracleTick >= -887272 && oracleTick <= 887272);
    vm.assume(testTick >= -887272 && testTick <= 887272);
    vm.assume(maxDev <= 50000);

    OracleData memory oracle = createStaticOracle(Tick.wrap(oracleTick), maxDev);
    bool result = testContract.accepts(oracle, Tick.wrap(testTick));

    bool expectedResult = (int256(oracleTick) - int256(testTick)) <= int256(uint256(maxDev));
    assertEq(result, expectedResult);
  }

  function test_accepts_doubleTick_withinRange() public view {
    OracleData memory oracle = createStaticOracle(Tick.wrap(1000), 100);
    assertTrue(testContract.acceptsTwo(oracle, Tick.wrap(900), Tick.wrap(-900))); // Both within range
  }

  function test_accepts_doubleTick_askOutsideRange() public view {
    OracleData memory oracle = createStaticOracle(Tick.wrap(1000), 100);
    assertFalse(testContract.acceptsTwo(oracle, Tick.wrap(899), Tick.wrap(-900))); // Ask outside range
  }

  function test_accepts_doubleTick_bidOutsideRange() public view {
    OracleData memory oracle = createStaticOracle(Tick.wrap(1000), 100);
    assertFalse(testContract.acceptsTwo(oracle, Tick.wrap(900), Tick.wrap(-1101))); // Bid outside range (-oracle - bid = -1000 - (-1101) = 101)
  }

  function testFuzz_accepts_doubleTick(int24 oracleTick, int24 askTick, int24 bidTick, uint16 maxDev) public view {
    vm.assume(oracleTick >= -887272 && oracleTick <= 887272);
    vm.assume(askTick >= -887272 && askTick <= 887272);
    vm.assume(bidTick >= -887272 && bidTick <= 887272);
    vm.assume(maxDev <= 50000);

    OracleData memory oracle = createStaticOracle(Tick.wrap(oracleTick), maxDev);
    bool result = testContract.acceptsTwo(oracle, Tick.wrap(askTick), Tick.wrap(bidTick));

    bool askAccepted = (int256(oracleTick) - int256(askTick)) <= int256(uint256(maxDev));
    bool bidAccepted = (-int256(oracleTick) - int256(bidTick)) <= int256(uint256(maxDev));
    bool expectedResult = askAccepted && bidAccepted;

    assertEq(result, expectedResult);
  }

  /*//////////////////////////////////////////////////////////////
                         TIMELOCKED TESTS
  //////////////////////////////////////////////////////////////*/

  function test_timelocked_notExpired() public {
    OracleData memory oracle = createStaticOracle(ZERO_TICK, 100);
    oracle.timelockMinutes = 60;

    uint40 startTime = uint40(block.timestamp);
    assertTrue(testContract.timelocked(oracle, startTime)); // Should be locked immediately

    vm.warp(block.timestamp + 30 * 60); // 30 minutes later
    assertTrue(testContract.timelocked(oracle, startTime)); // Still locked
  }

  function test_timelocked_expired() public {
    OracleData memory oracle = createStaticOracle(ZERO_TICK, 100);
    oracle.timelockMinutes = 60;

    uint40 startTime = uint40(block.timestamp);
    vm.warp(block.timestamp + 61 * 60); // 61 minutes later
    assertFalse(testContract.timelocked(oracle, startTime)); // Should be unlocked
  }

  function test_timelocked_exactExpiry() public {
    OracleData memory oracle = createStaticOracle(ZERO_TICK, 100);
    oracle.timelockMinutes = 60;

    uint40 startTime = uint40(block.timestamp);
    vm.warp(block.timestamp + 60 * 60); // Exactly 60 minutes later
    assertFalse(testContract.timelocked(oracle, startTime)); // Should be unlocked
  }

  function test_timelocked_futureStart() public view {
    OracleData memory oracle = createStaticOracle(ZERO_TICK, 100);
    oracle.timelockMinutes = 60;

    uint40 futureStart = uint40(block.timestamp + 1000);
    assertTrue(testContract.timelocked(oracle, futureStart)); // Should be locked for future starts
  }

  function testFuzz_timelocked(uint40 startTime, uint8 timelockMinutes, uint40 currentOffset) public {
    vm.assume(startTime > 0 && startTime < type(uint40).max - 86400); // Reasonable start time
    vm.assume(timelockMinutes > 0 && timelockMinutes <= 1440); // 0-24 hours
    vm.assume(currentOffset < 86400); // Max 24 hours offset

    OracleData memory oracle = createStaticOracle(ZERO_TICK, 100);
    oracle.timelockMinutes = timelockMinutes;

    vm.warp(startTime + currentOffset);
    bool result = testContract.timelocked(oracle, startTime);

    uint40 currentTime = uint40(block.timestamp);
    bool expectedResult;
    if (currentTime < startTime) {
      expectedResult = true; // Future start time
    } else {
      uint40 elapsed = currentTime - startTime;
      expectedResult = elapsed < uint40(timelockMinutes) * 60;
    }

    assertEq(result, expectedResult);
  }

  /*//////////////////////////////////////////////////////////////
                          IS VALID TESTS
  //////////////////////////////////////////////////////////////*/

  function test_isValid_static_validTick() public view {
    OracleData memory oracle = createStaticOracle(ZERO_TICK, 100);
    assertTrue(testContract.isValid(oracle));

    oracle.staticValue = int24(Tick.unwrap(MAX_TICK));
    assertTrue(testContract.isValid(oracle));

    oracle.staticValue = int24(Tick.unwrap(MIN_TICK));
    assertTrue(testContract.isValid(oracle));
  }

  function test_isValid_static_invalidTick() public view {
    OracleData memory oracle = createStaticOracle(Tick.wrap(887273), 100); // Out of range
    assertFalse(testContract.isValid(oracle));

    oracle.staticValue = int24(-887273); // Out of range
    assertFalse(testContract.isValid(oracle));
  }

  function test_isValid_dynamic_validOracle() public {
    mockOracle.setTick(ZERO_TICK);
    OracleData memory oracle = createDynamicOracle(mockOracle, 100);
    assertTrue(testContract.isValid(oracle));
  }

  function test_isValid_dynamic_invalidOracle() public {
    mockOracle.setShouldRevert(true);
    OracleData memory oracle = createDynamicOracle(mockOracle, 100);
    assertFalse(testContract.isValid(oracle));
  }

  function test_isValid_dynamic_noCode() public view {
    OracleData memory oracle = createDynamicOracle(IOracle(address(0x1234)), 100);
    assertFalse(testContract.isValid(oracle)); // No code at address
  }

  function testFuzz_isValid_static(int24 tickValue) public view {
    OracleData memory oracle = createStaticOracle(Tick.wrap(tickValue), 100);
    bool result = testContract.isValid(oracle);

    bool expectedResult = Tick.wrap(tickValue).inRange();
    assertEq(result, expectedResult);
  }

  /*//////////////////////////////////////////////////////////////
                      ACCEPTS TRADE TESTS
  //////////////////////////////////////////////////////////////*/

  function test_acceptsTrade_sell() public view {
    OracleData memory oracle = createStaticOracle(Tick.wrap(0), 1000);

    // Test a sell trade: selling 1 ether for 1 USDC (both 18 decimals)
    uint256 sent = 1 ether;
    uint256 received = 1 ether;
    assertTrue(testContract.acceptsTrade(oracle, true, received, sent));
  }

  function test_acceptsTrade_buy() public view {
    OracleData memory oracle = createStaticOracle(Tick.wrap(0), 1000);

    // Test a buy trade: buying 1 ether with 1 USDC (both 18 decimals)
    uint256 sent = 1 ether;
    uint256 received = 1 ether;
    assertTrue(testContract.acceptsTrade(oracle, false, received, sent));
  }

  /*//////////////////////////////////////////////////////////////
                    ACCEPTS INITIAL MINT TESTS
  //////////////////////////////////////////////////////////////*/

  function test_acceptsInitialMint_validRatio() public view {
    OracleData memory oracle = createStaticOracle(Tick.wrap(0), 1000);

    // Test initial mint with 1:1 ratio
    uint256 baseAmount = 1 ether;
    uint256 quoteAmount = 1 ether;
    assertTrue(testContract.acceptsInitialMint(oracle, baseAmount, quoteAmount));
  }

  function test_acceptsInitialMint_extremeRatio() public view {
    OracleData memory oracle = createStaticOracle(Tick.wrap(0), 100);

    // Test with extreme ratio that might be outside deviation
    uint256 baseAmount = 1;
    uint256 quoteAmount = 1e30;

    // This should likely fail due to extreme ratio
    bool result = testContract.acceptsInitialMint(oracle, baseAmount, quoteAmount);
    assertFalse(result);
  }

  /*//////////////////////////////////////////////////////////////
                        EDGE CASE TESTS
  //////////////////////////////////////////////////////////////*/

  function test_edgeCase_zeroDeviation() public view {
    OracleData memory oracle = createStaticOracle(ZERO_TICK, 0);

    assertTrue(testContract.accepts(oracle, ZERO_TICK));
    assertTrue(testContract.accepts(oracle, Tick.wrap(1))); // more expensive ask so should work
    assertFalse(testContract.accepts(oracle, Tick.wrap(-1))); // cheaper ask so should not work
  }

  function test_edgeCase_zeroTimelock() public view {
    OracleData memory oracle = createStaticOracle(ZERO_TICK, 100);
    oracle.timelockMinutes = 0;

    uint40 startTime = uint40(block.timestamp);
    assertFalse(testContract.timelocked(oracle, startTime)); // Should be unlocked immediately
  }

  /*//////////////////////////////////////////////////////////////
                      INTEGRATION TESTS
  //////////////////////////////////////////////////////////////*/

  function test_integration_completeOracle() public {
    // Test a complete oracle workflow
    mockOracle.setTick(Tick.wrap(500)); // price = 1.05
    OracleData memory oracle = createDynamicOracle(mockOracle, 200); // maxDev = 2%
    oracle.timelockMinutes = 30;
    oracle.proposedAt = uint40(block.timestamp);

    // Oracle should be valid
    assertTrue(testContract.isValid(oracle));

    // Should be timelocked initially
    assertTrue(testContract.timelocked(oracle, oracle.proposedAt));

    // Should accept ticks within deviation
    assertTrue(testContract.accepts(oracle, Tick.wrap(400))); // 500 - 400 = 100 <= 200
    assertFalse(testContract.accepts(oracle, Tick.wrap(250))); // 500 - 250 = 250 > 200

    // Should work with trades (sell)
    assertTrue(testContract.acceptsTrade(oracle, true, 1.05 ether, 1 ether)); // price of 1.05 is within 2% deviation
    assertFalse(testContract.acceptsTrade(oracle, true, 1 ether, 1 ether)); // price of 1 is not within 2% deviation
    assertTrue(testContract.acceptsTrade(oracle, true, 1.04 ether, 1 ether)); // price of 1.04 is within 2% deviation
    assertTrue(testContract.acceptsTrade(oracle, true, 10 ether, 1 ether)); // price of 10 is not within 2% deviation but is a better price so should be working

    // Should work with trades (buy)
    assertTrue(testContract.acceptsTrade(oracle, false, 1 ether, 1.05 ether)); // price of 1.05 is within 2% deviation
    assertFalse(testContract.acceptsTrade(oracle, false, 1 ether, 1.1 ether)); // price of 1.1 is not within 2% deviation
    assertTrue(testContract.acceptsTrade(oracle, false, 1 ether, 1.06 ether)); // price of 1.06 is within 2% deviation
    assertTrue(testContract.acceptsTrade(oracle, false, 1 ether, 0.1 ether)); // price of 0.1 is not within 2% deviation but is a better price so should be working

    // After timelock expires
    vm.warp(block.timestamp + 31 * 60);
    assertFalse(testContract.timelocked(oracle, oracle.proposedAt));
  }

  function test_integration_staticVsDynamic() public {
    Tick commonTick = Tick.wrap(1000);

    // Create static and dynamic oracles with same tick value
    OracleData memory staticOracle = createStaticOracle(commonTick, 100);

    mockOracle.setTick(commonTick);
    OracleData memory dynamicOracle = createDynamicOracle(mockOracle, 100);

    // Both should return same tick
    assertEq(Tick.unwrap(testContract.tick(staticOracle)), Tick.unwrap(testContract.tick(dynamicOracle)));

    // Both should accept same test tick
    Tick testTick = Tick.wrap(950);
    assertEq(testContract.accepts(staticOracle, testTick), testContract.accepts(dynamicOracle, testTick));

    // Both should have same validation results
    assertEq(testContract.isValid(staticOracle), testContract.isValid(dynamicOracle));
  }
}
