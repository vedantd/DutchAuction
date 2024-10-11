// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract LBPPool is Initializable {
    using SafeERC20 for IERC20;

    struct PoolToken {
        IERC20 token;
        uint256 balance;
        uint256 denormWeight;
    }

    uint256 private constant MIN_WEIGHT = 1e16; // 1%
    uint256 private constant MAX_WEIGHT = 50e16; // 50%
    uint256 private constant TOTAL_WEIGHT = 50e18; // 100%
    uint256 private constant MIN_BALANCE = 1e6;

    PoolToken[] public poolTokens;
    uint256 public swapFeePercentage;
    bool public swapEnabled;
    address public owner;

    // Weight change parameters
    uint256 public startTime;
    uint256 public endTime;
    uint256[] public startWeights;
    uint256[] public endWeights;

    event SwapFeePercentageChanged(uint256 swapFeePercentage);
    event SwapEnabledSet(bool swapEnabled);
    event GradualWeightUpdateScheduled(
        uint256 startTime,
        uint256 endTime,
        uint256[] startWeights,
        uint256[] endWeights
    );

    function initialize(
        IERC20[] memory tokens,
        uint256[] memory initialBalances,
        uint256[] memory weights,
        uint256 _swapFeePercentage,
        bool _swapEnabledOnStart,
        address _owner
    ) public initializer {
        require(
            tokens.length == initialBalances.length &&
                tokens.length == weights.length,
            "Array lengths must match"
        );
        require(
            tokens.length >= 2 && tokens.length <= 4,
            "Must have 2-4 tokens"
        );

        uint256 totalWeight = 0;
        for (uint256 i = 0; i < tokens.length; i++) {
            require(
                weights[i] >= MIN_WEIGHT && weights[i] <= MAX_WEIGHT,
                "Weight out of range"
            );
            require(initialBalances[i] >= MIN_BALANCE, "Balance too low");
            totalWeight += weights[i];

            poolTokens.push(
                PoolToken({
                    token: tokens[i],
                    balance: initialBalances[i],
                    denormWeight: weights[i]
                })
            );
            tokens[i].safeTransferFrom(
                msg.sender,
                address(this),
                initialBalances[i]
            );
        }
        require(totalWeight == TOTAL_WEIGHT, "Total weight must be 100%");

        swapFeePercentage = _swapFeePercentage;
        swapEnabled = _swapEnabledOnStart;
        owner = _owner;
    }

    function setSwapFeePercentage(uint256 newSwapFeePercentage) external {
        require(msg.sender == owner, "Only owner");
        require(
            newSwapFeePercentage >= 1e12 && newSwapFeePercentage <= 1e17,
            "Invalid swap fee percentage"
        );
        swapFeePercentage = newSwapFeePercentage;
        emit SwapFeePercentageChanged(newSwapFeePercentage);
    }

    function setSwapEnabled(bool enabled) external {
        require(msg.sender == owner, "Only owner");
        swapEnabled = enabled;
        emit SwapEnabledSet(enabled);
    }

    function updateWeightsGradually(
        uint256 _startTime,
        uint256 _endTime,
        uint256[] memory newEndWeights
    ) external {
        require(msg.sender == owner, "Only owner");
        require(
            _startTime >= block.timestamp,
            "Start time must be in the future"
        );
        require(_endTime > _startTime, "End time must be after start time");
        require(
            newEndWeights.length == poolTokens.length,
            "Weights array length mismatch"
        );

        uint256 totalWeight = 0;
        for (uint256 i = 0; i < newEndWeights.length; i++) {
            require(
                newEndWeights[i] >= MIN_WEIGHT &&
                    newEndWeights[i] <= MAX_WEIGHT,
                "Weight out of range"
            );
            totalWeight += newEndWeights[i];
        }
        require(totalWeight == TOTAL_WEIGHT, "Total weight must be 100%");

        startTime = _startTime;
        endTime = _endTime;
        startWeights = new uint256[](poolTokens.length);
        endWeights = newEndWeights;

        for (uint256 i = 0; i < poolTokens.length; i++) {
            startWeights[i] = poolTokens[i].denormWeight;
        }

        emit GradualWeightUpdateScheduled(
            startTime,
            endTime,
            startWeights,
            endWeights
        );
    }

    function getNormalizedWeights()
        public
        view
        returns (uint256[] memory weights)
    {
        weights = new uint256[](poolTokens.length);
        uint256 totalWeight = 0;

        if (block.timestamp < startTime) {
            for (uint256 i = 0; i < poolTokens.length; i++) {
                weights[i] = poolTokens[i].denormWeight;
                totalWeight += weights[i];
            }
        } else if (block.timestamp >= endTime) {
            for (uint256 i = 0; i < poolTokens.length; i++) {
                weights[i] = endWeights[i];
                totalWeight += weights[i];
            }
        } else {
            uint256 pctProgress = ((block.timestamp - startTime) * 1e18) /
                (endTime - startTime);
            for (uint256 i = 0; i < poolTokens.length; i++) {
                weights[i] =
                    startWeights[i] +
                    ((endWeights[i] - startWeights[i]) * pctProgress) /
                    1e18;
                totalWeight += weights[i];
            }
        }

        for (uint256 i = 0; i < weights.length; i++) {
            weights[i] = (weights[i] * 1e18) / totalWeight;
        }
    }

    function swap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn
    ) external returns (uint256 amountOut) {
        require(swapEnabled, "Swaps not enabled");
        require(tokenIn != tokenOut, "Cannot swap same token");

        (PoolToken storage ptIn, PoolToken storage ptOut) = _getPoolTokens(
            tokenIn,
            tokenOut
        );

        uint256[] memory weights = getNormalizedWeights();
        uint256 weightIn = weights[_getTokenIndex(tokenIn)];
        uint256 weightOut = weights[_getTokenIndex(tokenOut)];

        uint256 spotPriceBeforeTrade = _calculateSpotPrice(
            ptIn.balance,
            weightIn,
            ptOut.balance,
            weightOut
        );
        amountOut = _calcOutGivenIn(
            ptIn.balance,
            weightIn,
            ptOut.balance,
            weightOut,
            amountIn,
            swapFeePercentage
        );

        ptIn.balance += amountIn;
        ptOut.balance -= amountOut;

        uint256 spotPriceAfterTrade = _calculateSpotPrice(
            ptIn.balance,
            weightIn,
            ptOut.balance,
            weightOut
        );
        require(
            spotPriceAfterTrade >= spotPriceBeforeTrade,
            "Trade causes price to decrease"
        );

        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenOut.safeTransfer(msg.sender, amountOut);

        return amountOut;
    }

    function _getPoolTokens(
        IERC20 tokenA,
        IERC20 tokenB
    ) internal view returns (PoolToken storage, PoolToken storage) {
        uint256 indexA = type(uint256).max;
        uint256 indexB = type(uint256).max;

        for (uint256 i = 0; i < poolTokens.length; i++) {
            if (poolTokens[i].token == tokenA) {
                indexA = i;
            } else if (poolTokens[i].token == tokenB) {
                indexB = i;
            }

            if (indexA != type(uint256).max && indexB != type(uint256).max) {
                break;
            }
        }

        require(
            indexA != type(uint256).max && indexB != type(uint256).max,
            "Token not found in pool"
        );
        return (poolTokens[indexA], poolTokens[indexB]);
    }

    function _getTokenIndex(IERC20 token) internal view returns (uint256) {
        for (uint256 i = 0; i < poolTokens.length; i++) {
            if (poolTokens[i].token == token) {
                return i;
            }
        }
        revert("Token not found in pool");
    }

    function _calculateSpotPrice(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut
    ) internal pure returns (uint256) {
        return (balanceIn * weightOut) / (balanceOut * weightIn);
    }

    function _calcOutGivenIn(
        uint256 balanceIn,
        uint256 weightIn,
        uint256 balanceOut,
        uint256 weightOut,
        uint256 amountIn,
        uint256 swapFee
    ) internal pure returns (uint256 amountOut) {
        uint256 weightRatio = (weightIn * 1e18) / weightOut;
        uint256 adjustedIn = (amountIn * (1e18 - swapFee)) / 1e18;
        uint256 y = (balanceIn * 1e18) / (balanceIn + adjustedIn);
        uint256 foo = y ** weightRatio;
        uint256 bar = 1e18 - foo;
        amountOut = (balanceOut * bar) / 1e18;
    }
}
