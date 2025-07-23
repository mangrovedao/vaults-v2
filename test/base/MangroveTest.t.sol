// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IMangrove} from "@mgv/src/IMangrove.sol";
import {Mangrove} from "@mgv/src/core/Mangrove.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {OLKey} from "@mgv/src/core/MgvLib.sol";
import {MgvReader, Market} from "@mgv/src/periphery/MgvReader.sol";

contract MockERC20 is ERC20 {
  string private _name;
  string private _symbol;
  uint8 private _decimals;

  constructor(string memory name_, string memory symbol_, uint8 decimals_) {
    _name = name_;
    _symbol = symbol_;
    _decimals = decimals_;
  }

  /// @dev Returns the name of the token.
  function name() public view virtual override returns (string memory) {
    return _name;
  }

  /// @dev Returns the symbol of the token.
  function symbol() public view virtual override returns (string memory) {
    return _symbol;
  }

  /// @dev Returns the number of decimals used to get its user representation.
  function decimals() public view virtual override returns (uint8) {
    return _decimals;
  }

  function mint(address to, uint256 amount) public {
    _mint(to, amount);
  }
}

contract MangroveTest is Test {
  IMangrove public mangrove;
  MgvReader public reader;
  address public governance;
  ERC20 public WETH;
  ERC20 public USDC;

  function setUp() public virtual {
    governance = makeAddr("governance");
    mangrove = IMangrove(payable(address(new Mangrove(governance, 1, 2_000_000))));
    WETH = new MockERC20("Wrapped Ether", "WETH", 18);
    USDC = new MockERC20("USD Coin", "USDC", 6);
    reader = new MgvReader(address(mangrove));
    vm.startPrank(governance);
    // 0.01 ETH min ask = 85899345920000000000
    mangrove.activate(OLKey(address(WETH), address(USDC), 1), 0, 85899345920000000000, 250_000);
    // 1 USDC min bid = 8589934592
    mangrove.activate(OLKey(address(USDC), address(WETH), 1), 0, 8589934592, 250_000);
    vm.stopPrank();
    reader.updateMarket(Market(address(WETH), address(USDC), 1));
  }
}
