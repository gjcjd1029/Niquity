// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

contract ChainLinkOracle {

    uint256 public price;
    uint256[] public liquidationList;
    address public owner;


    // 이더리움 가격을 설정하는 곳
    constructor(address _owner) {
        owner = _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // 체인링크에서 가져오지만 1e18단위로 적어야 함.
    function getEthPrice() external view returns(uint256) {
        return price;
    }

    function setEthPrice(uint256 _price) external {
        _checkOwner();
        price = _price;
    }

    function _checkOwner() internal view {
        require(owner == msg.sender, "Not Owner");
    }
    
    function getLiquidationTrove(uint256 liquidationNum) external returns(uint256[] memory indexList) {
        require(liquidationList.length != 0 || liquidationList.length <= liquidationNum, "Check liquidationList");
        
        uint256[] memory list = new uint256[](liquidationNum);
        for(uint256 i = 0; i < liquidationNum; i++) {
            list[i] = (liquidationList[liquidationList.length - 1]);
            liquidationList.pop();
        }
        return list;
    }

    function setLiquidationTrove(uint256[] memory index) external onlyOwner {
        liquidationList = index;
    }
}