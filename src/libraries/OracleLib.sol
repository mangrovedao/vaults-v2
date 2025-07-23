// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../interfaces/IOracle.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {FixedPointMathLib} from "lib/solady/src/utils/FixedPointMathLib.sol";

struct OracleData {
  bool isStatic; // 8 bits
  IOracle oracle; // 160 bits + 8 bits = 168 bits
  Tick staticValue; // 24 bits + 168 bits = 192 bits
  uint16 maxDeviation; // 16 bits + 192 bits = 208 bits
  uint40 proposedAt; // 40 bits + 208 bits = 248 bits
  uint8 timelockMinutes; // 8 bits + 248 bits = 256 bits
}

library OracleLib {
  using OracleLib for OracleData;

  function tick(OracleData memory self) internal view returns (Tick) {
    if (self.isStatic) {
      return self.staticValue;
    }
    return self.oracle.tick();
  }

  function accepts(OracleData memory self, Tick askTick, Tick bidTick) internal view returns (bool) {
    int256 oracleTick = Tick.unwrap(self.tick());
    int256 askTick_ = Tick.unwrap(askTick);
    int256 bidTick_ = Tick.unwrap(bidTick);
    return oracleTick - askTick_ <= int256(uint256(self.maxDeviation))
      && oracleTick - bidTick_ <= int256(uint256(self.maxDeviation));
  }

  function timelocked(OracleData memory self, uint40 start) internal view returns (bool) {
    uint40 date = uint40(block.timestamp);
    if (date < start) return true;
    return date - start < uint40(self.timelockMinutes) * 60;
  }
}
