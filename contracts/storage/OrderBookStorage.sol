// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.7.6;

import { Tick } from "../lib/Tick.sol";
import { Funding } from "../lib/Funding.sol";
import { OpenOrder } from "../lib/OpenOrder.sol";

/// @notice For future upgrades, do not change OrderBookStorageV1. Create a new
/// contract which implements OrderBookStorageV1 and following the naming convention
/// OrderBookStorageVX.
abstract contract OrderBookStorageV1 {
    address internal _exchange;

    // 管理一个用户下持有的订单ids
    // first key: trader, second key: base token
    mapping(address => mapping(address => bytes32[])) internal _openOrderIdsMap;

    // 通过订单id 找到订单
    // key: openOrderId
    mapping(bytes32 => OpenOrder.Info) internal _openOrderMap;

    // 用于计算流动性收益，也就是 tick外的累积的手续费总和，和uniswapV3一致
    // first key: base token, second key: tick index
    // value: the accumulator of **Tick.GrowthInfo** outside each tick of each pool
    mapping(address => mapping(int24 => Tick.GrowthInfo)) internal _growthOutsideTickMap;

    // 用于计算流动性收益，
    // key: base token
    // value: the global accumulator of **quote fee transformed from base fee** of each pool
    mapping(address => uint256) internal _feeGrowthGlobalX128Map;
}
