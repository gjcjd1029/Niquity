// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./StabilityPool.sol";
import "./ChainLinkOracle.sol";
import "./NUSD.sol";
import {console} from "forge-std/Test.sol";

// 트로브 개설
// 이더를 받고 lusd를 주고 icr, mcr, tcr, recovery mode
contract BorrowerOperation {

    struct UserDetail {
        address user;
        uint256 col;    // msg.value 그대로 들어감 1e18
        uint256 debt;   // 1달러 1e8
        uint256 index;
        uint256 gasCompensation;
    }

    mapping(address user => UserDetail info) public userInfo;
    mapping(uint256 index => address user) public indexToUser;
    StabilityPool public stabilityPool;
    ChainLinkOracle public oracle;
    NUSD public nusd;
    
    uint256 constant public WAD = 1e18;
    uint256 constant public CCR = 150 * WAD;
    uint256 constant public MCR = 110 * WAD;
    uint256 constant public liquidationBonus = 200 * WAD;
    uint256 public indexCount;
    uint256 public totalCol;
    uint256 public totalDebt;
    uint256 public feeRate;

    address public owner;

    event swapIndex(address user, uint256 prevIndex, uint256 nextIndex);

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    constructor(address _owner) {
        owner = _owner;
        feeRate = WAD * 5 / 1000;
    }

    function setAddress(address _oracle, address _nusd, address _stabilitypool) external onlyOwner {
        oracle = ChainLinkOracle(_oracle);
        nusd = NUSD(_nusd);
        stabilityPool = StabilityPool(_stabilitypool);
    }
    
    function openTrove(address user, uint256 lendAmount) external payable {
        _checkUser(user);
        _checkZeroAddress(user);

        uint256 price = viewEthToNusd(msg.value);
        uint256 debt = lendAmount;
        uint256 reward;
        uint256 fee = lendAmount * feeRate / WAD;
        uint256 liquidationFee = lendAmount * feeRate / WAD;
        _checkMinimumDebt(debt);

        if(_checkRecoveryMode()) {
            _checkCCR(price, debt);
        } else {
            _checkMCR(price, debt);
            _checkUpdateNICR(price, debt, true, true);
        }
        
        userInfo[user] = UserDetail({
            user: user,
            col: msg.value,
            debt: debt,
            index: indexCount,
            gasCompensation: liquidationBonus + liquidationFee
        });
        
        indexToUser[indexCount] = user;
        indexCount++;
        totalCol += msg.value;
        totalDebt += debt;

        if(stabilityPool.totalDeposits() == 0) {
            fee = 0;
        } else {
            stabilityPool.distributeProfit(fee);
        }
        nusd.mint(user, lendAmount - fee);
    }

    // 추가 담보
    function depositCollateral(address user, uint256 colAmount) external payable {
        _checkUser(user);

        userInfo[user].col += colAmount;

        totalCol += colAmount;
    }

    // 담보 제거
    function withdrawCollateral(address user, uint256 colAmount) external {
        _checkUser(user);

        userInfo[user].col -= colAmount;

        _checkMCR(userInfo[user].col, userInfo[user].debt);
        _checkUpdateNICR(colAmount, 0, false, true);

        totalCol -= colAmount;

        payable(user).call{value: colAmount}("");
    }

    // 추가 부채
    function addDebt(address user, uint256 lendAmount) external {
        _checkUser(user);
        
        uint256 fee = lendAmount * feeRate / WAD;
        uint256 liquidationFee = lendAmount * feeRate / WAD;
        userInfo[user].debt += lendAmount;
        userInfo[user].gasCompensation += liquidationFee;
        
        _checkMCR(userInfo[user].col, userInfo[user].debt);
        _checkUpdateNICR(0, lendAmount, true, true);

        totalDebt += lendAmount;

        if(stabilityPool.totalDeposits() == 0) {
            fee = 0;
        } else {
            stabilityPool.distributeProfit(fee);
        }

        nusd.mint(user, lendAmount - fee);
    }

    // 부채를 갚는 함수
    function repayNUSD(address user, uint256 repayAmount) external {
        _checkUser(user);
        
        // amount의 1달러 decimals는 1e8이지만, 체인링크 오라클에서 가져오는것도 1e8 업스케일링 되어있는 상태
        uint256 dollarToEth = viewNusdToEth(repayAmount);
        _checkNonZero(user, dollarToEth);

        userInfo[user].col -= dollarToEth;
        userInfo[user].debt -= repayAmount;

        totalCol -= dollarToEth;
        totalDebt -= repayAmount;

        nusd.burn(user, repayAmount);
        payable(user).call{value: dollarToEth}("");
    }

    // Trove 닫기
    function closeTrove(address user) external {
        _checkUser(user);
        _checkDebtZero(user);

        uint256 prevIndex = indexCount - 1;
        uint256 nextIndex = userInfo[user].index;
        userInfo[indexToUser[prevIndex]].index = nextIndex;
        indexToUser[nextIndex] = indexToUser[prevIndex];
        indexToUser[prevIndex] = address(0);

        uint256 col = userInfo[user].col;

        _initUserDetail(user);
        indexCount--;

        totalCol -= col;
        
        payable(user).call{value: col}("");

        // emit으로 마지막 index로 들어간 trove의 index번호가 바뀌었음 알려줌.
        emit swapIndex(indexToUser[nextIndex], prevIndex, nextIndex);
    }

    // 청산
    function liquidation(address user) external {
        _checkLiquidation(user);

        uint256 NICR = viewNICR(user);
        if(stabilityPool.totalDeposits() <= viewNusdToEth(userInfo[user].col)) {

            uint256 remain = userInfo[user].col;
            for(uint256 i = 0; i < indexCount; i++) {
                address target = indexToUser[indexCount];
                uint256 addCol = userInfo[user].col * userInfo[target].col / totalCol;
                userInfo[target].col += addCol;
                remain -= addCol;
                userInfo[target].debt += viewNusdToEth(addCol) * 100 * WAD / NICR ;
            }
            if(remain != 0) {
                userInfo[indexToUser[0]].col += remain;
                userInfo[indexToUser[0]].debt += viewNusdToEth(remain) * 100 * WAD / NICR ;
            }
        } else {
            stabilityPool.liquidation{value: userInfo[user].col}(viewEthToNusd(userInfo[user].col), NICR);
        }

        nusd.mint(msg.sender, liquidationBonus + userInfo[user].col * feeRate / WAD);
        _initUserDetail(user);
    }

    function _initUserDetail(address user) internal {
        userInfo[user] = UserDetail({
            user: address(0),
            col: 0,
            debt: 0,
            index: 0,
            gasCompensation: 0
        });
    }

    // 청산되어야 할 index들이 들어있는 list를 가져오는 함수.
    function getLiquidationTrove(uint256 indexNum) public returns(uint256[] memory indexList) {
        return oracle.getLiquidationTrove(indexNum);
    }


    function _checkOwner() internal view {
        require(owner == msg.sender, "Not owner");
    }

    function _checkUser(address user) internal view {
        require(user == msg.sender, "Check valid user");
    }

    function _checkZeroAddress(address user) internal view {
        require(userInfo[user].user == address(0), "Already open trove");
    }

    function _checkDebtZero(address user) internal view {
        require(userInfo[user].debt == 0, "Repay debt");
    }

    function _checkCCR(uint256 col, uint256 debt) internal view {
        require(100 * WAD * col / debt > CCR, "ICR is needed over by 150%");
    }

    // ICR은 MCR보다 커야 하며, 들어 갔을 때 total ICR은 CCR보다 커야 한다.
    function _checkMCR(uint256 col, uint256 debt) internal view {
        require(100 * WAD * col / debt > MCR, "Icr needs to be above 110%");
    }

    // direction - True + 
    function _checkUpdateNICR(uint256 col, uint256 debt, bool colDirection, bool debtDirection) internal view {
        if(colDirection == true) {
            if(debtDirection == true) {
                require(
                100 * WAD * (totalCol + col) / (totalDebt + debt) > CCR,
                "Total NICR needs to be above 150%"
                );
            } else {
                require(
                100 * WAD * (totalCol + col) / (totalDebt - debt) > CCR,
                "Total NICR needs to be above 150%"
                );
            }
        } else {
            if(debtDirection == true) {
                require(
                100 * WAD * (totalCol - col) / (totalDebt + debt) > CCR,
                "Total NICR needs to be above 150%"
                );
            } else {
                require(
                100 * WAD * (totalCol - col) / (totalDebt - debt) > CCR,
                "Total NICR needs to be above 150%"
                );
            }
        }
    }

    function _checkLiquidation(address user) internal view {
        uint256 MCR = _checkRecoveryMode()? 150 : 110;
        require(viewNICR(user) < MCR * WAD, "Not NICR rate");
    }

    function _checkNonZero(address user, uint256 repayAmount) internal view {
        require(repayAmount != 0, "Zero repay");
        require(repayAmount <= userInfo[user].col, "Too much");
    }

    function _checkRecoveryMode() internal view returns(bool) {
        if(100 * totalCol / totalDebt > CCR) {
            return false;
        } else {
            return true;
        }
    }

    function _checkMinimumDebt(uint256 _debt) internal view {
        require(_debt > 1800 * WAD, "Minimum 1800LUSD");
    }
   
    // 이더 개수를 입력하면 달러로 얼마인지를 리턴, 1 달러 == 1e18
    function viewEthToNusd(uint256 ethAmount) public view returns(uint256) {
        return oracle.getEthPrice() * ethAmount / WAD;
    }

    // nusd 양을 입력하면 이더 몇개인지 나옴, 1 개 == 1e18
    function viewNusdToEth(uint256 nusdAmount) public view returns(uint256) {
        return nusdAmount * WAD / oracle.getEthPrice();
    }

    function viewNICR(address user) public view returns(uint256) {
        return viewEthToNusd(userInfo[user].col) * WAD * 100 / userInfo[user].debt;
    }

    function viewUserDetail(address user) public view returns(UserDetail memory) {
        return userInfo[user];
    } 
}