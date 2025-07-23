// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {OracleData, OracleLib} from "../libraries/OracleLib.sol";

contract OracleRange is Ownable {
  using OracleLib for OracleData;

  error NotGuardian();
  error OracleTimelocked();

  event ProposedOracle(bytes32 indexed key, OracleData oracle);
  event AcceptedOracle(bytes32 indexed key);
  event RejectedOracle(bytes32 indexed key);

  OracleData public oracle;
  OracleData public proposedOracle;

  address public guardian;

  modifier onlyGuardian() {
    if (msg.sender != guardian) revert NotGuardian();
    _;
  }

  constructor(OracleData memory _oracle, address _owner, address _guardian) {
    _oracle.proposedAt = uint40(block.timestamp);
    oracle = _oracle;
    _initializeOwner(_owner);
    guardian = _guardian;
  }

  function _guardInitializeOwner() internal pure override returns (bool) {
    return true;
  }

  function proposeOracle(OracleData memory _oracle) external onlyOwner {
    _oracle.proposedAt = uint40(block.timestamp);
    proposedOracle = _oracle;
    emit ProposedOracle(keccak256(abi.encode(_oracle)), _oracle);
  }

  function acceptOracle() external onlyOwner {
    OracleData memory _oracle = proposedOracle;
    if (oracle.timelocked(_oracle.proposedAt)) revert OracleTimelocked();
    oracle = _oracle;
    emit AcceptedOracle(keccak256(abi.encode(_oracle)));
  }

  function rejectOracle() external onlyGuardian {
    OracleData memory _oracle = proposedOracle;
    delete proposedOracle;
    emit RejectedOracle(keccak256(abi.encode(_oracle)));
  }
}
