import { MockContract } from "@eth-optimism/smock"
import { expect } from "chai"
import { parseEther, parseUnits } from "ethers/lib/utils"
import { ethers, waffle } from "hardhat"
import {
    BaseToken,
    Exchange,
    ExchangeRegistry,
    OrderBook,
    QuoteToken,
    TestClearingHouse,
    TestERC20,
    UniswapV3Pool,
    Vault,
} from "../../typechain"
import { deposit } from "../helper/token"
import { encodePriceSqrt } from "../shared/utilities"
import { BaseQuoteOrdering, createClearingHouseFixture } from "./fixtures"

describe("ClearingHouse customized fee", () => {
    const [admin, maker, taker, taker2] = waffle.provider.getWallets()
    const loadFixture: ReturnType<typeof waffle.createFixtureLoader> = waffle.createFixtureLoader([admin])
    let clearingHouse: TestClearingHouse
    let exchangeRegistry: ExchangeRegistry
    let exchange: Exchange
    let orderBook: OrderBook
    let vault: Vault
    let collateral: TestERC20
    let baseToken: BaseToken
    let quoteToken: QuoteToken
    let pool: UniswapV3Pool
    let mockedBaseAggregator: MockContract
    let collateralDecimals: number
    const lowerTick: number = 0
    const upperTick: number = 100000

    beforeEach(async () => {
        const _clearingHouseFixture = await loadFixture(createClearingHouseFixture(BaseQuoteOrdering.BASE_0_QUOTE_1))
        clearingHouse = _clearingHouseFixture.clearingHouse as TestClearingHouse
        orderBook = _clearingHouseFixture.orderBook
        exchange = _clearingHouseFixture.exchange
        exchangeRegistry = _clearingHouseFixture.exchangeRegistry
        vault = _clearingHouseFixture.vault
        collateral = _clearingHouseFixture.USDC
        baseToken = _clearingHouseFixture.baseToken
        quoteToken = _clearingHouseFixture.quoteToken
        mockedBaseAggregator = _clearingHouseFixture.mockedBaseAggregator
        pool = _clearingHouseFixture.pool
        collateralDecimals = await collateral.decimals()

        mockedBaseAggregator.smocked.latestRoundData.will.return.with(async () => {
            return [0, parseUnits("100", 6), 0, 0, 0]
        })

        await pool.initialize(encodePriceSqrt("151.373306858723226652", "1")) // tick = 50200 (1.0001^50200 = 151.373306858723226652)
        // the initial number of oracle can be recorded is 1; thus, have to expand it
        await pool.increaseObservationCardinalityNext((2 ^ 16) - 1)

        // add pool after it's initialized
        await exchangeRegistry.addPool(baseToken.address, 10000)

        // prepare collateral for maker
        const makerCollateralAmount = parseUnits("1000000", collateralDecimals)
        await collateral.mint(maker.address, makerCollateralAmount)
        await deposit(maker, vault, 1000000, collateral)

        // maker add liquidity
        await clearingHouse.connect(maker).addLiquidity({
            baseToken: baseToken.address,
            base: parseEther("65.943787"),
            quote: parseEther("10000"),
            lowerTick,
            upperTick,
            minBase: 0,
            minQuote: 0,
            deadline: ethers.constants.MaxUint256,
        })

        // maker
        //   pool.base = 65.9437860798
        //   pool.quote = 10000
        //   liquidity = 884.6906588359
        //   virtual base liquidity = 884.6906588359 / sqrt(151.373306858723226652) = 71.9062751863
        //   virtual quote liquidity = 884.6906588359 * sqrt(151.373306858723226652) = 10884.6906588362

        // prepare collateral for taker
        const takerCollateral = parseUnits("1000", collateralDecimals)
        await collateral.mint(taker.address, takerCollateral)
        await collateral.connect(taker).approve(clearingHouse.address, takerCollateral)
        await collateral.mint(taker2.address, takerCollateral)
        await collateral.connect(taker2).approve(clearingHouse.address, takerCollateral)
    })

    describe("CH fee ratio(2%) > uniswap pool fee ratio(1%)", async () => {
        beforeEach(async () => {
            // set fee ratio to 2%
            await exchange.setFeeRatio(baseToken.address, 20000)
        })

        describe("taker open position from zero", async () => {
            beforeEach(async () => {
                await deposit(taker, vault, 1000, collateral)
            })

            it("long and exact in", async () => {
                // taker swap 1 USD for ? ETH
                await expect(
                    clearingHouse.connect(taker).openPosition({
                        baseToken: baseToken.address,
                        isBaseToQuote: false,
                        isExactInput: true,
                        oppositeAmountBound: 0,
                        amount: parseEther("1"),
                        sqrtPriceLimitX96: 0,
                        deadline: ethers.constants.MaxUint256,
                        referralCode: ethers.constants.HashZero,
                    }),
                )
                    .to.emit(clearingHouse, "PositionChanged")
                    .withArgs(
                        taker.address, // trader
                        baseToken.address, // baseToken
                        "6473478014450606", // exchangedPositionSize
                        parseEther("-0.98"), // exchangedPositionNotional
                        parseEther("0.02"), // fee = 1 * 0.02
                        parseEther("-1"), // openNotional
                        parseEther("0"), // realizedPnl
                    )

                expect(await clearingHouse.getPositionSize(taker.address, baseToken.address)).to.eq("6473478014450606")

                const fee = (
                    await clearingHouse.connect(maker).callStatic.removeLiquidity({
                        baseToken: baseToken.address,
                        lowerTick: lowerTick,
                        upperTick: upperTick,
                        liquidity: 0,
                        minBase: 0,
                        minQuote: 0,
                        deadline: ethers.constants.MaxUint256,
                    })
                ).fee
                expect(fee).to.be.closeTo(parseEther("0.02"), 1)
            })

            it("long and exact out", async () => {
                // taker swap ? USD for 1 ETH -> quote to base -> fee is charged before swapping
                // exchanged notional = 71.9062751863 * 10884.6906588362 / (71.9062751863 - 1) - 10884.6906588362 = 153.508143394
                // (qr * (1 - x)) * y / (1 - y)
                //   taker fee = 153.508143394 / 0.98 * 0.02 = 3.13281925
                await expect(
                    clearingHouse.connect(taker).openPosition({
                        baseToken: baseToken.address,
                        isBaseToQuote: false,
                        isExactInput: false,
                        oppositeAmountBound: ethers.constants.MaxUint256,
                        amount: parseEther("1"),
                        sqrtPriceLimitX96: 0,
                        deadline: ethers.constants.MaxUint256,
                        referralCode: ethers.constants.HashZero,
                    }),
                )
                    .to.emit(clearingHouse, "PositionChanged")
                    .withArgs(
                        taker.address, // trader
                        baseToken.address, // baseToken
                        parseEther("1"), // exchangedPositionSize
                        "-153508143394151325059", // exchangedPositionNotional
                        "3132819252941863777", // fee
                        "-156640962647093188836", // openNotional
                        parseEther("0"), // realizedPnl
                    )
                expect(await clearingHouse.getPositionSize(taker.address, baseToken.address)).to.eq(parseEther("1"))

                const fee = (
                    await clearingHouse.connect(maker).callStatic.removeLiquidity({
                        baseToken: baseToken.address,
                        lowerTick: lowerTick,
                        upperTick: upperTick,
                        liquidity: 0,
                        minBase: 0,
                        minQuote: 0,
                        deadline: ethers.constants.MaxUint256,
                    })
                ).fee
                expect(fee).to.be.closeTo(parseEther("3.132819252941863777"), 1)
            })

            it("short and exact in", async () => {
                // taker swap ? USD for 1 ETH -> base to quote -> fee is included in exchangedNotional
                //   taker exchangedNotional = 10884.6906588362 - 71.9062751863 * 10884.6906588362 / (71.9062751863 + 1) = 149.2970341856
                //   taker fee = 149.2970341856 * 0.02 = 2.98594068371

                // taker swap 1 ETH for ? USD
                await expect(
                    clearingHouse.connect(taker).openPosition({
                        baseToken: baseToken.address,
                        isBaseToQuote: true,
                        isExactInput: true,
                        oppositeAmountBound: 0,
                        amount: parseEther("1"),
                        sqrtPriceLimitX96: 0,
                        deadline: ethers.constants.MaxUint256,
                        referralCode: ethers.constants.HashZero,
                    }),
                )
                    .to.emit(clearingHouse, "PositionChanged")
                    .withArgs(
                        taker.address, // trader
                        baseToken.address, // baseToken
                        parseEther("-1"), // exchangedPositionSize
                        parseEther("149.297034185732877727"), // exchangedPositionNotional
                        parseEther("2.985940683714657555"), // fee: 149.297034185732877727 * 0.02 = 2.985940683714657555
                        parseEther("146.311093502018220172"), // openNotional
                        parseEther("0"), // realizedPnl
                    )
                expect(await clearingHouse.getPositionSize(taker.address, baseToken.address)).to.eq(parseEther("-1"))

                const fee = (
                    await clearingHouse.connect(maker).callStatic.removeLiquidity({
                        baseToken: baseToken.address,
                        lowerTick: lowerTick,
                        upperTick: upperTick,
                        liquidity: 0,
                        minBase: 0,
                        minQuote: 0,
                        deadline: ethers.constants.MaxUint256,
                    })
                ).fee
                expect(fee).to.be.closeTo(parseEther("2.985940683714657555"), 2)
            })

            it("short and exact out", async () => {
                // taker swap ? ETH for 1 USD
                await expect(
                    clearingHouse.connect(taker).openPosition({
                        baseToken: baseToken.address,
                        isBaseToQuote: true,
                        isExactInput: false,
                        oppositeAmountBound: ethers.constants.MaxUint256,
                        amount: parseEther("1"),
                        sqrtPriceLimitX96: 0,
                        deadline: ethers.constants.MaxUint256,
                        referralCode: ethers.constants.HashZero,
                    }),
                )
                    .to.emit(clearingHouse, "PositionChanged")
                    .withArgs(
                        taker.address, // trader
                        baseToken.address, // baseToken
                        parseEther("-0.006741636644634247"), // exchangedPositionSize
                        parseEther("1.020408163265306123"), // exchangedPositionNotional = 1 / 0.98
                        parseEther("0.020408163265306123"), // fee: 1 / 0.98 * 0.02
                        parseEther("1"), // openNotional
                        parseEther("0"), // realizedPnl
                    )
                expect(await clearingHouse.getPositionSize(taker.address, baseToken.address)).to.eq(
                    parseEther("-0.006741636644634247"),
                )

                const fee = (
                    await clearingHouse.connect(maker).callStatic.removeLiquidity({
                        baseToken: baseToken.address,
                        lowerTick: lowerTick,
                        upperTick: upperTick,
                        liquidity: 0,
                        minBase: 0,
                        minQuote: 0,
                        deadline: ethers.constants.MaxUint256,
                    })
                ).fee
                expect(fee).to.be.closeTo(parseEther("0.020408163265306123"), 1)
            })
        })

        describe("opening long first then", () => {
            beforeEach(async () => {
                await deposit(taker, vault, 1000, collateral)
                await deposit(taker2, vault, 1000, collateral)

                // 71.9062751863 - 884.6906588359 ^ 2  / (10884.6906588362 + 2 * 0.99) = 0.01307786649
                // taker swap 2 USD for 0.01307786649 ETH
                await clearingHouse.connect(taker).openPosition({
                    baseToken: baseToken.address,
                    isBaseToQuote: false,
                    isExactInput: true,
                    oppositeAmountBound: 0,
                    amount: parseEther("2"),
                    sqrtPriceLimitX96: 0,
                    deadline: ethers.constants.MaxUint256,
                    referralCode: ethers.constants.HashZero,
                })

                // virtual base liquidity = 71.9062751863 - 0.01307786649 = 71.8931973198
                // virtual quote liquidity = 10884.6906588362 + 2 * 0.99 = 10886.6706588362
            })

            it("increase position and exact in", async () => {
                // taker swap 1 USD for ? ETH again

                await clearingHouse.connect(taker).openPosition({
                    baseToken: baseToken.address,
                    isBaseToQuote: false,
                    isExactInput: true,
                    oppositeAmountBound: 0,
                    amount: parseEther("1"),
                    sqrtPriceLimitX96: 0,
                    deadline: ethers.constants.MaxUint256,
                    referralCode: ethers.constants.HashZero,
                })

                const fee = (
                    await clearingHouse.connect(maker).callStatic.removeLiquidity({
                        baseToken: baseToken.address,
                        lowerTick: lowerTick,
                        upperTick: upperTick,
                        liquidity: 0,
                        minBase: 0,
                        minQuote: 0,
                        deadline: ethers.constants.MaxUint256,
                    })
                ).fee
                expect(fee).to.be.closeTo(parseEther("0.06"), 1)

                expect(await clearingHouse.getPositionSize(taker.address, baseToken.address)).to.eq("19416937961245645")
            })

            it("increase position and exact out", async () => {
                // taker2 moves the price back to tick 50200 for easy calculation
                await clearingHouse.connect(taker2).openPosition({
                    baseToken: baseToken.address,
                    isBaseToQuote: true,
                    isExactInput: false,
                    oppositeAmountBound: ethers.constants.MaxUint256,
                    amount: parseEther("2"),
                    sqrtPriceLimitX96: encodePriceSqrt("151.373306858723226652", "1"),
                    deadline: ethers.constants.MaxUint256,
                    referralCode: ethers.constants.HashZero,
                })

                const feeBeforeSwap = (
                    await clearingHouse.connect(maker).callStatic.removeLiquidity({
                        baseToken: baseToken.address,
                        lowerTick: lowerTick,
                        upperTick: upperTick,
                        liquidity: 0,
                        minBase: 0,
                        minQuote: 0,
                        deadline: ethers.constants.MaxUint256,
                    })
                ).fee

                await clearingHouse.connect(taker).openPosition({
                    baseToken: baseToken.address,
                    isBaseToQuote: false,
                    isExactInput: false,
                    oppositeAmountBound: ethers.constants.MaxUint256,
                    amount: parseEther("1"),
                    sqrtPriceLimitX96: 0,
                    deadline: ethers.constants.MaxUint256,
                    referralCode: ethers.constants.HashZero,
                })

                const feeAfterSwap = (
                    await clearingHouse.connect(maker).callStatic.removeLiquidity({
                        baseToken: baseToken.address,
                        lowerTick: lowerTick,
                        upperTick: upperTick,
                        liquidity: 0,
                        minBase: 0,
                        minQuote: 0,
                        deadline: ethers.constants.MaxUint256,
                    })
                ).fee
                expect(feeAfterSwap.sub(feeBeforeSwap)).to.be.closeTo(parseEther("3.132819252941863777"), 1)
            })
        })
    })

    describe("CH fee ratio < uniswap pool fee ratio", async () => {
        beforeEach(async () => {
            // set fee ratio to 0.5%
            await exchange.setFeeRatio(baseToken.address, 5000)
            await deposit(taker, vault, 1000, collateral)
        })

        it("long and exact in", async () => {
            // taker swap 1 USD for ? ETH
            await expect(
                clearingHouse.connect(taker).openPosition({
                    baseToken: baseToken.address,
                    isBaseToQuote: false,
                    isExactInput: true,
                    oppositeAmountBound: 0,
                    amount: parseEther("1"),
                    sqrtPriceLimitX96: 0,
                    deadline: ethers.constants.MaxUint256,
                    referralCode: ethers.constants.HashZero,
                }),
            )
                .to.emit(clearingHouse, "PositionChanged")
                .withArgs(
                    taker.address, // trader
                    baseToken.address, // baseToken
                    "6572552804907016", // exchangedPositionSize
                    parseEther("-0.995"), // exchangedPositionNotional
                    parseEther("0.005"), // fee = 1 * 0.005
                    parseEther("-1"), // openNotional
                    parseEther("0"), // realizedPnl
                )

            expect(await clearingHouse.getPositionSize(taker.address, baseToken.address)).to.eq("6572552804907016")

            const fee = (
                await clearingHouse.connect(maker).callStatic.removeLiquidity({
                    baseToken: baseToken.address,
                    lowerTick: lowerTick,
                    upperTick: upperTick,
                    liquidity: 0,
                    minBase: 0,
                    minQuote: 0,
                    deadline: ethers.constants.MaxUint256,
                })
            ).fee
            expect(fee).to.be.closeTo(parseEther("0.005"), 1)
        })

        it("long and exact out", async () => {
            // taker swap ? USD for 1 ETH -> quote to base -> fee is charged before swapping
            // exchanged notional = 71.9062751863 * 10884.6906588362 / (71.9062751863 - 1) - 10884.6906588362 = 153.508143394
            // (qr * (1 - x)) * y / (1 - y)
            //   taker fee = 153.508143394 / 0.995 * 0.005 = 0.77139771

            await expect(
                clearingHouse.connect(taker).openPosition({
                    baseToken: baseToken.address,
                    isBaseToQuote: false,
                    isExactInput: false,
                    oppositeAmountBound: ethers.constants.MaxUint256,
                    amount: parseEther("1"),
                    sqrtPriceLimitX96: 0,
                    deadline: ethers.constants.MaxUint256,
                    referralCode: ethers.constants.HashZero,
                }),
            )
                .to.emit(clearingHouse, "PositionChanged")
                .withArgs(
                    taker.address, // trader
                    baseToken.address, // baseToken
                    parseEther("1"), // exchangedPositionSize
                    "-153508143394151325059", // exchangedPositionNotional
                    parseEther("0.771397705498247865"), // fee
                    "-154279541099649572924", // openNotional
                    parseEther("0"), // realizedPnl
                )
            expect(await clearingHouse.getPositionSize(taker.address, baseToken.address)).to.eq(parseEther("1"))

            const fee = (
                await clearingHouse.connect(maker).callStatic.removeLiquidity({
                    baseToken: baseToken.address,
                    lowerTick: lowerTick,
                    upperTick: upperTick,
                    liquidity: 0,
                    minBase: 0,
                    minQuote: 0,
                    deadline: ethers.constants.MaxUint256,
                })
            ).fee
            expect(fee).to.be.closeTo(parseEther("0.771397705498247865"), 1)
        })

        it("short and exact in", async () => {
            // taker swap ? USD for 1 ETH -> base to quote -> fee is included in exchangedNotional
            //   taker exchangedNotional = 10884.6906588362 - 71.9062751863 * 10884.6906588362 / (71.9062751863 + 1) = 149.2970341856
            //   taker fee = 149.2970341856 * 0.005 = 0.74648517

            // taker swap 1 ETH for ? USD
            await expect(
                clearingHouse.connect(taker).openPosition({
                    baseToken: baseToken.address,
                    isBaseToQuote: true,
                    isExactInput: true,
                    oppositeAmountBound: 0,
                    amount: parseEther("1"),
                    sqrtPriceLimitX96: 0,
                    deadline: ethers.constants.MaxUint256,
                    referralCode: ethers.constants.HashZero,
                }),
            )
                .to.emit(clearingHouse, "PositionChanged")
                .withArgs(
                    taker.address, // trader
                    baseToken.address, // baseToken
                    parseEther("-1"), // exchangedPositionSize
                    parseEther("149.297034185732877727"), // exchangedPositionNotional
                    parseEther("0.746485170928664389"), // fee
                    parseEther("148.550549014804213338"), // openNotional
                    parseEther("0"), // realizedPnl
                )
            expect(await clearingHouse.getPositionSize(taker.address, baseToken.address)).to.eq(parseEther("-1"))

            const fee = (
                await clearingHouse.connect(maker).callStatic.removeLiquidity({
                    baseToken: baseToken.address,
                    lowerTick: lowerTick,
                    upperTick: upperTick,
                    liquidity: 0,
                    minBase: 0,
                    minQuote: 0,
                    deadline: ethers.constants.MaxUint256,
                })
            ).fee
            expect(fee).to.be.closeTo(parseEther("0.746485170928664389"), 2)
        })

        it("short and exact out", async () => {
            // taker swap 1 ETH for ? USD
            await expect(
                clearingHouse.connect(taker).openPosition({
                    baseToken: baseToken.address,
                    isBaseToQuote: true,
                    isExactInput: false,
                    oppositeAmountBound: ethers.constants.MaxUint256,
                    amount: parseEther("1"),
                    sqrtPriceLimitX96: 0,
                    deadline: ethers.constants.MaxUint256,
                    referralCode: ethers.constants.HashZero,
                }),
            )
                .to.emit(clearingHouse, "PositionChanged")
                .withArgs(
                    taker.address, // trader
                    baseToken.address, // baseToken
                    parseEther("-0.006639994546394814"), // exchangedPositionSize
                    parseEther("1.005025125628140704"), // exchangedPositionNotional = 1 / 0.995
                    parseEther("0.005025125628140704"), // fee: 1 / 0.995 * 0.005 = 0.00502513
                    parseEther("1"), // openNotional
                    parseEther("0"), // realizedPnl
                )
            expect(await clearingHouse.getPositionSize(taker.address, baseToken.address)).to.eq(
                parseEther("-0.006639994546394814"),
            )

            const fee = (
                await clearingHouse.connect(maker).callStatic.removeLiquidity({
                    baseToken: baseToken.address,
                    lowerTick: lowerTick,
                    upperTick: upperTick,
                    liquidity: 0,
                    minBase: 0,
                    minQuote: 0,
                    deadline: ethers.constants.MaxUint256,
                })
            ).fee
            expect(fee).to.be.closeTo(parseEther("0.005025125628140704"), 2)
        })
    })

    describe("change CH fee ratio", async () => {
        beforeEach(async () => {
            // set fee ratio to 0.5%
            await exchange.setFeeRatio(baseToken.address, 20000)
            await deposit(taker, vault, 1000, collateral)

            await clearingHouse.connect(taker).openPosition({
                baseToken: baseToken.address,
                isBaseToQuote: false,
                isExactInput: true,
                oppositeAmountBound: 0,
                amount: parseEther("1"),
                sqrtPriceLimitX96: 0,
                deadline: ethers.constants.MaxUint256,
                referralCode: ethers.constants.HashZero,
            })
        })

        it("change from 2% to 3%", async () => {
            await exchange.setFeeRatio(baseToken.address, 30000)

            // taker swap 1 USD for ? ETH
            await expect(
                clearingHouse.connect(taker).openPosition({
                    baseToken: baseToken.address,
                    isBaseToQuote: false,
                    isExactInput: true,
                    oppositeAmountBound: 0,
                    amount: parseEther("1"),
                    sqrtPriceLimitX96: 0,
                    deadline: ethers.constants.MaxUint256,
                    referralCode: ethers.constants.HashZero,
                }),
            )
                .to.emit(clearingHouse, "PositionChanged")
                .withArgs(
                    taker.address, // trader
                    baseToken.address, // baseToken
                    "6406274427766891", // exchangedPositionSize
                    parseEther("-0.97"), // exchangedPositionNotional
                    parseEther("0.03"), // fee = 1 * 0.03
                    parseEther("-2"), // openNotional
                    parseEther("0"), // realizedPnl
                )

            expect(await clearingHouse.getPositionSize(taker.address, baseToken.address)).to.eq("12879752442217497")

            const fee = (
                await clearingHouse.connect(maker).callStatic.removeLiquidity({
                    baseToken: baseToken.address,
                    lowerTick: lowerTick,
                    upperTick: upperTick,
                    liquidity: 0,
                    minBase: 0,
                    minQuote: 0,
                    deadline: ethers.constants.MaxUint256,
                })
            ).fee
            expect(fee).to.be.closeTo(parseEther("0.05"), 1)
        })

        it("change from 2% to 1%", async () => {
            await exchange.setFeeRatio(baseToken.address, 10000)

            // taker swap 1 USD for ? ETH
            await expect(
                clearingHouse.connect(taker).openPosition({
                    baseToken: baseToken.address,
                    isBaseToQuote: false,
                    isExactInput: true,
                    oppositeAmountBound: 0,
                    amount: parseEther("1"),
                    sqrtPriceLimitX96: 0,
                    deadline: ethers.constants.MaxUint256,
                    referralCode: ethers.constants.HashZero,
                }),
            )
                .to.emit(clearingHouse, "PositionChanged")
                .withArgs(
                    taker.address, // trader
                    baseToken.address, // baseToken
                    "6538350548602818", // exchangedPositionSize
                    parseEther("-0.99"), // exchangedPositionNotional
                    parseEther("0.01"), // fee = 1 * 0.01
                    parseEther("-2"), // openNotional
                    parseEther("0"), // realizedPnl
                )

            expect(await clearingHouse.getPositionSize(taker.address, baseToken.address)).to.eq("13011828563053424")

            const fee = (
                await clearingHouse.connect(maker).callStatic.removeLiquidity({
                    baseToken: baseToken.address,
                    lowerTick: lowerTick,
                    upperTick: upperTick,
                    liquidity: 0,
                    minBase: 0,
                    minQuote: 0,
                    deadline: ethers.constants.MaxUint256,
                })
            ).fee
            expect(fee).to.be.closeTo(parseEther("0.03"), 1)
        })

        it("change from 2% to 3% and then to 5%", async () => {
            await exchange.setFeeRatio(baseToken.address, 30000)

            // taker swap 1 USD for ? ETH
            await clearingHouse.connect(taker).openPosition({
                baseToken: baseToken.address,
                isBaseToQuote: false,
                isExactInput: true,
                oppositeAmountBound: 0,
                amount: parseEther("1"),
                sqrtPriceLimitX96: 0,
                deadline: ethers.constants.MaxUint256,
                referralCode: ethers.constants.HashZero,
            })

            await exchange.setFeeRatio(baseToken.address, 50000)

            // taker swap 1 USD for ? ETH
            await expect(
                clearingHouse.connect(taker).openPosition({
                    baseToken: baseToken.address,
                    isBaseToQuote: false,
                    isExactInput: true,
                    oppositeAmountBound: 0,
                    amount: parseEther("1"),
                    sqrtPriceLimitX96: 0,
                    deadline: ethers.constants.MaxUint256,
                    referralCode: ethers.constants.HashZero,
                }),
            )
                .to.emit(clearingHouse, "PositionChanged")
                .withArgs(
                    taker.address, // trader
                    baseToken.address, // baseToken
                    "6273079857818529", // exchangedPositionSize
                    parseEther("-0.95"), // exchangedPositionNotional
                    parseEther("0.05"), // fee = 1 * 0.05
                    parseEther("-3"), // openNotional
                    parseEther("0"), // realizedPnl
                )

            expect(await clearingHouse.getPositionSize(taker.address, baseToken.address)).to.eq("19152832300036026")

            const fee = (
                await clearingHouse.connect(maker).callStatic.removeLiquidity({
                    baseToken: baseToken.address,
                    lowerTick: lowerTick,
                    upperTick: upperTick,
                    liquidity: 0,
                    minBase: 0,
                    minQuote: 0,
                    deadline: ethers.constants.MaxUint256,
                })
            ).fee
            expect(fee).to.be.closeTo(parseEther("0.1"), 1)
        })
    })

    describe("cross many ticks to make sure CH mint enough token to transfer to Uniswap pool", async () => {
        beforeEach(async () => {
            const takerCollateral = parseUnits("9000", collateralDecimals)
            await collateral.mint(taker.address, takerCollateral)
            await collateral.connect(taker).approve(clearingHouse.address, takerCollateral)
            await deposit(taker, vault, 10000, collateral)

            // set fee ratio to 2%
            await exchange.setFeeRatio(baseToken.address, 20000)
        })

        it("Q2B and exact in", async () => {
            await clearingHouse.connect(taker).openPosition({
                baseToken: baseToken.address,
                isBaseToQuote: false,
                isExactInput: true,
                oppositeAmountBound: 0,
                amount: parseEther("8000"),
                sqrtPriceLimitX96: 0,
                deadline: ethers.constants.MaxUint256,
                referralCode: ethers.constants.HashZero,
            })

            const fee = (
                await clearingHouse.connect(maker).callStatic.removeLiquidity({
                    baseToken: baseToken.address,
                    lowerTick: lowerTick,
                    upperTick: upperTick,
                    liquidity: 0,
                    minBase: 0,
                    minQuote: 0,
                    deadline: ethers.constants.MaxUint256,
                })
            ).fee
            // 8000 * 2% = 160
            expect(fee).to.be.eq(parseEther("160"))
        })

        it("Q2B and exact out", async () => {
            await clearingHouse.connect(taker).openPosition({
                baseToken: baseToken.address,
                isBaseToQuote: false,
                isExactInput: false,
                oppositeAmountBound: ethers.constants.MaxUint256,
                amount: parseEther("30"),
                sqrtPriceLimitX96: 0,
                deadline: ethers.constants.MaxUint256,
                referralCode: ethers.constants.HashZero,
            })

            const fee = (
                await clearingHouse.connect(maker).callStatic.removeLiquidity({
                    baseToken: baseToken.address,
                    lowerTick: lowerTick,
                    upperTick: upperTick,
                    liquidity: 0,
                    minBase: 0,
                    minQuote: 0,
                    deadline: ethers.constants.MaxUint256,
                })
            ).fee

            // TODO need spreadsheet
            expect(fee).is.gt(0)
        })
    })
})
