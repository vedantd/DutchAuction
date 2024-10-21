// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract LBPPool is ReentrancyGuard, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    struct PoolToken {
        IERC20 token;
        uint256 balance;
        uint256 denormWeight;
    }

    uint256 private constant WEIGHT_MULTIPLIER = 1e16;
    uint256 private constant MIN_WEIGHT = 1; // 1%
    uint256 private constant MAX_WEIGHT = 99; // 99%
    uint256 private constant TOTAL_WEIGHT = 100; // 100%
    uint256 private constant MIN_BALANCE = 1e6;

    PoolToken[2] public poolTokens;
    uint256 public swapFeePercentage;
    bool public swapEnabled;

    uint256 public startTime;
    uint256 public endTime;
    uint256[2] public startWeights;
    uint256[2] public endWeights;

    bool private initialized;

    event WeightsSet(uint256 weight0, uint256 weight1);
    event SwapFeePercentageChanged(uint256 swapFeePercentage);
    event SwapEnabledSet(bool swapEnabled);
    event GradualWeightUpdateScheduled(
        uint256 startTime,
        uint256 endTime,
        uint256[2] startWeights,
        uint256[2] endWeights
    );
    event Swap(
        address indexed caller,
        IERC20 indexed tokenIn,
        IERC20 indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    function initialize(
        address owner,
        IERC20[2] memory tokens,
        uint256[2] memory initialBalances,
        uint256[2] memory weights,
        uint256 _swapFeePercentage,
        bool _swapEnabledOnStart,
        uint256 _startTime,
        uint256 _endTime
    ) external initializer {
        __Ownable_init(owner);

        require(
            weights[0] >= MIN_WEIGHT && weights[0] <= MAX_WEIGHT,
            "Weight 0 out of range"
        );
        require(
            weights[1] >= MIN_WEIGHT && weights[1] <= MAX_WEIGHT,
            "Weight 1 out of range"
        );
        require(
            weights[0] + weights[1] == TOTAL_WEIGHT,
            "Total weight must be 100%"
        );
        require(
            initialBalances[0] >= MIN_BALANCE &&
                initialBalances[1] >= MIN_BALANCE,
            "Balance too low"
        );

        for (uint256 i = 0; i < 2; i++) {
            poolTokens[i] = PoolToken({
                token: tokens[i],
                balance: initialBalances[i],
                denormWeight: weights[i] * WEIGHT_MULTIPLIER
            });
        }

        swapFeePercentage = _swapFeePercentage;
        swapEnabled = _swapEnabledOnStart;
        startTime = _startTime;
        endTime = _endTime;
        startWeights = weights;
        endWeights = weights;

        initialized = true;
        emit WeightsSet(weights[0], weights[1]);
    }

    function setSwapFeePercentage(
        uint256 newSwapFeePercentage
    ) external onlyOwner {
        require(
            newSwapFeePercentage >= 1e12 && newSwapFeePercentage <= 1e17,
            "Invalid swap fee percentage"
        );
        swapFeePercentage = newSwapFeePercentage;
        emit SwapFeePercentageChanged(newSwapFeePercentage);
    }

    function setSwapEnabled(bool enabled) external onlyOwner {
        swapEnabled = enabled;
        emit SwapEnabledSet(enabled);
    }

    function updateWeightsGradually(
        uint256 _startTime,
        uint256 _endTime,
        uint256[2] memory newEndWeights
    ) external onlyOwner {
        require(
            _startTime >= block.timestamp,
            "Start time must be in the future"
        );
        require(_endTime > _startTime, "End time must be after start time");
        require(
            newEndWeights[0] >= MIN_WEIGHT && newEndWeights[0] <= MAX_WEIGHT,
            "Weight 0 out of range"
        );
        require(
            newEndWeights[1] >= MIN_WEIGHT && newEndWeights[1] <= MAX_WEIGHT,
            "Weight 1 out of range"
        );
        require(
            newEndWeights[0] + newEndWeights[1] == TOTAL_WEIGHT,
            "Total weight must be 100%"
        );

        startTime = _startTime;
        endTime = _endTime;
        startWeights = getCurrentDenormWeights();
        endWeights = newEndWeights;

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
        returns (uint256[2] memory weights)
    {
        uint256[2] memory denormWeights = getCurrentDenormWeights();
        uint256 totalWeight = denormWeights[0] + denormWeights[1];
        weights[0] = (denormWeights[0] * 1e18) / totalWeight;
        weights[1] = (denormWeights[1] * 1e18) / totalWeight;
    }

    function getCurrentDenormWeights()
        public
        view
        returns (uint256[2] memory weights)
    {
        if (block.timestamp <= startTime) {
            return startWeights;
        } else if (block.timestamp >= endTime) {
            return endWeights;
        } else {
            uint256 pctProgress = ((block.timestamp - startTime) * 1e18) /
                (endTime - startTime);
            weights[0] =
                startWeights[0] +
                ((endWeights[0] - startWeights[0]) * pctProgress) /
                1e18;
            weights[1] =
                startWeights[1] +
                ((endWeights[1] - startWeights[1]) * pctProgress) /
                1e18;
        }
    }

    function swap(
        IERC20 tokenIn,
        IERC20 tokenOut,
        uint256 amountIn
    ) external nonReentrant returns (uint256 amountOut) {
        require(initialized, "Pool not initialized");
        require(swapEnabled, "Swaps not enabled");
        require(tokenIn != tokenOut, "Cannot swap same token");

        (PoolToken storage ptIn, PoolToken storage ptOut) = _getPoolTokens(
            tokenIn,
            tokenOut
        );

        uint256[2] memory weights = getNormalizedWeights();
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

        emit Swap(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    function getPoolTokens()
        external
        view
        returns (
            IERC20[2] memory tokens,
            uint256[2] memory balances,
            uint256[2] memory weights
        )
    {
        require(initialized, "Pool not initialized");
        tokens[0] = poolTokens[0].token;
        tokens[1] = poolTokens[1].token;
        balances[0] = poolTokens[0].balance;
        balances[1] = poolTokens[1].balance;
        weights = getNormalizedWeights();
    }

    function getSwapFeePercentage() external view returns (uint256) {
        return swapFeePercentage;
    }

    function getLatest(
        IERC20 token
    ) external view returns (uint256 balance, uint256 weight) {
        require(initialized, "Pool not initialized");
        uint256 index = _getTokenIndex(token);
        balance = poolTokens[index].balance;
        weight = getNormalizedWeights()[index];
    }

    function _getPoolTokens(
        IERC20 tokenA,
        IERC20 tokenB
    ) internal view returns (PoolToken storage, PoolToken storage) {
        require(
            (tokenA == poolTokens[0].token && tokenB == poolTokens[1].token) ||
                (tokenA == poolTokens[1].token &&
                    tokenB == poolTokens[0].token),
            "Invalid token pair"
        );
        return
            tokenA == poolTokens[0].token
                ? (poolTokens[0], poolTokens[1])
                : (poolTokens[1], poolTokens[0]);
    }

    function _getTokenIndex(IERC20 token) internal view returns (uint256) {
        return token == poolTokens[0].token ? 0 : 1;
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
        uint256 foo = y ** (weightRatio / 1e18);
        uint256 bar = 1e18 - foo;
        amountOut = (balanceOut * bar) / 1e18;
    }
}
