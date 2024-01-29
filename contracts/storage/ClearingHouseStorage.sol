// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.7.6;

/// @notice For future upgrades, do not change ClearingHouseStorageV1. Create a new
/// contract which implements ClearingHouseStorageV1 and following the naming convention
/// ClearingHouseStorageVX.
abstract contract ClearingHouseStorageV1 {
    // --------- IMMUTABLE ---------
    address internal _quoteToken;
    address internal _uniswapV3Factory;

    // cache the settlement token's decimals for gas optimization
    // 结算token的精度
    uint8 internal _settlementTokenDecimals;
    // --------- ^^^^^^^^^ ---------

    // 配置项
    address internal _clearingHouseConfig;
    // 金库
    address internal _vault;
    // 撮合引擎
    address internal _exchange;
    // 订单簿 也就是 range order,和流动性相关
    address internal _orderBook;
    // 管理用户仓位 已实现盈亏 手续费之类的记账
    address internal _accountBalance;
    // 风险保证金
    address internal _insuranceFund;
}

abstract contract ClearingHouseStorageV2 is ClearingHouseStorageV1 {
    address internal _delegateApproval;
}
