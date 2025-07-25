// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./BorrowerOperation.sol";
import "./StabilityPool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract NUSD is ERC20 {

    BorrowerOperation bp;
    StabilityPool sp;
    address owner;

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    constructor() ERC20("NUSD", "USD") {}

    function setAddress(address _bp, address _sp) external onlyOwner {
        bp = BorrowerOperation(_bp);
        sp = StabilityPool(_sp);
    }
    function mint(address to, uint256 amount) external {
        _checkCaller();
        _mint(to, amount);
    }

    function burn(address to, uint256 amount) external {
        _checkCaller();
        _burn(to, amount);
    }

    function decimals() public override view returns(uint8) {
        return 18;
    }

    function _checkOwner() internal view {
        require(owner == msg.sender, "Not Owner");
    }

    function _checkCaller() internal view {
        require(address(bp) == msg.sender || address(sp) == msg.sender, "Check Caller");
    }
}