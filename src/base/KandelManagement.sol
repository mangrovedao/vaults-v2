// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AbstractKandelSeeder} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/AbstractKandelSeeder.sol";
import {GeometricKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/GeometricKandel.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {DirectWithBidsAndAsksDistribution} from
  "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/DirectWithBidsAndAsksDistribution.sol";
import {Tick} from "@mgv/lib/core/TickLib.sol";
import {MAX_TICK} from "@mgv/lib/core/Constants.sol";
import {CoreKandel} from "@mgv-strats/src/strategies/offer_maker/market_making/kandel/abstract/CoreKandel.sol";

abstract contract KandelManagement {
  error NotManager();
  error InvalidDistribution();

  event SetManager(address indexed manager);

  GeometricKandel public immutable kandel;

  address internal immutable BASE;
  address internal immutable QUOTE;
  uint256 internal immutable TICK_SPACING;

  address public manager;

  modifier onlyManager() {
    if (msg.sender != manager) revert NotManager();
    _;
  }

  constructor(AbstractKandelSeeder seeder, address base, address quote, uint256 tickSpacing, address _manager) {
    BASE = base;
    QUOTE = quote;
    TICK_SPACING = tickSpacing;
    manager = _manager;
    kandel = seeder.sow(OLKey(base, quote, tickSpacing), false);
  }

  function setManager(address _manager) external onlyManager {
    manager = _manager;
    emit SetManager(_manager);
  }

  function _checkTick(Tick tick, bool isBid) internal view virtual returns (bool);

  function _minTick(DirectWithBidsAndAsksDistribution.DistributionOffer[] memory offers) internal view returns (Tick) {
    int256 minTick = MAX_TICK;
    for (uint256 i = 0; i < offers.length; i++) {
      if (offers[i].gives == 0) continue;
      if (Tick.unwrap(offers[i].tick) < minTick) {
        minTick = Tick.unwrap(offers[i].tick);
      }
    }
    return Tick.wrap(minTick);
  }

  function _checkDistribution(DirectWithBidsAndAsksDistribution.Distribution memory distribution)
    internal
    view
    returns (bool)
  {
    // get ask with lowest tick => check it
    // bid with lowest tick => check its opposite
    return _checkTick(_minTick(distribution.asks), false) && _checkTick(_minTick(distribution.bids), true);
  }

  function _params() internal view returns (CoreKandel.Params memory params) {
    (uint32 gasprice, uint24 gasreq, uint32 stepSize, uint32 pricePoints) = kandel.params();
    params.gasprice = gasprice;
    params.gasreq = gasreq;
    params.stepSize = stepSize;
    params.pricePoints = pricePoints;
  }

  function populateFromOffset(
    uint256 from,
    uint256 to,
    Tick baseQuoteTickIndex0,
    uint256 _baseQuoteTickOffset,
    uint256 firstAskIndex,
    uint256 bidGives,
    uint256 askGives,
    CoreKandel.Params calldata parameters
  ) external payable onlyManager {
    DirectWithBidsAndAsksDistribution.Distribution memory distribution = kandel.createDistribution(
      from,
      to,
      baseQuoteTickIndex0,
      _baseQuoteTickOffset,
      firstAskIndex,
      bidGives,
      askGives,
      parameters.pricePoints,
      parameters.stepSize
    );
    if (!_checkDistribution(distribution)) revert InvalidDistribution();
    kandel.populate{value: msg.value}(distribution, parameters, 0, 0);
  }

  function populateChunkFromOffset(
    uint256 from,
    uint256 to,
    Tick baseQuoteTickIndex0,
    uint256 firstAskIndex,
    uint256 bidGives,
    uint256 askGives
  ) external onlyManager {
    CoreKandel.Params memory parameters = _params();
    uint256 baseQuoteTickOffset = kandel.baseQuoteTickOffset();
    DirectWithBidsAndAsksDistribution.Distribution memory distribution = kandel.createDistribution(
      from,
      to,
      baseQuoteTickIndex0,
      baseQuoteTickOffset,
      firstAskIndex,
      bidGives,
      askGives,
      parameters.pricePoints,
      parameters.stepSize
    );
    if (!_checkDistribution(distribution)) revert InvalidDistribution();
    kandel.populateChunk(distribution);
  }
}
