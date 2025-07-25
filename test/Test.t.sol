// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import "../src/BorrowerOperation.sol";

contract CounterTest is Test {

    BorrowerOperation op;
    address public user;
    function setUp() public {
        user = address(0x123456);
        op = new BorrowerOperation(user);
    }

    function test_Increment() public {
        vm.startPrank(user);
        vm.deal(user, 10 ether);
    }
}
