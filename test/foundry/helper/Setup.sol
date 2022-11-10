import "forge-std/Test.sol";
import "../../../contracts/MarketRegistry.sol";
import "../../../contracts/ClearingHouse.sol";
import "../../../contracts/Exchange.sol";
import "../../../contracts/OrderBook.sol";
import "../../../contracts/ClearingHouseConfig.sol";
import "../../../contracts/InsuranceFund.sol";
import "../../../contracts/AccountBalance.sol";
import "../../../contracts/Vault.sol";
import "../../../contracts/QuoteToken.sol";
import "../../../contracts/BaseToken.sol";
import "../../../contracts/VirtualToken.sol";
import "../../../contracts/test/TestERC20.sol";
import "@perp/perp-oracle-contract/contracts/interface/IPriceFeed.sol";
import "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3PoolDeployer.sol";
import "@uniswap/v3-core/contracts/UniswapV3Pool.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "./DeployConfig.sol";

contract Setup is Test, DeployConfig {
    address internal _BASE_TOKEN_PRICE_FEED = makeAddr("_BASE_TOKEN_PRICE_FEED");
    address internal _BASE_TOKEN_2_PRICE_FEED = makeAddr("_BASE_TOKEN_2_PRICE_FEED");
    MarketRegistry public marketRegistry;
    ClearingHouse public clearingHouse;
    ClearingHouseConfig public clearingHouseConfig;
    InsuranceFund public insuranceFund;
    AccountBalance public accountBalance;
    OrderBook public orderBook;
    Exchange public exchange;
    Vault public vault;
    UniswapV3Factory public uniswapV3Factory;
    UniswapV3Pool public pool;
    UniswapV3Pool public pool2;
    BaseToken public baseToken;
    BaseToken public baseToken2;
    QuoteToken public quoteToken;
    TestERC20 public usdc;

    function setUp() public virtual {
        // External
        uniswapV3Factory = _create_UniswapV3Factory();
        usdc = _create_TestERC20("USD Coin", "USDC", 6);

        // Cores
        clearingHouseConfig = _create_ClearingHouseConfig();
        quoteToken = _create_QuoteToken();
        marketRegistry = _create_MarketRegistry(address(uniswapV3Factory), address(quoteToken), address(clearingHouse));
        insuranceFund = _create_InsuranceFund(address(usdc));
        orderBook = _create_OrderBook(address(marketRegistry));
        exchange = _create_Exchange(address(marketRegistry), address(orderBook), address(clearingHouseConfig));
        accountBalance = _create_AccountBalance(address(clearingHouseConfig), address(orderBook));
        vault = _create_Vault(
            address(insuranceFund),
            address(clearingHouseConfig),
            address(accountBalance),
            address(exchange)
        );
        clearingHouse = _create_ClearingHouse(
            address(clearingHouseConfig),
            address(vault),
            address(quoteToken),
            address(uniswapV3Factory),
            address(exchange),
            address(accountBalance),
            address(insuranceFund)
        );
        baseToken = _create_BaseToken(_BASE_TOKEN_NAME, address(quoteToken), _BASE_TOKEN_PRICE_FEED, false);
        baseToken2 = _create_BaseToken(_BASE_TOKEN_2_NAME, address(quoteToken), _BASE_TOKEN_2_PRICE_FEED, false);
        pool = _create_UniswapV3Pool(uniswapV3Factory, baseToken, quoteToken, _DEFAULT_POOL_FEE);
        pool2 = _create_UniswapV3Pool(uniswapV3Factory, baseToken2, quoteToken, _DEFAULT_POOL_FEE);

        _setter();

        // Label addresses for easier debugging
        vm.label(address(clearingHouseConfig), "ClearingHouseConfig");
        vm.label(address(marketRegistry), "MarketRegistry");
        vm.label(address(insuranceFund), "InsuranceFund");
        vm.label(address(orderBook), "OrderBook");
        vm.label(address(exchange), "Exchange");
        vm.label(address(accountBalance), "AccountBalance");
        vm.label(address(vault), "Vault");
        vm.label(address(clearingHouse), "ClearingHouse");
        vm.label(address(baseToken), "BaseToken");
        vm.label(address(baseToken2), "BaseToken2");
        vm.label(address(quoteToken), "QuoteToken");
        vm.label(address(pool), "Pool");
        vm.label(address(pool2), "Pool2");
        vm.label(address(usdc), "Usdc");
    }

    function _create_QuoteToken() internal returns (QuoteToken) {
        QuoteToken quoteToken = new QuoteToken();
        quoteToken.initialize(_QUOTE_TOKEN_NAME, _QUOTE_TOKEN_NAME);
        return quoteToken;
    }

    function _create_BaseToken(
        string memory tokenName,
        address quoteToken,
        address baseTokenPriceFeed,
        bool largerThan
    ) internal returns (BaseToken) {
        BaseToken baseToken;
        while (address(baseToken) == address(0) || (largerThan != (quoteToken < address(baseToken)))) {
            baseToken = new BaseToken();
        }
        // NOTE: put faked code on price feed address, must have contract code to make mockCall
        vm.etch(baseTokenPriceFeed, "_PRICE_FEED");
        vm.mockCall(baseTokenPriceFeed, abi.encodeWithSelector(IPriceFeed.decimals.selector), abi.encode(8));
        baseToken.initialize(tokenName, tokenName, baseTokenPriceFeed);
        return baseToken;
    }

    function _create_UniswapV3Factory() internal returns (UniswapV3Factory) {
        return new UniswapV3Factory();
    }

    function _create_UniswapV3Pool(
        UniswapV3Factory uniswapV3Factory,
        BaseToken baseToken,
        QuoteToken quoteToken,
        uint24 fee
    ) internal returns (UniswapV3Pool) {
        address poolAddress = uniswapV3Factory.createPool(address(baseToken), address(quoteToken), fee);
        baseToken.addWhitelist(poolAddress);
        quoteToken.addWhitelist(poolAddress);
        return UniswapV3Pool(poolAddress);
    }

    function _create_MarketRegistry(
        address uniswapV3Factory,
        address quoteToken,
        address clearingHouse
    ) internal returns (MarketRegistry) {
        MarketRegistry marketRegistry = new MarketRegistry();
        marketRegistry.initialize(uniswapV3Factory, quoteToken);
        return marketRegistry;
    }

    function _create_Exchange(
        address marketRegistryArg,
        address orderBookArg,
        address clearingHouseConfigArg
    ) internal returns (Exchange) {
        Exchange exchange = new Exchange();
        exchange.initialize(marketRegistryArg, orderBookArg, clearingHouseConfigArg);
        return exchange;
    }

    function _create_OrderBook(address marketRegistryArg) internal returns (OrderBook) {
        OrderBook orderBook = new OrderBook();
        orderBook.initialize(marketRegistryArg);
        return orderBook;
    }

    function _create_ClearingHouseConfig() internal returns (ClearingHouseConfig) {
        ClearingHouseConfig clearingHouseConfig = new ClearingHouseConfig();
        clearingHouseConfig.initialize();
        return clearingHouseConfig;
    }

    function _create_ClearingHouse(
        address clearingHouseConfigArg,
        address vaultArg,
        address quoteTokenArg,
        address uniswapV3FactoryArg,
        address exchangeArg,
        address accountBalanceArg,
        address insuranceFundArg
    ) internal returns (ClearingHouse) {
        ClearingHouse clearingHouse = new ClearingHouse();
        clearingHouse.initialize(
            clearingHouseConfigArg,
            vaultArg,
            quoteTokenArg,
            uniswapV3FactoryArg,
            exchangeArg,
            accountBalanceArg,
            insuranceFundArg
        );
        return clearingHouse;
    }

    function _create_InsuranceFund(address usdcArg) internal returns (InsuranceFund) {
        InsuranceFund insuranceFund = new InsuranceFund();
        insuranceFund.initialize(usdcArg);

        return insuranceFund;
    }

    function _create_AccountBalance(address clearingHouseConfig, address orderBookArg)
        internal
        returns (AccountBalance)
    {
        AccountBalance accountBalance = new AccountBalance();
        accountBalance.initialize(clearingHouseConfig, orderBookArg);
        return accountBalance;
    }

    function _create_Vault(
        address insuranceFundArg,
        address clearingHouseConfigArg,
        address accountBalanceArg,
        address exchangeArg
    ) internal returns (Vault) {
        Vault vault = new Vault();
        vault.initialize(insuranceFundArg, clearingHouseConfigArg, accountBalanceArg, exchangeArg);
        return vault;
    }

    function _create_TestERC20(
        string memory name,
        string memory symbol,
        uint8 decimal
    ) internal returns (TestERC20) {
        TestERC20 testErc20 = new TestERC20();
        testErc20.__TestERC20_init(name, symbol, decimal);
        return testErc20;
    }

    function _setter() internal {
        // baseToken
        baseToken.mintMaximumTo(address(clearingHouse));
        baseToken.addWhitelist(address(clearingHouse));
        baseToken.addWhitelist(address(pool));

        // baseToken2
        baseToken2.mintMaximumTo(address(clearingHouse));
        baseToken2.addWhitelist(address(clearingHouse));
        baseToken2.addWhitelist(address(pool2));

        // quoteToken
        quoteToken.mintMaximumTo(address(clearingHouse));
        quoteToken.addWhitelist(address(clearingHouse));
        quoteToken.addWhitelist(address(pool));
        quoteToken.addWhitelist(address(pool2));

        // clearingHouseConfig
        clearingHouseConfig.setMaxMarketsPerAccount(MAX_MARKETS_PER_ACCOUNT);
        uint8 settlementTokenDecimals = vault.decimals();
        clearingHouseConfig.setSettlementTokenBalanceCap(SETTLEMENT_TOKEN_BALANCE_CAP * 10**settlementTokenDecimals);

        // marketRegistry
        marketRegistry.setClearingHouse(address(clearingHouse));
        marketRegistry.setMaxOrdersPerMarket(MAX_ORDERS_PER_MARKET);

        // insuranceFund
        insuranceFund.setBorrower(address(vault));

        // orderBook
        orderBook.setClearingHouse(address(clearingHouse));
        orderBook.setExchange(address(exchange));

        // exchange
        exchange.setClearingHouse(address(clearingHouse));
        exchange.setAccountBalance(address(accountBalance));

        // accountBalance
        accountBalance.setClearingHouse(address(clearingHouse));
        accountBalance.setVault(address(vault));

        // vault
        vault.setClearingHouse(address(clearingHouse));
    }
}
