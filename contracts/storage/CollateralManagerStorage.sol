// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;

import { Collateral } from "../lib/Collateral.sol";

abstract contract CollateralManagerStorageV1 {
    // key: token address, value: collateral config
    // 抵押品配置
    mapping(address => Collateral.Config) internal _collateralConfigMap;

    // 配置
    address internal _clearingHouseConfig;

    // 金库
    address internal _vault;

    // 每一个账号最大抵押token种类数量
    uint8 internal _maxCollateralTokensPerAccount;

    // https://support.perp.com/hc/en-us/articles/5257432076569#heading-6
    // 这个用于抵押品清算，加上50个基点的缓冲，这个就是缓冲
    uint24 internal _mmRatioBuffer;

    // 非结算token负债阈值
    uint24 internal _debtNonSettlementTokenValueRatio;

    // 清算比例
    uint24 internal _liquidationRatio;

    // 风险保证金费率
    uint24 internal _clInsuranceFundFeeRatio;

    // 负债阈值
    uint256 internal _debtThreshold;

    uint256 internal _collateralValueDust;
}

abstract contract CollateralManagerStorageV2 is CollateralManagerStorageV1 {
    // key: trader address, value: whitelisted debt threshold
    mapping(address => uint256) internal _whitelistedDebtThresholdMap;

    uint256 internal _totalWhitelistedDebtThreshold;
}
