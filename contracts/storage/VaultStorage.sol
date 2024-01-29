// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.7.6;

/// @notice For future upgrades, do not change VaultStorageV1. Create a new
/// contract which implements VaultStorageV1 and following the naming convention
/// VaultStorageVX.
abstract contract VaultStorageV1 {
    // --------- IMMUTABLE ---------

    // 精度
    uint8 internal _decimals;

    // 用于结算的token, 目前是USDC作为结算的token
    address internal _settlementToken;

    // --------- ^^^^^^^^^ ---------

    // 配置项
    address internal _clearingHouseConfig;

    // 用户仓位合约
    address internal _accountBalance;
    // 风险保证金合约
    address internal _insuranceFund;
    // 撮合引擎合约
    address internal _exchange;
    // 清算合约
    address internal _clearingHouse;

    // 弃用
    // _totalDebt is deprecated
    uint256 internal _totalDebt;

    // 每一个地址对应token的余额记账
    // key: trader, token address
    mapping(address => mapping(address => int256)) internal _balance;
}

abstract contract VaultStorageV2 is VaultStorageV1 {
    address internal _collateralManager;
    address internal _WETH9;

    // trader => collateral token
    // collateral token registry of each trader

    // 为每一个taker注册 抵押token列表
    mapping(address => address[]) internal _collateralTokensMap;
}
