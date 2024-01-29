// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import { AddressUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import { SafeMathUpgradeable } from "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import { SignedSafeMathUpgradeable } from "@openzeppelin/contracts-upgradeable/math/SignedSafeMathUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IUniswapV3MintCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import { IUniswapV3SwapCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import { FullMath } from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import { PerpSafeCast } from "./lib/PerpSafeCast.sol";
import { PerpMath } from "./lib/PerpMath.sol";
import { SettlementTokenMath } from "./lib/SettlementTokenMath.sol";
import { Funding } from "./lib/Funding.sol";
import { AccountMarket } from "./lib/AccountMarket.sol";
import { OpenOrder } from "./lib/OpenOrder.sol";
import { OwnerPausable } from "./base/OwnerPausable.sol";
import { BlockContext } from "./base/BlockContext.sol";
import { IERC20Metadata } from "./interface/IERC20Metadata.sol";
import { IVault } from "./interface/IVault.sol";
import { IExchange } from "./interface/IExchange.sol";
import { IOrderBook } from "./interface/IOrderBook.sol";
import { IBaseToken } from "./interface/IBaseToken.sol";
import { IClearingHouseConfig } from "./interface/IClearingHouseConfig.sol";
import { IAccountBalance } from "./interface/IAccountBalance.sol";
import { IInsuranceFund } from "./interface/IInsuranceFund.sol";
import { IDelegateApproval } from "./interface/IDelegateApproval.sol";
import { IClearingHouse } from "./interface/IClearingHouse.sol";
import { BaseRelayRecipient } from "./gsn/BaseRelayRecipient.sol";
import { ClearingHouseStorageV2 } from "./storage/ClearingHouseStorage.sol";

// never inherit any new stateful contract. never change the orders of parent stateful contracts
contract ClearingHouse is
    IUniswapV3MintCallback,
    IUniswapV3SwapCallback,
    IClearingHouse,
    BlockContext,
    ReentrancyGuardUpgradeable,
    OwnerPausable,
    BaseRelayRecipient,
    ClearingHouseStorageV2
{
    using AddressUpgradeable for address;
    using SafeMathUpgradeable for uint256;
    using SignedSafeMathUpgradeable for int256;
    using PerpSafeCast for uint256;
    using PerpSafeCast for uint128;
    using PerpSafeCast for int256;
    using PerpMath for uint256;
    using PerpMath for uint160;
    using PerpMath for uint128;
    using PerpMath for int256;
    using SettlementTokenMath for int256;

    //
    // STRUCT
    //

    /// @param sqrtPriceLimitX96 tx will fill until it reaches this price but WON'T REVERT
    struct InternalOpenPositionParams {
        address trader;
        address baseToken;
        bool isBaseToQuote;
        bool isExactInput;
        bool isClose;
        uint256 amount;
        uint160 sqrtPriceLimitX96;
    }

    struct InternalCheckSlippageParams {
        bool isBaseToQuote;
        bool isExactInput;
        uint256 base;
        uint256 quote;
        uint256 oppositeAmountBound;
    }

    //
    // MODIFIER
    //

    modifier checkDeadline(uint256 deadline) {
        // transaction expires
        require(_blockTimestamp() <= deadline, "CH_TE");
        _;
    }

    //
    // EXTERNAL NON-VIEW
    //

    /// @dev this function is public for testing
    // solhint-disable-next-line func-order
    function initialize(
        address clearingHouseConfigArg,
        address vaultArg,
        address quoteTokenArg,
        address uniV3FactoryArg,
        address exchangeArg,
        address accountBalanceArg,
        address insuranceFundArg
    ) public initializer {
        // CH_VANC: Vault address is not contract
        _isContract(vaultArg, "CH_VANC");
        // CH_QANC: QuoteToken address is not contract
        _isContract(quoteTokenArg, "CH_QANC");
        // CH_QDN18: QuoteToken decimals is not 18
        require(IERC20Metadata(quoteTokenArg).decimals() == 18, "CH_QDN18");
        // CH_UANC: UniV3Factory address is not contract
        _isContract(uniV3FactoryArg, "CH_UANC");
        // ClearingHouseConfig address is not contract
        _isContract(clearingHouseConfigArg, "CH_CCNC");
        // AccountBalance is not contract
        _isContract(accountBalanceArg, "CH_ABNC");
        // CH_ENC: Exchange is not contract
        _isContract(exchangeArg, "CH_ENC");
        // CH_IFANC: InsuranceFund address is not contract
        _isContract(insuranceFundArg, "CH_IFANC");

        address orderBookArg = IExchange(exchangeArg).getOrderBook();
        // orderBook is not contract
        _isContract(orderBookArg, "CH_OBNC");

        __ReentrancyGuard_init();
        __OwnerPausable_init();

        _clearingHouseConfig = clearingHouseConfigArg;
        _vault = vaultArg;
        _quoteToken = quoteTokenArg;
        _uniswapV3Factory = uniV3FactoryArg;
        _exchange = exchangeArg;
        _orderBook = orderBookArg;
        _accountBalance = accountBalanceArg;
        _insuranceFund = insuranceFundArg;

        _settlementTokenDecimals = IVault(_vault).decimals();
    }

    /// @dev remove to reduce bytecode size, might add back when we need it
    // // solhint-disable-next-line func-order
    // function setTrustedForwarder(address trustedForwarderArg) external onlyOwner {
    //     // CH_TFNC: TrustedForwarder is not contract
    //     require(trustedForwarderArg.isContract(), "CH_TFNC");
    //     // TrustedForwarderUpdated event is emitted in BaseRelayRecipient
    //     _setTrustedForwarder(trustedForwarderArg);
    // }

    function setDelegateApproval(address delegateApprovalArg) external onlyOwner {
        // CH_DANC: DelegateApproval is not contract
        require(delegateApprovalArg.isContract(), "CH_DANC");
        _delegateApproval = delegateApprovalArg;
        emit DelegateApprovalChanged(delegateApprovalArg);
    }

    /// @inheritdoc IClearingHouse
    // 增加流动性
    function addLiquidity(AddLiquidityParams calldata params)
        external
        override
        whenNotPaused
        nonReentrant
        checkDeadline(params.deadline)
        returns (AddLiquidityResponse memory)
    {
        //  struct AddLiquidityParams {
        //        address baseToken;
        //        uint256 base; // 添加的base token 数量
        //        uint256 quote; // 添加的 quote token 数量
        //        int24 lowerTick; // 价格区间lower
        //        int24 upperTick; // 价格区间upper
        //        uint256 minBase; // 最小的base数量
        //        uint256 minQuote;// 最小的quote数量
        //        bool useTakerBalance; // 默认禁用状态，这里不考虑。
        //        uint256 deadline; // 过期时间
        //    }

        // input requirement checks:
        //   baseToken: in Exchange.settleFunding()
        //   base & quote: in LiquidityAmounts.getLiquidityForAmounts() -> FullMath.mulDiv()
        //   lowerTick & upperTick: in UniswapV3Pool._modifyPosition()
        //   minBase, minQuote & deadline: here

        // 确保交易对有效
        _checkMarketOpen(params.baseToken);

        // 确保index price 和 mark price不能偏离超过阈值
        // This condition is to prevent the intentional bad debt attack through price manipulation.
        // CH_OMPS: Over the maximum price spread
        require(!IExchange(_exchange).isOverPriceSpread(params.baseToken), "CH_OMPS");

        // 禁用状态，不考虑
        // CH_DUTB: Disable useTakerBalance
        require(!params.useTakerBalance, "CH_DUTB");

        address trader = _msgSender();
        // register token if it's the first time
        _registerBaseToken(trader, params.baseToken);

        // must settle funding first
        // 结算资金费率
        Funding.Growth memory fundingGrowthGlobal = _settleFunding(trader, params.baseToken);

        // 添加流动性
        // note that we no longer check available tokens here because CH will always auto-mint in UniswapV3MintCallback
        IOrderBook.AddLiquidityResponse memory response =
            IOrderBook(_orderBook).addLiquidity(
                IOrderBook.AddLiquidityParams({
                    trader: trader,
                    baseToken: params.baseToken,
                    base: params.base,
                    quote: params.quote,
                    lowerTick: params.lowerTick,
                    upperTick: params.upperTick,
                    fundingGrowthGlobal: fundingGrowthGlobal
                })
            );

        // 检查滑点
        _checkSlippageAfterLiquidityChange(response.base, params.minBase, response.quote, params.minQuote);

        // 添加流动性产生的收益归用户所有，记账到已实现盈亏中
        // fees always have to be collected to owedRealizedPnl, as long as there is a change in liquidity
        _modifyOwedRealizedPnl(trader, response.fee.toInt256());

        // after token balances are updated, we can check if there is enough free collateral
        // 检查可用的抵押品
        _requireEnoughFreeCollateral(trader);

        // 抛事件
        _emitLiquidityChanged(
            trader, // 添加流动性的地址
            params.baseToken, // 交易对
            _quoteToken,
            params.lowerTick, // 流动性 lower
            params.upperTick, // 流动性 upper
            response.base.toInt256(), // 添加的base token数量
            response.quote.toInt256(), // 添加的 quote token数量
            response.liquidity.toInt128(), // 合计流动性
            response.fee // 返回当前区间累计的手续费，如果是首次添加，那就为0
        );

        return
            AddLiquidityResponse({
                base: response.base,
                quote: response.quote,
                fee: response.fee,
                liquidity: response.liquidity
            });
    }

    // 移除流动性
    /// @inheritdoc IClearingHouse
    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        override
        whenNotPaused
        nonReentrant
        checkDeadline(params.deadline)
        returns (RemoveLiquidityResponse memory)
    {
        // input requirement checks:
        //   baseToken: in Exchange.settleFunding()
        //   lowerTick & upperTick: in UniswapV3Pool._modifyPosition()
        //   liquidity: in LiquidityMath.addDelta()
        //   minBase, minQuote & deadline: here

        // CH_MP: Market paused
        require(!IBaseToken(params.baseToken).isPaused(), "CH_MP");

        address trader = _msgSender();

        // must settle funding first
        // 结算资金费率
        _settleFunding(trader, params.baseToken);

        // 调用uniswap 移除流动性
        IOrderBook.RemoveLiquidityResponse memory response =
            _removeLiquidity(
                IOrderBook.RemoveLiquidityParams({
                    maker: trader,
                    baseToken: params.baseToken,
                    lowerTick: params.lowerTick,
                    upperTick: params.upperTick,
                    liquidity: params.liquidity
                })
            );

        // 检查滑点
        _checkSlippageAfterLiquidityChange(response.base, params.minBase, response.quote, params.minQuote);

        // 移除流动性完成订单撮合，此时更新仓位和PNL
        // 正常情况下，
        // 做多，也就是买入，意味着支付Quote 然后得到 Base, 所以我们就需要在Upper处添加流动性，
        // 当价格下降到 Lower处时，添加的QuoteToken 将转换为 BaseToken, 这就类似于挂了一个限价订单然后到达具体价格后会被撮合
        // 做空，也就是卖出，意味着支付Base 得到Quote, 所以我们就需要在Lower，处添加流动性
        // 当价格上升到 Upper处时，添加的BaseToken 将转换为 QuoteToken, 这就相当于撮合成功

        // 当移除流动性的时候，base 和 quote token亏损
        // response.takerBase 有可能是正数也有可能是负数
        // response.takerQuote 有可能是正数也有可能是负数
        _modifyPositionAndRealizePnl(
            trader,
            params.baseToken,
            response.takerBase, // exchangedPositionSize
            response.takerQuote, // exchangedPositionNotional
            response.fee, // makerFee
            0 //takerFee
        );

        _emitLiquidityChanged(
            trader,
            params.baseToken,
            _quoteToken,
            params.lowerTick,
            params.upperTick,
            response.base.neg256(),
            response.quote.neg256(),
            params.liquidity.neg128(),
            response.fee
        );

        return RemoveLiquidityResponse({ quote: response.quote, base: response.base, fee: response.fee });
    }

    // 结算trader 所有仓位的资金费
    /// @inheritdoc IClearingHouse
    function settleAllFunding(address trader) external override {
        // only vault or trader
        // vault must check msg.sender == trader when calling settleAllFunding
        require(_msgSender() == _vault || _msgSender() == trader, "CH_OVOT");

        // 获取地址所有持仓的交易对
        address[] memory baseTokens = IAccountBalance(_accountBalance).getBaseTokens(trader);
        uint256 baseTokenLength = baseTokens.length;
        for (uint256 i = 0; i < baseTokenLength; i++) {
            // 结算单个交易对资金费
            _settleFunding(trader, baseTokens[i]);
        }
    }

    // 开仓
    /// @inheritdoc IClearingHouse
    function openPosition(OpenPositionParams memory params)
        external
        override
        whenNotPaused
        nonReentrant
        checkDeadline(params.deadline)
        returns (uint256 base, uint256 quote)
    {
        // openPosition() is already published, returned types remain the same (without fee)
        (base, quote, ) = _openPositionFor(_msgSender(), params);
        return (base, quote);
    }

    // 开仓
    /// @inheritdoc IClearingHouse
    function openPositionFor(address trader, OpenPositionParams memory params)
        external
        override
        whenNotPaused
        nonReentrant
        checkDeadline(params.deadline)
        returns (
            uint256 base,
            uint256 quote,
            uint256 fee
        )
    {
        // CH_SHNAOPT: Sender Has No Approval to Open Position for Trader
        require(IDelegateApproval(_delegateApproval).canOpenPositionFor(trader, _msgSender()), "CH_SHNAOPT");

        return _openPositionFor(trader, params);
    }

    // 平仓
    /// @inheritdoc IClearingHouse
    function closePosition(ClosePositionParams calldata params)
        external
        override
        whenNotPaused
        nonReentrant
        checkDeadline(params.deadline)
        returns (uint256 base, uint256 quote)
    {
        // input requirement checks:
        //   baseToken: in Exchange.settleFunding()
        //   sqrtPriceLimitX96: X (this is not for slippage protection)
        //   oppositeAmountBound: in _checkSlippage()
        //   deadline: here
        //   referralCode: X

        // 确保交易对开放
        _checkMarketOpen(params.baseToken);

        address trader = _msgSender();

        // 先结算累计的资金费
        // must settle funding first
        _settleFunding(trader, params.baseToken);

        // 这里是获取用户当前的持仓数量，这个持仓数量只是taker的，不包含maker的
        int256 positionSize = _getTakerPositionSafe(trader, params.baseToken);
        uint256 positionSizeAbs = positionSize.abs();

        // old position is long. when closing, it's baseToQuote && exactInput (sell exact base)
        // old position is short. when closing, it's quoteToBase && exactOutput (buy exact base back)
        bool isBaseToQuote = positionSize > 0;

        // 反向订单去平仓
        IExchange.SwapResponse memory response =
            _openPosition(
                InternalOpenPositionParams({
                    trader: trader,
                    baseToken: params.baseToken,
                    isBaseToQuote: isBaseToQuote,
                    isExactInput: isBaseToQuote,
                    isClose: true,
                    amount: positionSizeAbs,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96
                })
            );

        // 检查滑点
        _checkSlippage(
            InternalCheckSlippageParams({
                isBaseToQuote: isBaseToQuote,
                isExactInput: isBaseToQuote,
                base: response.base,
                quote: response.quote,
                oppositeAmountBound: response.isPartialClose
                    ? params.oppositeAmountBound.mulRatio(response.closedRatio)
                    : params.oppositeAmountBound
            })
        );

        // 邀请奖励相关
        _referredPositionChanged(params.referralCode);

        return (response.base, response.quote);
    }

    // 清算
    /// @inheritdoc IClearingHouse
    function liquidate(
        address trader,
        address baseToken,
        int256 positionSize
    ) external override whenNotPaused nonReentrant {
        _liquidate(trader, baseToken, positionSize);
    }

    // 清算
    /// @inheritdoc IClearingHouse
    function liquidate(address trader, address baseToken) external override whenNotPaused nonReentrant {
        // positionSizeToBeLiquidated = 0 means liquidating as much as possible
        _liquidate(trader, baseToken, 0);
    }

    // 取消未完成的maker订单, 这个是给清算人用的
    /// @inheritdoc IClearingHouse
    function cancelExcessOrders(
        address maker,
        address baseToken,
        bytes32[] calldata orderIds
    ) external override whenNotPaused nonReentrant {
        // input requirement checks:
        //   maker: in _cancelExcessOrders()
        //   baseToken: in Exchange.settleFunding()
        //   orderIds: in OrderBook.removeLiquidityByIds()

        _cancelExcessOrders(maker, baseToken, orderIds);
    }

    // 取消未完成的maker订单, 这个是给清算人用的
    /// @inheritdoc IClearingHouse
    function cancelAllExcessOrders(address maker, address baseToken) external override whenNotPaused nonReentrant {
        // input requirement checks:
        //   maker: in _cancelExcessOrders()
        //   baseToken: in Exchange.settleFunding()
        //   orderIds: in OrderBook.removeLiquidityByIds()

        _cancelExcessOrders(maker, baseToken, _getOpenOrderIds(maker, baseToken));
    }

    /// @inheritdoc IClearingHouse
    function quitMarket(address trader, address baseToken)
        external
        override
        nonReentrant
        returns (uint256 base, uint256 quote)
    {
        // CH_MNC: Market not closed
        require(IBaseToken(baseToken).isClosed(), "CH_MNC");

        _settleFunding(trader, baseToken);

        bytes32[] memory orderIds = _getOpenOrderIds(trader, baseToken);

        // remove all orders in internal function
        if (orderIds.length > 0) {
            _removeAllLiquidity(trader, baseToken, orderIds);
        }

        int256 positionSize = _getTakerPosition(trader, baseToken);

        // if position is 0, no need to do settlement accounting
        if (positionSize == 0) {
            return (0, 0);
        }

        (int256 positionNotional, int256 openNotional, int256 realizedPnl, uint256 closedPrice) =
            IAccountBalance(_accountBalance).settlePositionInClosedMarket(trader, baseToken);

        emit PositionClosed(trader, baseToken, positionSize, positionNotional, openNotional, realizedPnl, closedPrice);

        _settleBadDebt(trader);

        return (positionSize.abs(), positionNotional.abs());
    }

    // uniswapV3 mint回调，这里是直接mint virtual token
    /// @inheritdoc IUniswapV3MintCallback
    /// @dev namings here follow Uniswap's convention
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external override {
        // input requirement checks:
        //   amount0Owed: here
        //   amount1Owed: here
        //   data: X

        // For caller validation purposes it would be more efficient and more reliable to use
        // "msg.sender" instead of "_msgSender()" as contracts never call each other through GSN.
        // not orderbook
        require(msg.sender == _orderBook, "CH_NOB");

        IOrderBook.MintCallbackData memory callbackData = abi.decode(data, (IOrderBook.MintCallbackData));

        if (amount0Owed > 0) {
            address token = IUniswapV3Pool(callbackData.pool).token0();
            _requireTransfer(token, callbackData.pool, amount0Owed);
        }
        if (amount1Owed > 0) {
            address token = IUniswapV3Pool(callbackData.pool).token1();
            _requireTransfer(token, callbackData.pool, amount1Owed);
        }
    }

    // uniswapV3 swap回调
    /// @inheritdoc IUniswapV3SwapCallback
    /// @dev namings here follow Uniswap's convention
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        // input requirement checks:
        //   amount0Delta: here
        //   amount1Delta: here
        //   data: X
        // For caller validation purposes it would be more efficient and more reliable to use
        // "msg.sender" instead of "_msgSender()" as contracts never call each other through GSN.
        require(msg.sender == _exchange, "CH_OE");

        // swaps entirely within 0-liquidity regions are not supported -> 0 swap is forbidden
        // CH_F0S: forbidden 0 swap
        require((amount0Delta > 0 && amount1Delta < 0) || (amount0Delta < 0 && amount1Delta > 0), "CH_F0S");

        IExchange.SwapCallbackData memory callbackData = abi.decode(data, (IExchange.SwapCallbackData));
        IUniswapV3Pool uniswapV3Pool = IUniswapV3Pool(callbackData.pool);

        // amount0Delta & amount1Delta are guaranteed to be positive when being the amount to be paid
        (address token, uint256 amountToPay) =
            amount0Delta > 0
                ? (uniswapV3Pool.token0(), uint256(amount0Delta))
                : (uniswapV3Pool.token1(), uint256(amount1Delta));

        // swap
        _requireTransfer(token, callbackData.pool, amountToPay);
    }

    //
    // EXTERNAL VIEW
    //

    /// @inheritdoc IClearingHouse
    function getQuoteToken() external view override returns (address) {
        return _quoteToken;
    }

    /// @inheritdoc IClearingHouse
    function getUniswapV3Factory() external view override returns (address) {
        return _uniswapV3Factory;
    }

    /// @inheritdoc IClearingHouse
    function getClearingHouseConfig() external view override returns (address) {
        return _clearingHouseConfig;
    }

    /// @inheritdoc IClearingHouse
    function getVault() external view override returns (address) {
        return _vault;
    }

    /// @inheritdoc IClearingHouse
    function getExchange() external view override returns (address) {
        return _exchange;
    }

    /// @inheritdoc IClearingHouse
    function getOrderBook() external view override returns (address) {
        return _orderBook;
    }

    /// @inheritdoc IClearingHouse
    function getAccountBalance() external view override returns (address) {
        return _accountBalance;
    }

    /// @inheritdoc IClearingHouse
    function getInsuranceFund() external view override returns (address) {
        return _insuranceFund;
    }

    /// @inheritdoc IClearingHouse
    function getDelegateApproval() external view override returns (address) {
        return _delegateApproval;
    }

    /// @inheritdoc IClearingHouse
    function getAccountValue(address trader) public view override returns (int256) {
        return IVault(_vault).getAccountValue(trader).parseSettlementToken(_settlementTokenDecimals);
    }

    //
    // INTERNAL NON-VIEW
    //

    function _requireTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        // CH_TF: Transfer failed
        require(IERC20Metadata(token).transfer(to, amount), "CH_TF");
    }

    // 清算
    function _liquidate(
        address trader,
        address baseToken,
        int256 positionSizeToBeLiquidated
    ) internal {
        _checkMarketOpen(baseToken);

        // CH_CLWTISO: cannot liquidate when there is still order
        require(!IAccountBalance(_accountBalance).hasOrder(trader), "CH_CLWTISO");

        // CH_EAV: enough account value
        require(_isLiquidatable(trader), "CH_EAV");

        // 获取当前持仓大小
        int256 positionSize = _getTakerPositionSafe(trader, baseToken);

        // CH_WLD: wrong liquidation direction
        require(positionSize.mul(positionSizeToBeLiquidated) >= 0, "CH_WLD");

        address liquidator = _msgSender();

        _registerBaseToken(liquidator, baseToken);

        // 计算trader 和 liquidator的资金费
        // must settle funding first
        _settleFunding(trader, baseToken);
        _settleFunding(liquidator, baseToken);

        // 获取当前trader的价值
        int256 accountValue = getAccountValue(trader);

        // trader's position is closed at index price and pnl realized

        // 计算被清算的仓位大小，以及名义价值
        (int256 liquidatedPositionSize, int256 liquidatedPositionNotional) =
            _getLiquidatedPositionSizeAndNotional(trader, baseToken, accountValue, positionSizeToBeLiquidated);
        _modifyPositionAndRealizePnl(trader, baseToken, liquidatedPositionSize, liquidatedPositionNotional, 0, 0);

        // 计算清算罚金
        // trader pays liquidation penalty
        uint256 liquidationPenalty = liquidatedPositionNotional.abs().mulRatio(_getLiquidationPenaltyRatio());
        _modifyOwedRealizedPnl(trader, liquidationPenalty.neg256());

        address insuranceFund = _insuranceFund;

        // if there is bad debt, liquidation fees all go to liquidator; otherwise, split between liquidator & IF

        // 清算罚金一半给清算人，一半给风险保证金，如果穿仓，那么清算人盈利由风险保证金支付
        uint256 liquidationFeeToLiquidator = liquidationPenalty.div(2);
        uint256 liquidationFeeToIF;
        if (accountValue < 0) {
            liquidationFeeToLiquidator = liquidationPenalty;
        } else {
            liquidationFeeToIF = liquidationPenalty.sub(liquidationFeeToLiquidator);
            _modifyOwedRealizedPnl(insuranceFund, liquidationFeeToIF.toInt256());
        }

        // 检查穿仓情况
        // assume there is no longer any unsettled bad debt in the system
        // (so that true IF capacity = accountValue(IF) + USDC.balanceOf(IF))
        // if trader's account value becomes negative, the amount is the bad debt IF must have enough capacity to cover
        {
            int256 accountValueAfterLiquidationX10_18 = getAccountValue(trader);

            if (accountValueAfterLiquidationX10_18 < 0) {
                int256 insuranceFundCapacityX10_18 =
                    IInsuranceFund(insuranceFund).getInsuranceFundCapacity().parseSettlementToken(
                        _settlementTokenDecimals
                    );

                // CH_IIC: insufficient insuranceFund capacity
                require(insuranceFundCapacityX10_18 >= accountValueAfterLiquidationX10_18.neg256(), "CH_IIC");
            }
        }

        // 在这里更新清算人的仓位

        // liquidator opens a position with liquidationFeeToLiquidator as a discount
        // liquidator's openNotional = -liquidatedPositionNotional + liquidationFeeToLiquidator
        int256 liquidatorExchangedPositionSize = liquidatedPositionSize.neg256();
        int256 liquidatorExchangedPositionNotional =
            liquidatedPositionNotional.neg256().add(liquidationFeeToLiquidator.toInt256());
        // note that this function will realize pnl if it's reducing liquidator's existing position size
        // 更新清算人仓位和PNL
        _modifyPositionAndRealizePnl(
            liquidator,
            baseToken,
            liquidatorExchangedPositionSize, // exchangedPositionSize
            liquidatorExchangedPositionNotional, // exchangedPositionNotional
            0, // makerFee
            0 // takerFee
        );

        _requireEnoughFreeCollateral(liquidator);

        emit PositionLiquidated(
            trader,
            baseToken,
            liquidatedPositionNotional.abs(), // positionNotional
            liquidatedPositionSize.abs(), // positionSize
            liquidationPenalty,
            liquidator
        );

        // 结算债务
        _settleBadDebt(trader);
    }

    /// @dev Calculate how much profit/loss we should realize,
    ///      The profit/loss is calculated by exchangedPositionSize/exchangedPositionNotional amount
    ///      and existing taker's base/quote amount.
    function _modifyPositionAndRealizePnl(
        address trader,
        address baseToken,
        int256 exchangedPositionSize,
        int256 exchangedPositionNotional,
        uint256 makerFee,
        uint256 takerFee
    ) internal {
        int256 realizedPnl;
        if (exchangedPositionSize != 0) {
            realizedPnl = IExchange(_exchange).getPnlToBeRealized(
                IExchange.RealizePnlParams({
                    trader: trader,
                    baseToken: baseToken,
                    base: exchangedPositionSize,
                    quote: exchangedPositionNotional
                })
            );
        }

        // realizedPnl is realized here
        // will deregister baseToken if there is no position
        _settleBalanceAndDeregister(
            trader,
            baseToken,
            exchangedPositionSize, // takerBase
            exchangedPositionNotional, // takerQuote
            realizedPnl,
            makerFee.toInt256()
        );

        _emitPositionChanged(
            trader,
            baseToken,
            exchangedPositionSize,
            exchangedPositionNotional,
            takerFee, // fee
            _getTakerOpenNotional(trader, baseToken), // openNotional
            realizedPnl,
            _getSqrtMarketTwapX96(baseToken) // sqrtPriceAfterX96: no swap, so market price didn't change
        );
    }

    // 取消未完成的maker订单, 这个是给清算人用的
    /// @dev only cancel open orders if there are not enough free collateral with mmRatio
    /// or account is able to being liquidated.
    function _cancelExcessOrders(
        address maker,
        address baseToken,
        bytes32[] memory orderIds
    ) internal {
        _checkMarketOpen(baseToken);

        if (orderIds.length == 0) {
            return;
        }

        // CH_NEXO: not excess orders
        // 如果仓位待清算 或者保证金足够，那就不允许取消
        require(
            (_getFreeCollateralByRatio(maker, IClearingHouseConfig(_clearingHouseConfig).getMmRatio()) < 0) ||
                _isLiquidatable(maker),
            "CH_NEXO"
        );

        // must settle funding first
        _settleFunding(maker, baseToken);

        // 移除所有流动性, 将maker仓位转换为永久仓位，一边进行下一步清算

        // remove all orders in internal function
        _removeAllLiquidity(maker, baseToken, orderIds);
    }

    function _removeAllLiquidity(
        address maker,
        address baseToken,
        bytes32[] memory orderIds
    ) internal {
        IOrderBook.RemoveLiquidityResponse memory removeLiquidityResponse;

        uint256 length = orderIds.length;
        for (uint256 i = 0; i < length; i++) {
            OpenOrder.Info memory order = IOrderBook(_orderBook).getOpenOrderById(orderIds[i]);

            // CH_ONBM: order is not belongs to this maker
            require(
                OpenOrder.calcOrderKey(maker, baseToken, order.lowerTick, order.upperTick) == orderIds[i],
                "CH_ONBM"
            );

            IOrderBook.RemoveLiquidityResponse memory response =
                _removeLiquidity(
                    IOrderBook.RemoveLiquidityParams({
                        maker: maker,
                        baseToken: baseToken,
                        lowerTick: order.lowerTick,
                        upperTick: order.upperTick,
                        liquidity: order.liquidity
                    })
                );

            removeLiquidityResponse.base = removeLiquidityResponse.base.add(response.base);
            removeLiquidityResponse.quote = removeLiquidityResponse.quote.add(response.quote);
            removeLiquidityResponse.fee = removeLiquidityResponse.fee.add(response.fee);
            removeLiquidityResponse.takerBase = removeLiquidityResponse.takerBase.add(response.takerBase);
            removeLiquidityResponse.takerQuote = removeLiquidityResponse.takerQuote.add(response.takerQuote);

            _emitLiquidityChanged(
                maker,
                baseToken,
                _quoteToken,
                order.lowerTick,
                order.upperTick,
                response.base.neg256(),
                response.quote.neg256(),
                order.liquidity.neg128(),
                response.fee
            );
        }

        _modifyPositionAndRealizePnl(
            maker,
            baseToken,
            removeLiquidityResponse.takerBase,
            removeLiquidityResponse.takerQuote,
            removeLiquidityResponse.fee,
            0
        );
    }

    /// @dev explainer diagram for the relationship between exchangedPositionNotional, fee and openNotional:
    ///      https://www.figma.com/file/xuue5qGH4RalX7uAbbzgP3/swap-accounting-and-events
    function _openPosition(InternalOpenPositionParams memory params) internal returns (IExchange.SwapResponse memory) {
        // 撮合前先获取仓位大小
        int256 takerPositionSizeBeforeSwap =
            IAccountBalance(_accountBalance).getTakerPositionSize(params.trader, params.baseToken);

        // 开始撮合
        IExchange.SwapResponse memory response =
            IExchange(_exchange).swap(
                IExchange.SwapParams({
                    trader: params.trader,
                    baseToken: params.baseToken,
                    isBaseToQuote: params.isBaseToQuote,
                    isExactInput: params.isExactInput,
                    isClose: params.isClose,
                    amount: params.amount,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96
                })
            );

        // 修改风险保证金
        _modifyOwedRealizedPnl(_insuranceFund, response.insuranceFundFee.toInt256());

        // 结算资金
        // examples:
        // https://www.figma.com/file/xuue5qGH4RalX7uAbbzgP3/swap-accounting-and-events?node-id=0%3A1
        _settleBalanceAndDeregister(
            params.trader,
            params.baseToken,
            response.exchangedPositionSize, // base
            response.exchangedPositionNotional.sub(response.fee.toInt256()), // quote
            response.pnlToBeRealized,
            0
        );

        if (takerPositionSizeBeforeSwap != 0) {
            int256 takerPositionSizeAfterSwap =
                IAccountBalance(_accountBalance).getTakerPositionSize(params.trader, params.baseToken);
            bool hasBecameInversePosition =
                _isReversingPosition(takerPositionSizeBeforeSwap, takerPositionSizeAfterSwap);
            bool isReducingPosition = takerPositionSizeBeforeSwap < 0 != params.isBaseToQuote;

            if (isReducingPosition && !hasBecameInversePosition) {
                // check margin free collateral by mmRatio after swap (reducing and closing position)
                // trader cannot reduce/close position if the free collateral by mmRatio is not enough
                // for preventing bad debt and not enough liquidation penalty fee
                // only liquidator can take over this position

                // CH_NEFCM: not enough free collateral by mmRatio
                require(
                    (_getFreeCollateralByRatio(
                        params.trader,
                        IClearingHouseConfig(_clearingHouseConfig).getMmRatio()
                    ) >= 0),
                    "CH_NEFCM"
                );
            } else {
                // check margin free collateral by imRatio after swap (increasing and reversing position)
                _requireEnoughFreeCollateral(params.trader);
            }
        } else {
            // check margin free collateral by imRatio after swap (opening a position)
            _requireEnoughFreeCollateral(params.trader);
        }

        // openNotional will be zero if baseToken is deregistered from trader's token list.
        int256 openNotional = _getTakerOpenNotional(params.trader, params.baseToken);
        _emitPositionChanged(
            params.trader, // 用户地址
            params.baseToken, // 交易对
            response.exchangedPositionSize, // 本次开仓加仓大小
            response.exchangedPositionNotional, // 增加的本金数量
            response.fee, // 交易手续费
            openNotional, // 开仓加仓后本金的数量
            response.pnlToBeRealized, // realizedPnl 已实现盈亏，如果是平仓的话
            response.sqrtPriceAfterX96 // 成交后 池子的价格
        );

        return response;
    }

    function _openPositionFor(address trader, OpenPositionParams memory params)
        internal
        returns (
            uint256 base,
            uint256 quote,
            uint256 fee
        )
    {
        // input requirement checks:
        //   baseToken: in Exchange.settleFunding()
        //   isBaseToQuote & isExactInput: X
        //   amount: in UniswapV3Pool.swap()
        //   oppositeAmountBound: in _checkSlippage()
        //   deadline: here
        //   sqrtPriceLimitX96: X (this is not for slippage protection)
        //   referralCode: X

        _checkMarketOpen(params.baseToken);

        // register token if it's the first time
        _registerBaseToken(trader, params.baseToken);

        // must settle funding first
        _settleFunding(trader, params.baseToken);

        IExchange.SwapResponse memory response =
            _openPosition(
                InternalOpenPositionParams({
                    trader: trader,
                    baseToken: params.baseToken,
                    isBaseToQuote: params.isBaseToQuote,
                    isExactInput: params.isExactInput,
                    amount: params.amount,
                    isClose: false,
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96
                })
            );

        // 检查滑点
        _checkSlippage(
            InternalCheckSlippageParams({
                isBaseToQuote: params.isBaseToQuote,
                isExactInput: params.isExactInput,
                base: response.base,
                quote: response.quote,
                oppositeAmountBound: params.oppositeAmountBound
            })
        );

        _referredPositionChanged(params.referralCode);

        return (response.base, response.quote, response.fee);
    }

    /// @dev Remove maker's liquidity.
    function _removeLiquidity(IOrderBook.RemoveLiquidityParams memory params)
        internal
        returns (IOrderBook.RemoveLiquidityResponse memory)
    {
        return IOrderBook(_orderBook).removeLiquidity(params);
    }

    /// @dev Settle trader's funding payment to his/her realized pnl.
    function _settleFunding(address trader, address baseToken)
        internal
        returns (Funding.Growth memory fundingGrowthGlobal)
    {
        int256 fundingPayment;
        (fundingPayment, fundingGrowthGlobal) = IExchange(_exchange).settleFunding(trader, baseToken);

        if (fundingPayment != 0) {
            _modifyOwedRealizedPnl(trader, fundingPayment.neg256());
            emit FundingPaymentSettled(trader, baseToken, fundingPayment);
        }

        IAccountBalance(_accountBalance).updateTwPremiumGrowthGlobal(
            trader,
            baseToken,
            fundingGrowthGlobal.twPremiumX96
        );
        return fundingGrowthGlobal;
    }

    function _registerBaseToken(address trader, address baseToken) internal {
        IAccountBalance(_accountBalance).registerBaseToken(trader, baseToken);
    }

    function _modifyOwedRealizedPnl(address trader, int256 amount) internal {
        IAccountBalance(_accountBalance).modifyOwedRealizedPnl(trader, amount);
    }

    function _settleBalanceAndDeregister(
        address trader,
        address baseToken,
        int256 takerBase,
        int256 takerQuote,
        int256 realizedPnl,
        int256 makerFee
    ) internal {
        IAccountBalance(_accountBalance).settleBalanceAndDeregister(
            trader,
            baseToken,
            takerBase,
            takerQuote,
            realizedPnl,
            makerFee
        );
    }

    function _emitPositionChanged(
        address trader,
        address baseToken,
        int256 exchangedPositionSize,
        int256 exchangedPositionNotional,
        uint256 fee,
        int256 openNotional,
        int256 realizedPnl,
        uint256 sqrtPriceAfterX96
    ) internal {
        emit PositionChanged(
            trader,
            baseToken,
            exchangedPositionSize,
            exchangedPositionNotional,
            fee,
            openNotional,
            realizedPnl,
            sqrtPriceAfterX96
        );
    }

    function _emitLiquidityChanged(
        address maker,
        address baseToken,
        address quoteToken,
        int24 lowerTick,
        int24 upperTick,
        int256 base,
        int256 quote,
        int128 liquidity,
        uint256 quoteFee
    ) internal {
        emit LiquidityChanged(maker, baseToken, quoteToken, lowerTick, upperTick, base, quote, liquidity, quoteFee);
    }

    function _referredPositionChanged(bytes32 referralCode) internal {
        if (referralCode != 0) {
            emit ReferredPositionChanged(referralCode);
        }
    }

    function _settleBadDebt(address trader) internal {
        IVault(_vault).settleBadDebt(trader);
    }

    //
    // INTERNAL VIEW
    //

    /// @inheritdoc BaseRelayRecipient
    function _msgSender() internal view override(BaseRelayRecipient, OwnerPausable) returns (address payable) {
        return super._msgSender();
    }

    /// @inheritdoc BaseRelayRecipient
    function _msgData() internal view override(BaseRelayRecipient, OwnerPausable) returns (bytes memory) {
        return super._msgData();
    }

    function _getTakerOpenNotional(address trader, address baseToken) internal view returns (int256) {
        return IAccountBalance(_accountBalance).getTakerOpenNotional(trader, baseToken);
    }

    function _getTakerPositionSafe(address trader, address baseToken) internal view returns (int256) {
        int256 takerPositionSize = _getTakerPosition(trader, baseToken);
        // CH_PSZ: position size is zero
        require(takerPositionSize != 0, "CH_PSZ");
        return takerPositionSize;
    }

    function _getTakerPosition(address trader, address baseToken) internal view returns (int256) {
        return IAccountBalance(_accountBalance).getTakerPositionSize(trader, baseToken);
    }

    function _getFreeCollateralByRatio(address trader, uint24 ratio) internal view returns (int256) {
        return IVault(_vault).getFreeCollateralByRatio(trader, ratio);
    }

    function _getSqrtMarketTwapX96(address baseToken) internal view returns (uint160) {
        return IExchange(_exchange).getSqrtMarketTwapX96(baseToken, 0);
    }

    function _getMarginRequirementForLiquidation(address trader) internal view returns (int256) {
        return IAccountBalance(_accountBalance).getMarginRequirementForLiquidation(trader);
    }

    function _getLiquidationPenaltyRatio() internal view returns (uint24) {
        return IClearingHouseConfig(_clearingHouseConfig).getLiquidationPenaltyRatio();
    }

    function _getTotalAbsPositionValue(address trader) internal view returns (uint256) {
        return IAccountBalance(_accountBalance).getTotalAbsPositionValue(trader);
    }

    function _getOpenOrderIds(address maker, address baseToken) internal view returns (bytes32[] memory) {
        return IOrderBook(_orderBook).getOpenOrderIds(maker, baseToken);
    }

    /// @dev liquidation condition:
    ///      accountValue < sum(abs(positionValue_by_market)) * mmRatio = totalMinimumMarginRequirement
    function _isLiquidatable(address trader) internal view returns (bool) {
        return getAccountValue(trader) < _getMarginRequirementForLiquidation(trader);
    }

    /// @param positionSizeToBeLiquidated its direction should be the same as taker's existing position
    function _getLiquidatedPositionSizeAndNotional(
        address trader,
        address baseToken,
        int256 accountValue,
        int256 positionSizeToBeLiquidated
    ) internal view returns (int256, int256) {
        int256 maxLiquidatablePositionSize =
            IAccountBalance(_accountBalance).getLiquidatablePositionSize(trader, baseToken, accountValue);

        if (positionSizeToBeLiquidated.abs() > maxLiquidatablePositionSize.abs() || positionSizeToBeLiquidated == 0) {
            positionSizeToBeLiquidated = maxLiquidatablePositionSize;
        }

        int256 liquidatedPositionSize = positionSizeToBeLiquidated.neg256();
        int256 liquidatedPositionNotional =
            positionSizeToBeLiquidated.mulDiv(
                IAccountBalance(_accountBalance).getMarkPrice(baseToken).toInt256(),
                1e18
            );

        return (liquidatedPositionSize, liquidatedPositionNotional);
    }

    function _requireEnoughFreeCollateral(address trader) internal view {
        // CH_NEFCI: not enough free collateral by imRatio
        require(
            _getFreeCollateralByRatio(trader, IClearingHouseConfig(_clearingHouseConfig).getImRatio()) >= 0,
            "CH_NEFCI"
        );
    }

    function _checkMarketOpen(address baseToken) internal view {
        // CH_MNO: Market not opened
        require(IBaseToken(baseToken).isOpen(), "CH_MNO");
    }

    function _isContract(address contractArg, string memory errorMsg) internal view {
        require(contractArg.isContract(), errorMsg);
    }

    //
    // INTERNAL PURE
    //

    function _checkSlippage(InternalCheckSlippageParams memory params) internal pure {
        // skip when params.oppositeAmountBound is zero
        if (params.oppositeAmountBound == 0) {
            return;
        }

        // B2Q + exact input, want more output quote as possible, so we set a lower bound of output quote
        // B2Q + exact output, want less input base as possible, so we set a upper bound of input base
        // Q2B + exact input, want more output base as possible, so we set a lower bound of output base
        // Q2B + exact output, want less input quote as possible, so we set a upper bound of input quote
        if (params.isBaseToQuote) {
            if (params.isExactInput) {
                // too little received when short
                require(params.quote >= params.oppositeAmountBound, "CH_TLRS");
            } else {
                // too much requested when short
                require(params.base <= params.oppositeAmountBound, "CH_TMRS");
            }
        } else {
            if (params.isExactInput) {
                // too little received when long
                require(params.base >= params.oppositeAmountBound, "CH_TLRL");
            } else {
                // too much requested when long
                require(params.quote <= params.oppositeAmountBound, "CH_TMRL");
            }
        }
    }

    function _checkSlippageAfterLiquidityChange(
        uint256 base,
        uint256 minBase,
        uint256 quote,
        uint256 minQuote
    ) internal pure {
        // CH_PSCF: price slippage check fails
        require(base >= minBase && quote >= minQuote, "CH_PSCF");
    }

    function _isReversingPosition(int256 sizeBefore, int256 sizeAfter) internal pure returns (bool) {
        return !(sizeAfter == 0 || sizeBefore == 0) && sizeBefore ^ sizeAfter < 0;
    }
}
