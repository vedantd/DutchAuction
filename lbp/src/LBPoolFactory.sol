// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "./LBPPool.sol";

contract LBPPoolFactory is Ownable {
    using SafeERC20 for IERC20;

    address public implementation;
    address public proxyAdmin;

    event PoolCreated(address indexed pool, address indexed owner);

    constructor(
        address _implementation,
        address _proxyAdmin
    ) Ownable(msg.sender) {
        implementation = _implementation;
        proxyAdmin = _proxyAdmin;
    }

    function createPool(
        IERC20[2] memory tokens,
        uint256[2] memory initialBalances,
        uint256[2] memory weights,
        uint256 swapFeePercentage,
        bool swapEnabledOnStart,
        uint256 startTime,
        uint256 endTime
    ) public returns (address) {
        bytes memory initData = abi.encodeWithSelector(
            LBPPool(implementation).initialize.selector,
            msg.sender, // Set the caller as the owner
            tokens,
            initialBalances,
            weights,
            swapFeePercentage,
            swapEnabledOnStart,
            startTime,
            endTime
        );

        TransparentUpgradeableProxy newPoolProxy = new TransparentUpgradeableProxy(
                implementation,
                proxyAdmin,
                initData
            );

        // Transfer tokens from the caller to the new pool
        for (uint256 i = 0; i < 2; i++) {
            tokens[i].safeTransferFrom(
                msg.sender,
                address(newPoolProxy),
                initialBalances[i]
            );
        }

        emit PoolCreated(address(newPoolProxy), msg.sender);
        return address(newPoolProxy);
    }

    function setImplementation(address _newImplementation) external onlyOwner {
        implementation = _newImplementation;
    }

    function setProxyAdmin(address _newProxyAdmin) external onlyOwner {
        proxyAdmin = _newProxyAdmin;
    }
}
