// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.7.6;

import { IBaseToken } from "../interface/IBaseToken.sol";

/// @notice For future upgrades, do not change BaseTokenStorageV1. Create a new
/// contract which implements BaseTokenStorageV1 and following the naming convention
/// BaseTokenStorageVX.
abstract contract BaseTokenStorageV1 {
    // --------- IMMUTABLE ---------

    // _priceFeedDecimals is now priceFeedDispatcherDecimals, which is IPriceFeedDispatcher.decimals()
    // 数据源价格精度
    uint8 internal _priceFeedDecimals;

    // --------- ^^^^^^^^^ ---------

    // _priceFeed is now priceFeedDispatcher, which dispatches either Chainlink or UniswapV3 price
    // IndexPrice价格数据源
    address internal _priceFeed;
}

abstract contract BaseTokenStorageV2 is BaseTokenStorageV1 {
    // 状态
    IBaseToken.Status internal _status;

    // 禁用时的Indexprice
    uint256 internal _pausedIndexPrice;

    // 禁用时间
    uint256 internal _pausedTimestamp;

    // 关闭时的价格
    uint256 internal _closedPrice;
}
