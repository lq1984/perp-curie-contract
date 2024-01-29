// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.7.6;

/// @notice For future upgrades, do not change MarketRegistryStorageV1. Create a new
/// contract which implements MarketRegistryStorageV1 and following the naming convention
/// MarketRegistryStorageVX.
abstract contract MarketRegistryStorageV1 {
    address internal _uniswapV3Factory;
    address internal _quoteToken;

    // 每一个交易对最多的订单数量
    uint8 internal _maxOrdersPerMarket;

    // key: baseToken, value: pool
    mapping(address => address) internal _poolMap;

    // 从交易手续费中提取一定比例的费用作为风险保证金
    // key: baseToken, what insurance fund get = exchangeFee * insuranceFundFeeRatio
    mapping(address => uint24) internal _insuranceFundFeeRatioMap;

    // 交易所手续费率
    // key: baseToken , uniswap fee will be ignored and use the exchangeFeeRatio instead
    mapping(address => uint24) internal _exchangeFeeRatioMap;

    // uniswap 手续费率
    // key: baseToken, _uniswapFeeRatioMap cache only
    mapping(address => uint24) internal _uniswapFeeRatioMap;
}

abstract contract MarketRegistryStorageV2 is MarketRegistryStorageV1 {
    // key: base token
    // value: the max price spread ratio of the market
    // 交易对最大的划点
    mapping(address => uint24) internal _marketMaxPriceSpreadRatioMap;
}

abstract contract MarketRegistryStorageV3 is MarketRegistryStorageV2 {
    // key: trader
    // value: discount ratio (percent-off)
    // 用户手续费折扣
    mapping(address => uint24) internal _feeDiscountRatioMap;
}

abstract contract MarketRegistryStorageV4 is MarketRegistryStorageV3 {
    // 给定几个地址，允许其管理相关的手续费率的更新
    mapping(address => bool) internal _feeManagerMap;
}
