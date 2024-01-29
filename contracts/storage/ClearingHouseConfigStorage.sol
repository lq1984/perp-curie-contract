// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.7.6;

/// @notice For future upgrades, do not change ClearingHouseConfigStorageV1. Create a new
/// contract which implements ClearingHouseConfigStorageV1 and following the naming convention
/// ClearingHouseConfigStorageVX.
abstract contract ClearingHouseConfigStorageV1 {
    uint8 internal _maxMarketsPerAccount;
    // 初始保证金率
    uint24 internal _imRatio;
    // 维持保证金率
    uint24 internal _mmRatio;
    // 清算罚金比例，用于奖励给清算人儿
    uint24 internal _liquidationPenaltyRatio;

    // 最大资金费率
    uint24 internal _maxFundingRate;

    // twap 周期
    uint32 internal _twapInterval;

    // 结算token余额上限
    uint256 internal _settlementTokenBalanceCap;

    // _partialCloseRatio is deprecated  弃用，不考虑
    uint24 internal _partialCloseRatio;
}

// 弃用，不考虑
abstract contract ClearingHouseConfigStorageV2 is ClearingHouseConfigStorageV1 {
    // _backstopLiquidityProviderMap is deprecated
    mapping(address => bool) internal _backstopLiquidityProviderMap;
}

abstract contract ClearingHouseConfigStorageV3 is ClearingHouseConfigStorageV2 {
    // 标记价格TWAP周期
    uint32 internal _markPriceMarketTwapInterval;
    // 溢价指数TW周期
    uint32 internal _markPricePremiumInterval;
}
