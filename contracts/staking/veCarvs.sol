// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Settings.sol";
import "../interfaces/IveCarvs.sol";

contract veCarvs is Settings, AccessControlUpgradeable, MulticallUpgradeable, IveCarvs {

    bytes32 public constant SPECIAL_DEPOSIT_ROLE = keccak256("SPECIAL_DEPOSIT_ROLE");

    /*---------- token infos ----------*/
    address public token;
    string public name;
    string public symbol;

    /*---------- Global reward parameters ----------*/
    uint256 public constant PRECISION = 1e18;
    uint256 public accumulatedRewardPerShare;
    uint256 public totalShare;
    uint256 public lastRewardTimestamp;
    uint256 public rewardTokenAmount;

    /*---------- Global algorithm parameters ----------*/
    // The contract will define the length of min time period here.
    uint256 public constant DURATION_PER_EPOCH = 1 days;
    uint256 public initialTimestamp;
    // epoch -> delta slope
    mapping(uint32 => int256) public slopeChanges;
    // epoch -> point
    EpochPoint[] public epochPoints;

    /*---------- User algorithm parameters ----------*/
    mapping(address => mapping(uint32 => int256)) public userSlopeChanges;
    mapping(address => EpochPoint[]) public userEpochPoints;

    /*---------- User position parameters ----------*/
    uint64 public positionIndex;
    mapping(uint64 => Position) public positions;

    function initialize(
        string memory name_, string memory symbol_, address carvToken
    ) public initializer {
        name = name_;
        symbol = symbol_;
        token = carvToken;
        initialTimestamp = (block.timestamp / DURATION_PER_EPOCH) * DURATION_PER_EPOCH;
        _newPoint(address(0), EpochPoint(0, 0, 0));
        __Settings_init(msg.sender);
        __Multicall_init();
        __AccessControl_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function depositRewardToken(uint256 amount) external {
        require(amount > 0, "invalid amount");
        rewardTokenAmount += amount;
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        emit DepositRewardToken(msg.sender, amount);
    }

    function deposit(uint256 amount, uint256 duration) external {
        require(duration <= type(uint16).max * DURATION_PER_EPOCH && duration % DURATION_PER_EPOCH == 0, "invalid duration");
        require(amount >= minStakingAmount(), "invalid amount");

        DurationInfo memory durationInfo = supportedDurations(uint16(duration/DURATION_PER_EPOCH));
        _deposit(msg.sender, amount, duration, durationInfo);
    }

    function depositForSpecial(address user, uint256 amount, uint256 duration) external onlyRole(SPECIAL_DEPOSIT_ROLE) {
        require(user != address(0), "zero address");
        require(duration <= type(uint16).max * DURATION_PER_EPOCH && duration % DURATION_PER_EPOCH == 0, "invalid duration");

        DurationInfo memory durationInfo = specialDurations(uint16(duration/DURATION_PER_EPOCH));
        _deposit(user, amount, duration, durationInfo);
    }

    function withdraw(uint64 positionID) external {
        Position storage position = positions[positionID];

        if (!position.finalized) {
            finalize(positionID);
        }

        require(position.user == msg.sender, "user not match or already withdrawn");
        IERC20(token).transfer(msg.sender, position.balance);
        delete positions[positionID];
        emit Withdraw(positionID);
    }

    function claim(uint64 positionID) external {
        Position storage position = positions[positionID];
        require(!position.finalized, "already finalized");
        require(position.user == msg.sender, "user not match or already withdrawn");

        _updateShare();

        uint256 pendingReward = (position.share * accumulatedRewardPerShare) / PRECISION - position.debt;
        if (pendingReward > 0) {
            rewardTokenAmount -= pendingReward;
            position.debt = (position.share * accumulatedRewardPerShare) / PRECISION;
            IERC20(token).transfer(msg.sender, pendingReward);
            emit Claim(positionID, pendingReward);
        }
    }

    function balanceOf(address user) external view returns (uint256) {
        return balanceOfAt(user, block.timestamp);
    }

    function totalSupply() external view returns (uint256) {
        return totalSupplyAt(block.timestamp);
    }

    function finalize(uint64 positionID) public {
        Position storage position = positions[positionID];
        require(!position.finalized, "already finalized");
        require(position.end <= block.timestamp, "locked");

        _updateShare();

        uint256 pendingReward = (position.share * accumulatedRewardPerShare) / PRECISION - position.debt;
        rewardTokenAmount -= pendingReward;
        totalShare -= position.share;
        position.finalized = true;
        position.balance += pendingReward;
        emit Finalize(positionID, pendingReward);
    }

    function checkEpoch(address withUser) public {
        _checkEpoch(address(0), epochPoints, slopeChanges);

        if (withUser != address(0)) {
            if (userEpochPoints[withUser].length == 0) {
                // initialize user array
                _newPoint(withUser, EpochPoint(0, 0, epoch()));
                return;
            }
            _checkEpoch(withUser, userEpochPoints[withUser], userSlopeChanges[withUser]);
        }
    }

    function balanceOfAt(address user, uint256 timestamp) public view returns (uint256) {
        return _biasAt(userEpochPoints[user], userSlopeChanges[user], timestamp);
    }

    function totalSupplyAt(uint256 timestamp) public view returns (uint256) {
        return _biasAt(epochPoints, slopeChanges, timestamp);
    }

    function epoch() public view returns (uint32) {
        return epochAt(block.timestamp);
    }

    function epochAt(uint256 timestamp) public view returns (uint32) {
        return uint32((timestamp - initialTimestamp) / DURATION_PER_EPOCH);
    }

    function epochTimestamp(uint32 epochIndex) public view returns (uint256) {
        return epochIndex * DURATION_PER_EPOCH + initialTimestamp;
    }

    function decimals() public pure returns (uint8) {
        return 18;
    }

    function _deposit(address user, uint256 amount, uint256 duration, DurationInfo memory durationInfo) internal {
        require(durationInfo.active, "invalid duration");
        _updateShare();

        uint256 beginTimestamp = (block.timestamp / DURATION_PER_EPOCH) * DURATION_PER_EPOCH;
        uint256 share = amount * durationInfo.rewardWeight / DURATION_INFO_DECIMALS;
        uint256 debt = (share * accumulatedRewardPerShare) / PRECISION;

        positionIndex++;
        positions[positionIndex] = Position(user, false, amount, beginTimestamp + duration, share, debt);
        totalShare += share;

        checkEpoch(user);
        _updateCurrentPoint(user, durationInfo.stakingMultiplier, amount, beginTimestamp, duration);

        IERC20(token).transferFrom(msg.sender, address(this), amount);
        emit Deposit(positionIndex, user, amount, beginTimestamp, duration, share, debt);
    }

    function _updateShare() internal {
        if (block.timestamp <= lastRewardTimestamp) {
            return;
        }

        if (totalShare == 0) {
            lastRewardTimestamp = block.timestamp;
        } else {
            uint256 newReward = (block.timestamp - lastRewardTimestamp) * rewardPerSecond();
            accumulatedRewardPerShare += (newReward * PRECISION) / totalShare;
            lastRewardTimestamp = block.timestamp;
        }

        emit UpdateShare(accumulatedRewardPerShare);
    }

    function _checkEpoch(address user, EpochPoint[] storage epochPoints_, mapping(uint32 => int256) storage slopeChanges_) internal {
        uint32 currentEpoch = epoch();
        uint32 lastRecordEpoch = epochPoints_[epochPoints_.length-1].epochIndex;

        if (currentEpoch <= lastRecordEpoch) {
            return;
        }

        // From the epoch of the previous Point to the current epoch
        for (uint32 epochIndex = lastRecordEpoch+1; epochIndex <= currentEpoch; epochIndex++) {
            // EpochPoints will be updated only when the slope changes or reaches the current epoch.
            if (slopeChanges_[epochIndex] == 0 && epochIndex < currentEpoch) {
                continue;
            }

            EpochPoint memory lastEpochPoint = epochPoints_[epochPoints_.length-1];
            EpochPoint memory newEpochPoint;
            newEpochPoint.slope = lastEpochPoint.slope + slopeChanges_[epochIndex];
            newEpochPoint.bias = _calculate(lastEpochPoint.bias, lastEpochPoint.slope, (epochIndex - lastEpochPoint.epochIndex) * DURATION_PER_EPOCH);
            newEpochPoint.epochIndex = epochIndex;
            _newPoint(user, newEpochPoint);
        }
    }

    function _newPoint(address user, EpochPoint memory point) internal {
        if (user == address(0)) {
            epochPoints.push(point);
        } else {
            userEpochPoints[user].push(point);
        }
        emit NewPoint(user, point.bias, point.slope, point.epochIndex);
    }

    // update slope and bias
    function _updateCurrentPoint(
        address user, uint32 stakingMultiplier, uint256 amount, uint256 beginTimestamp, uint256 duration
    ) internal {
        uint256 initialBias = amount * stakingMultiplier / DURATION_INFO_DECIMALS;
        uint256 slope = initialBias / duration + 1;
        uint32 endEpoch = epochAt(beginTimestamp + duration);

        // update global slope and bias
        slopeChanges[endEpoch] -= int256(slope);
        epochPoints[epochPoints.length-1].slope += int256(slope);
        epochPoints[epochPoints.length-1].bias += initialBias;
        // update user's slope and bias
        userSlopeChanges[user][endEpoch] -= int256(slope);
        userEpochPoints[user][userEpochPoints[user].length-1].slope += int256(slope);
        userEpochPoints[user][userEpochPoints[user].length-1].bias += initialBias;

        emit UpdateCurrentPoint(user, slope, initialBias, endEpoch);
    }

    function _biasAt(EpochPoint[] memory epochPoints_, mapping(uint32 => int256) storage slopeChanges_, uint256 timestamp) internal view returns (uint256) {
        EpochPoint memory lastRecordEpochPoint = epochPoints_[epochPoints_.length-1];
        uint32 targetEpoch = epochAt(timestamp);

        if (targetEpoch < lastRecordEpochPoint.epochIndex) {
            for (uint256 epochPointsIndex = epochPoints_.length-2; ; epochPointsIndex--) {
                EpochPoint memory epochPoint = epochPoints_[epochPointsIndex];
                if (targetEpoch >= epochPoint.epochIndex) {
                    return _calculate(epochPoint.bias, epochPoint.slope, timestamp - epochTimestamp(epochPoint.epochIndex));
                }
            }
        }

        uint256 tmpBias = lastRecordEpochPoint.bias;
        int256 tmpSlope = lastRecordEpochPoint.slope;
        for (uint32 epochIndex = lastRecordEpochPoint.epochIndex; epochIndex < targetEpoch; epochIndex++) {
            tmpBias = _calculate(tmpBias, tmpSlope, DURATION_PER_EPOCH);
            tmpSlope += slopeChanges_[epochIndex+1];
        }
        return _calculate(tmpBias, tmpSlope, timestamp - epochTimestamp(targetEpoch));
    }

    function _calculate(uint256 bias, int256 slope, uint256 duration) internal pure returns (uint256) {
        if (bias < uint256(slope) * (duration)) {
            return 0;
        }
        return (bias - uint256(slope) * (duration));
    }
}
