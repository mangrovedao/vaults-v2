// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../interfaces/IOracle.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

/**
 * @title OracleData
 * @notice Packed struct containing oracle configuration and validation parameters
 * @dev This struct is optimized for gas efficiency using bit packing to fit in exactly 256 bits (1 slot).
 *      The struct supports both static price values and dynamic oracle feeds with timelock mechanisms.
 * @param isStatic Whether to use a static tick value or query an external oracle
 * @param oracle The external oracle contract to query (used when isStatic is false)
 * @param staticValue The static tick value to use (used when isStatic is true)
 * @param maxDeviation Maximum allowed deviation in ticks from the oracle price
 * @param proposedAt Timestamp when the oracle configuration was proposed (used for timelock)
 * @param timelockMinutes Duration in minutes that must pass before accepting oracle changes
 */
struct OracleData {
  bool isStatic; // 8 bits
  IOracle oracle; // 160 bits + 8 bits = 168 bits
  Tick staticValue; // 24 bits + 168 bits = 192 bits
  uint16 maxDeviation; // 16 bits + 192 bits = 208 bits
  uint40 proposedAt; // 40 bits + 208 bits = 248 bits
  uint8 timelockMinutes; // 8 bits + 248 bits = 256 bits
}

/**
 * @title OracleLib
 * @notice Library for managing oracle data and price validation
 * @dev Provides functionality to:
 *      - Retrieve current tick values from static or dynamic sources
 *      - Validate trading positions against oracle-defined price ranges
 *      - Enforce timelock periods for oracle configuration changes
 * @author Mangrove
 */
library OracleLib {
  using OracleLib for OracleData;

  /*//////////////////////////////////////////////////////////////
                         CORE FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Retrieves the current tick value from the oracle configuration
   * @param self The oracle data configuration
   * @return Tick The current tick value
   * @dev If isStatic is true, returns the staticValue. Otherwise, queries the external oracle.
   *      This function may revert if the external oracle is unavailable or returns invalid data.
   */
  function tick(OracleData memory self) internal view returns (Tick) {
    if (self.isStatic) {
      return self.staticValue;
    }
    return self.oracle.tick();
  }

  /**
   * @notice Validates whether a given tick is within acceptable deviation from the oracle's current tick
   * @param self The oracle data struct containing deviation parameters
   * @param _tick The tick to validate against the oracle (ask tick)
   * @return bool True if the tick is within acceptable deviation range, false otherwise
   * @dev Checks if the absolute difference between oracle tick and given tick is within maxDeviation
   * @dev Current implementation only checks one direction (oracleTick - tick_ <= maxDeviation)
   * @dev This means it accepts ticks that are at most maxDeviation below the oracle tick
   */
  function accepts(OracleData memory self, Tick _tick) internal view returns (bool) {
    int256 tick_ = Tick.unwrap(_tick);
    int256 oracleTick = Tick.unwrap(self.tick());

    return oracleTick - tick_ <= int256(uint256(self.maxDeviation));
  }

  /**
   * @notice Validates whether ask and bid ticks are within acceptable deviation from oracle price
   * @param self The oracle data configuration
   * @param askTick The tick value for the ask side (higher price, lower tick)
   * @param bidTick The tick value for the bid side (lower price, higher tick)
   * @return bool True if both ask and bid ticks are within maxDeviation, false otherwise
   * @dev Validates that:
   *      - Oracle tick - ask tick <= maxDeviation (ask not too far below oracle)
   *      - Oracle tick - bid tick <= maxDeviation (bid not too far below oracle)
   *      This ensures trading positions respect oracle-defined price bounds.
   */
  function accepts(OracleData memory self, Tick askTick, Tick bidTick) internal view returns (bool) {
    int256 oracleTick = Tick.unwrap(self.tick());
    int256 askTick_ = Tick.unwrap(askTick);
    int256 bidTick_ = Tick.unwrap(bidTick);

    // Check if both ask and bid are within acceptable deviation from oracle price
    return oracleTick - askTick_ <= int256(uint256(self.maxDeviation))
      && -oracleTick - bidTick_ <= int256(uint256(self.maxDeviation));
  }

  /**
   * @notice Checks whether an oracle configuration change is still under timelock
   * @param self The oracle data configuration
   * @param start The timestamp when the oracle change was proposed
   * @return bool True if the change is still timelocked (cannot be accepted), false if timelock has expired
   * @dev Returns true if:
   *      - Current timestamp is before the start timestamp (invalid state)
   *      - Time elapsed since start is less than timelockMinutes * 60 seconds
   *      This prevents immediate oracle changes and provides time for guardians to review proposals.
   */
  function timelocked(OracleData memory self, uint40 start) internal view returns (bool) {
    uint40 date = uint40(block.timestamp);
    // Handle edge case where current time is before start time
    if (date < start) return true;
    // Check if timelock period has elapsed
    return date - start < uint40(self.timelockMinutes) * 60;
  }

  /**
   * @notice Validates whether the oracle configuration can provide a valid tick value
   * @param self The oracle data configuration
   * @return bool True if oracle can provide a valid tick within acceptable range, false otherwise
   * @dev For static oracles, validates the staticValue is within valid tick range.
   *      For dynamic oracles, attempts to query the external oracle with try-catch:
   *      - If oracle call succeeds, validates the returned tick is within valid range
   *      - If oracle call fails (reverts), returns false
   *      This function is useful for validating oracle configurations before deployment.
   */
  function isValid(OracleData memory self) internal view returns (bool) {
    if (self.isStatic) {
      // For static oracles, just check if the static value is in valid range
      return self.staticValue.inRange();
    }

    // Check if oracle code size is greater than 0
    if (address(self.oracle).code.length == 0) {
      return false;
    }

    // For dynamic oracles, try to query the oracle and validate the result
    try self.oracle.tick() returns (Tick oracleTick) {
      return oracleTick.inRange();
    } catch {
      // Oracle call failed, return false
      return false;
    }
  }
}
