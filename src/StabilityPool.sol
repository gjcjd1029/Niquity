// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./BorrowerOperation.sol";
import "./ChainLinkOracle.sol";
import "./NUSD.sol";
import {console} from "forge-std/Test.sol";

contract StabilityPool {
    
    struct stakedUserInfo {
        uint256 deposits;
        uint256 userLastProfitPerUnit;
        uint256 index;
    }
    BorrowerOperation public borrowerOperation;
    ChainLinkOracle public oracle;
    NUSD public nusd;

    uint256 constant public WAD = 1e18;
    address public owner;
    mapping(address => stakedUserInfo) public users;
    mapping(uint256 => address) public indexToUser;
    uint256 public totalDeposits;
    uint256 public profitPerUnit;
    uint256 public indexCount;

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    constructor(address _owner) {
        owner = _owner;
    }

    function setAddress(address _oracle, address _nusd, address _borrowerOperation) external onlyOwner {
        oracle = ChainLinkOracle(_oracle);
        nusd = NUSD(_nusd);
        borrowerOperation = BorrowerOperation(_borrowerOperation);
    }

    function _calculatePendingProfit(address user) internal view returns (uint256) {
        return (users[user].deposits * (profitPerUnit - users[user].userLastProfitPerUnit)) / WAD;
    }

    function deposit(uint256 amount) public {
        require(amount > 0, "Amount must be greater than zero");

        _claimPendingProfit(msg.sender);

        if(users[msg.sender].deposits == 0) {
            indexToUser[indexCount] = msg.sender;
            users[msg.sender].index = indexCount;
            indexCount++;
        }
        nusd.burn(msg.sender, amount);
        users[msg.sender].deposits += amount;
        totalDeposits += amount;
    }

    function withdraw(address user, uint256 nusdAmount) public {
        require(users[user].deposits >= nusdAmount, "Insufficient deposit");
        require(user == msg.sender);

        _claimPendingProfit(user);

        users[user].deposits -= nusdAmount;
        totalDeposits -= nusdAmount;
        nusd.mint(user, nusdAmount);

        if(users[user].deposits == 0) {
            users[indexToUser[indexCount - 1]].index = users[user].index;
            indexToUser[users[user].index] = indexToUser[indexCount - 1];
            indexToUser[indexCount - 1] = address(0);
            indexCount--;
            users[msg.sender].userLastProfitPerUnit = 0;
        }
    }

    function claimPendingProfit(address user) external {
        _claimPendingProfit(user);
    }

    function _claimPendingProfit(address user) internal returns (uint256) {
        uint256 pendingNUSDProfit = _calculatePendingProfit(user);
        if (pendingNUSDProfit > 0) {
            nusd.mint(user, pendingNUSDProfit);
        }
        users[msg.sender].userLastProfitPerUnit = profitPerUnit;
        return pendingNUSDProfit;
    }

    // 실제 Liquity에서는 청산 트랜잭션의 일부로 이 로직이 작동, 청산 금액, nicr
    function distributeProfit(uint256 profitAmount) public payable {
        require(totalDeposits > 0, "No deposits to distribute profit to");
        profitPerUnit += (profitAmount) / totalDeposits;
    }

    function liquidation(uint256 nusdAmount, uint256 nicr) public payable {
        require(msg.sender == address(borrowerOperation), "Must call by borrowerOperation");
        
        for(uint256 i = 0; i < indexCount; i++) {
            address target = indexToUser[i];
            uint256 balance = users[target].deposits * nusdAmount / totalDeposits ;

            if(users[target].deposits < balance * WAD * 100 / nicr) {
                continue;
            } else {
                _claimPendingProfit(target);
                users[target].deposits -= balance * WAD * 100 / nicr;
                totalDeposits -= balance * WAD * 100 / nicr;
                payable(target).call{value: viewNusdToEth(balance)}("");
            }
        }
    }


    function getUserInfo(address user) public view returns (uint256 currentDeposit, uint256 pendingNUSDProfit) {
        currentDeposit = users[user].deposits;
        pendingNUSDProfit = _calculatePendingProfit(user);
    }

    function _checkOwner() internal view {
        require(owner == msg.sender, "Not owner");
    }

        // 이더 개수를 입력하면 달러로 얼마인지를 리턴, 1 달러 == 1e18
    function viewEthToNusd(uint256 ethAmount) public view returns(uint256) {
        return oracle.getEthPrice() * ethAmount / WAD;
    }

    // nusd 양을 입력하면 이더 몇개인지 나옴, 1 개 == 1e18
    function viewNusdToEth(uint256 nusdAmount) public view returns(uint256) {
        return nusdAmount * WAD / oracle.getEthPrice();
    }
}