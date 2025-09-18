// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import { IAzUsd } from "src/interfaces/IAzUsd.sol";
import { IReferral } from "src/interfaces/IReferral.sol";
import { Types } from "src/Types.sol";

contract Referral is Ownable, Pausable, IReferral {
    string public constant name = "Referral";

    mapping(address => Types.ReferralInfo) public referralInfo;
    mapping(string => address) public referralCodeToAddress;
    mapping(address => string) public addressToReferralCode;
    mapping(uint256 => Types.LevelConfig) public levelConfigs;
    uint256 public maxLevel;

    IAzUsd public azUsd;
    address public defaultFeeReceiver;
    mapping(address => bool) public authorizedManagers;

    event ReferralRegistered(address indexed user, address indexed referrer, string referralCode);
    event FeeDistributed(
        address indexed user,
        address indexed referrer,
        uint256 feeAmount,
        uint256 rewardAmount,
        uint256 discountAmount,
        uint256 platformAmount,
        uint256 referrerLevel,
        FeeFrom feeFrom
    );
    event LevelUpgraded(address indexed user, uint256 oldLevel, uint256 newLevel);
    event LevelConfigUpdated(
        uint256 level,
        uint256 minSpotVolume,
        uint256 minPerpetualVolume,
        uint256 rewardRate,
        uint256 discountRate,
        bool isActive
    );
    event DefaultFeeReceiverUpdated(address indexed oldReceiver, address indexed newReceiver);
    event ManagerAuthorized(address indexed manager);
    event ManagerRevoked(address indexed manager);
    event MaxLevelUpdated(uint256 oldMaxLevel, uint256 newMaxLevel);
    event ReferralCodeUpdated(address indexed user, string oldCode, string newCode);

    error InvalidReferralCode();
    error InvalidLevel();
    error AlreadyRegistered();
    error ReferralCodeExists();
    error InvalidRewardRate();
    error InvalidDefaultFeeReceiver();
    error UnauthorizedManager();
    error TransferFailed();
    error LevelNotActive();
    error InvalidMaxLevel();
    error ReferralCodeNotSet();
    error ReferralCodeInUse();

    modifier onlyAuthorizedManager() {
        if (!authorizedManagers[msg.sender]) {
            revert UnauthorizedManager();
        }
        _;
    }

    constructor(IAzUsd _azUsd, address _defaultFeeReceiver) Ownable(msg.sender) {
        if (_defaultFeeReceiver == address(0)) {
            revert InvalidDefaultFeeReceiver();
        }
        azUsd = _azUsd;
        defaultFeeReceiver = _defaultFeeReceiver;
        maxLevel = 5;

        _initializeDefaultLevelConfigs();
    }

    function initialize(IAzUsd _azUsd, address _defaultFeeReceiver) external onlyOwner {
        if (_defaultFeeReceiver == address(0)) {
            revert InvalidDefaultFeeReceiver();
        }
        azUsd = _azUsd;
        defaultFeeReceiver = _defaultFeeReceiver;
    }

    function _initializeDefaultLevelConfigs() internal {
        levelConfigs[1] = Types.LevelConfig({
            minSpotVolume: 0,
            minPerpetualVolume: 0,
            rewardRate: 500,
            discountRate: 100,
            isActive: true
        });
        levelConfigs[2] = Types.LevelConfig({
            minSpotVolume: 500 ether,
            minPerpetualVolume: 1000 ether,
            rewardRate: 1000,
            discountRate: 200,
            isActive: true
        });
        levelConfigs[3] = Types.LevelConfig({
            minSpotVolume: 2000 ether,
            minPerpetualVolume: 5000 ether,
            rewardRate: 2000,
            discountRate: 300,
            isActive: true
        });
        levelConfigs[4] = Types.LevelConfig({
            minSpotVolume: 10_000 ether,
            minPerpetualVolume: 20_000 ether,
            rewardRate: 3000,
            discountRate: 400,
            isActive: true
        });
        levelConfigs[5] = Types.LevelConfig({
            minSpotVolume: 50_000 ether,
            minPerpetualVolume: 100_000 ether,
            rewardRate: 8500,
            discountRate: 500,
            isActive: true
        });
    }

    function updateMaxLevel(
        uint256 _maxLevel
    ) external onlyOwner {
        if (_maxLevel == 0 || _maxLevel > 10) {
            revert InvalidMaxLevel();
        }
        uint256 oldMaxLevel = maxLevel;
        maxLevel = _maxLevel;
        emit MaxLevelUpdated(oldMaxLevel, _maxLevel);
    }

    function updateLevelConfig(
        uint256 level,
        uint256 minSpotVolume,
        uint256 minPerpetualVolume,
        uint256 rewardRate,
        uint256 discountRate,
        bool isActive
    ) external onlyOwner {
        if (level == 0 || level > maxLevel) {
            revert InvalidLevel();
        }
        if (rewardRate > 9000) {
            revert InvalidRewardRate();
        }
        if (discountRate > 1000) {
            revert InvalidRewardRate();
        }

        levelConfigs[level] = Types.LevelConfig({
            minSpotVolume: minSpotVolume,
            minPerpetualVolume: minPerpetualVolume,
            rewardRate: rewardRate,
            discountRate: discountRate,
            isActive: isActive
        });

        emit LevelConfigUpdated(level, minSpotVolume, minPerpetualVolume, rewardRate, discountRate, isActive);
    }

    function batchUpdateLevelConfigs(
        uint256[] calldata levels,
        Types.LevelConfig[] calldata configs
    ) external onlyOwner {
        if (levels.length != configs.length) {
            revert("Length mismatch");
        }

        for (uint256 i = 0; i < levels.length; i++) {
            if (levels[i] == 0 || levels[i] > maxLevel) {
                revert InvalidLevel();
            }
            if (configs[i].rewardRate > 9000) {
                revert InvalidRewardRate();
            }

            levelConfigs[levels[i]] = configs[i];
            emit LevelConfigUpdated(
                levels[i],
                configs[i].minSpotVolume,
                configs[i].minPerpetualVolume,
                configs[i].rewardRate,
                configs[i].discountRate,
                configs[i].isActive
            );
        }
    }

    function _checkAndUpgradeLevel(
        address user
    ) internal {
        Types.ReferralInfo storage info = referralInfo[user];
        uint256 currentLevel = info.level;
        uint256 highestQualifiedLevel = currentLevel;

        for (uint256 i = currentLevel + 1; i <= maxLevel; i++) {
            Types.LevelConfig memory config = levelConfigs[i];
            if (!config.isActive) continue;

            if (info.spotVolume >= config.minSpotVolume || info.perpetualVolume >= config.minPerpetualVolume) {
                highestQualifiedLevel = i;
            }
        }

        if (highestQualifiedLevel > currentLevel) {
            info.level = highestQualifiedLevel;
            emit LevelUpgraded(user, currentLevel, highestQualifiedLevel);
        }
    }

    function handleFee(
        address user,
        uint256 _feeAmount,
        FeeFrom feeFrom
    ) external onlyAuthorizedManager whenNotPaused {
        if (_feeAmount == 0) return;

        Types.ReferralInfo storage info = referralInfo[user];
        address referrer = info.referrer;
        if (referrer == address(0)) return;

        Types.ReferralInfo storage referrerInfo = referralInfo[referrer];
        if (feeFrom == FeeFrom.SPOT) {
            referrerInfo.spotVolume += _feeAmount;
        } else {
            referrerInfo.perpetualVolume += _feeAmount;
        }

        _checkAndUpgradeLevel(referrer);

        referrerInfo = referralInfo[referrer];
        uint256 currentLevel = referrerInfo.level;
        Types.LevelConfig memory config = levelConfigs[currentLevel];

        uint256 rewardAmount = (_feeAmount * config.rewardRate) / 10_000;
        uint256 discountAmount = (_feeAmount * config.discountRate) / 10_000;
        uint256 platformAmount = _feeAmount - rewardAmount - discountAmount;

        referrerInfo.totalRewards += rewardAmount;

        if (rewardAmount > 0) {
            if (!azUsd.transfer(referrer, rewardAmount)) {
                revert TransferFailed();
            }
        }

        if (discountAmount > 0) {
            if (!azUsd.transfer(user, discountAmount)) {
                revert TransferFailed();
            }
        }

        if (platformAmount > 0) {
            if (!azUsd.transfer(defaultFeeReceiver, platformAmount)) {
                revert TransferFailed();
            }
        }

        emit FeeDistributed(
            user, referrer, _feeAmount, rewardAmount, discountAmount, platformAmount, currentLevel, feeFrom
        );
    }

    function authorizeManager(
        address manager
    ) external onlyOwner {
        authorizedManagers[manager] = true;
        emit ManagerAuthorized(manager);
    }

    function revokeManager(
        address manager
    ) external onlyOwner {
        authorizedManagers[manager] = false;
        emit ManagerRevoked(manager);
    }

    function register(string calldata referrerCode, string calldata userCode) external whenNotPaused {
        if (referralCodeToAddress[userCode] != address(0)) {
            revert ReferralCodeExists();
        }
        if (referralInfo[msg.sender].referrer != address(0)) {
            revert AlreadyRegistered();
        }

        address referrer;
        if (bytes(referrerCode).length > 0) {
            referrer = referralCodeToAddress[referrerCode];
            if (referrer == address(0)) {
                revert InvalidReferralCode();
            }
        }

        referralInfo[msg.sender] = Types.ReferralInfo({
            referrer: referrer,
            level: 1,
            totalReferrals: 0,
            spotVolume: 0,
            perpetualVolume: 0,
            totalRewards: 0
        });

        referralCodeToAddress[userCode] = msg.sender;
        addressToReferralCode[msg.sender] = userCode;

        if (referrer != address(0)) {
            referralInfo[referrer].totalReferrals++;
        }

        emit ReferralRegistered(msg.sender, referrer, userCode);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function getReferralInfo(
        address user
    ) external view returns (Types.ReferralInfo memory) {
        return referralInfo[user];
    }

    function getLevelConfig(
        uint256 level
    ) external view returns (Types.LevelConfig memory) {
        return levelConfigs[level];
    }

    function updateDefaultFeeReceiver(
        address _newReceiver
    ) external onlyOwner {
        if (_newReceiver == address(0)) {
            revert InvalidDefaultFeeReceiver();
        }
        address oldReceiver = defaultFeeReceiver;
        defaultFeeReceiver = _newReceiver;
        emit DefaultFeeReceiverUpdated(oldReceiver, _newReceiver);
    }

    function updateReferralCode(
        string calldata newCode
    ) external whenNotPaused {
        string memory oldCode = addressToReferralCode[msg.sender];
        if (bytes(oldCode).length == 0) {
            revert ReferralCodeNotSet();
        }
        if (referralCodeToAddress[newCode] != address(0)) {
            revert ReferralCodeInUse();
        }

        delete referralCodeToAddress[oldCode];

        referralCodeToAddress[newCode] = msg.sender;
        addressToReferralCode[msg.sender] = newCode;

        emit ReferralCodeUpdated(msg.sender, oldCode, newCode);
    }
}
