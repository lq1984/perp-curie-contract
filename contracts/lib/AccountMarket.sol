// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.7.6;

library AccountMarket {
    /// @param lastTwPremiumGrowthGlobalX96 the last time weighted premiumGrowthGlobalX96
    struct Info {
        int256 takerPositionSize; // 仓位大小
        int256 takerOpenNotional; // 本金对应的名义价值
        int256 lastTwPremiumGrowthGlobalX96;
    }
}
