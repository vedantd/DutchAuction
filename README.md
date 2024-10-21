# DutchAuction
Contracts (programs on blockchain) for creating a dutch auction on EVM compatible blockchains.


# LBP System Permissions and Allowances

## 1. Contracts and Entities

1. LBPPoolFactory
2. LBPPool
3. Factory Owner
4. Pool Owner
5. Regular Users
6. ProxyAdmin

## 2. Detailed Permissions Breakdown

### 2.1 LBPPoolFactory Contract

Allowed Actions:
- Create new LBPPool instances
- Transfer initial token balances to newly created pools

Permissions:
- Can deploy new TransparentUpgradeableProxy contracts
- Can call initialize on new LBPPool instances
- Can transfer tokens from the pool creator to the new pool

### 2.2 LBPPool Contract

Allowed Actions:
- Manage token balances and weights
- Execute swaps between the two pool tokens
- Update weights gradually over time

Permissions:
- Can transfer tokens to and from users during swaps
- Can modify its own state variables (balances, weights, etc.)

### 2.3 Factory Owner

Allowed Actions:
- Set new implementation address for LBPPool
- Set new proxy admin address

Permissions:
- Call setImplementation on LBPPoolFactory
- Call setProxyAdmin on LBPPoolFactory

### 2.4 Pool Owner (set during pool creation)

Allowed Actions:
- Set swap fee percentage
- Enable or disable swaps
- Update weights gradually

Permissions:
- Call setSwapFeePercentage on LBPPool
- Call setSwapEnabled on LBPPool
- Call updateWeightsGradually on LBPPool

### 2.5 Regular Users

Allowed Actions:
- Create new pools (if they have sufficient token balances)
- Swap tokens in existing pools

Permissions:
- Call createPool on LBPPoolFactory (requires token approval)
- Call swap on LBPPool instances (requires token approval)

### 2.6 ProxyAdmin

Allowed Actions:
- Upgrade the implementation of LBPPool instances
- Call admin functions on the proxy contracts

Permissions:
- Call upgrade on TransparentUpgradeableProxy instances
- Call changeAdmin on TransparentUpgradeableProxy instances

## 3. Token Allowances

1. For Pool Creation:
   - Users must approve LBPPoolFactory to spend the initial token balances
   - Allowance must be at least equal to the initialBalances specified in createPool

2. For Swaps:
   - Users must approve LBPPool to spend the token they're swapping in
   - Allowance must be at least equal to the amountIn specified in the swap function

## 4. Important Notes

1. The LBPPoolFactory does not have permission to modify existing pools or their parameters.
2. Regular users cannot modify pool parameters (fees, weights, swap enablement).
3. The Pool Owner cannot withdraw tokens or change the fundamental structure of the pool.
4. The Factory Owner cannot directly interact with or modify individual pools.
5. The ProxyAdmin has significant power and should be a secure multisig or governance contract.

## 5. Potential Improvements in Permissions and Allowances

1. Tiered Permissions: Implement a more granular permission system allowing for different levels of access.
2. Time-Locked Operations: Add time locks to sensitive operations like implementation upgrades.
3. Governance Integration: Transfer certain permissions to a governance system for more decentralized control.
4. Permission Transfers: Allow pool owners to transfer their ownership to another address.
5. Emergency Controls: Implement emergency stop functions accessible by a designated guardian.
6. Allowance Optimizations: Implement infinite approvals or permit-style functions to reduce transaction costs for frequent traders.
7. Factory Permissionlessness: Consider removing the onlyOwner restriction for createPool to allow anyone to create pools.
8. Auditing and Transparency: Add events for all permission changes to increase transparency and auditability.

