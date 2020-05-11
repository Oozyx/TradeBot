pragma solidity ^0.6.0;

import "./interfaces/ERC20.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router01.sol";
import "./interfaces/KyberNetworkProxyInterface.sol";
import "./interfaces/ILendingPoolAddressesProvider.sol";
import "./interfaces/ILendingPool.sol";
import "./interfaces/AToken.sol";
import "./interfaces/OrFeedInterface.sol";

contract TradeBot {
  /*
    Constants
  */
  address private constant  UNISWAP_ROUTER_ADDRESS  = 0xcDbE04934d89e97a24BCc07c3562DC8CF17d8167; // Rinkeby
  address private constant  UNISWAP_FACTORY_ADDRESS = 0xe2f197885abe8ec7c866cFf76605FD06d4576218; // Rinkeby
  address private constant  KYBER_PROXY_ADDRESS     = 0xF77eC7Ed5f5B9a5aee4cfa6FFCaC6A4C315BaC76; // Rinkeby
  address private constant  ETH_MOCK_ADDRESS        = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  address private constant  DAI_ADDRESS             = 0x6B175474E89094C44Da98b954EedeAC495271d0F; // Mainnet
  address private constant  AAVE_ADDRESSES_PROVIDER = 0x1c8756FD2B28e9426CDBDcC7E3c4d64fa9A54728; // Ropsten
  address private constant  ORFEED_ADDRESS          = 0xB215bF00E18825667f696833d13368092CF62E66; // Rinkeby
  uint    private constant  TOKEN_18_DECIMALS       = (10**18);
  
  /*
    Members
  */
  address                       private immutable owner;
  IUniswapV2Factory             private immutable uniswapFactory;
  IUniswapV2Router01            private immutable uniswapRouter;
  KyberNetworkProxyInterface    private immutable kyberProxy;
  ILendingPoolAddressesProvider private immutable aaveAddressesProvider;
  OrFeedInterface               private immutable orfeed;

  mapping(address => string)    public  orfeedAssets;

  /*
    Events
  */
  event Log(string log);
  event Log(uint log);

  /*
    Modifiers
  */
  modifier onlyOwner() {
    require (
      msg.sender == owner,
      "Only owner can call this function."
    );
    _;
  }

  /*
    Constructors
  */
  constructor() public {
    owner = msg.sender;
    uniswapFactory        = IUniswapV2Factory(UNISWAP_FACTORY_ADDRESS);
    uniswapRouter         = IUniswapV2Router01(UNISWAP_ROUTER_ADDRESS);
    kyberProxy            = KyberNetworkProxyInterface(KYBER_PROXY_ADDRESS);
    aaveAddressesProvider = ILendingPoolAddressesProvider(AAVE_ADDRESSES_PROVIDER);
    orfeed                = OrFeedInterface(ORFEED_ADDRESS);

    // Initialize orfeed assets with basic assets
    addOrfeedAsset(ETH_MOCK_ADDRESS, "ETH");
    addOrfeedAsset(DAI_ADDRESS, "DAI"); // Rinkeby DAI
  }

  /*
    Aave methods
  */
  function depositEthAave(uint ethAmount) public onlyOwner {
    // Verify we have enough funds
    require(ethAmount <= address(this).balance, "Not enough Eth in contract to deposit into Aave.");

    // Make the call
    ILendingPool lendingPool = ILendingPool(aaveAddressesProvider.getLendingPool());
    lendingPool.deposit{ value: ethAmount }(ETH_MOCK_ADDRESS, ethAmount, 0);
  }

  function withdrawEthAave(uint ethAmount) public onlyOwner {
    // Get the aToken address
    address aTokenEthAddress;
    ILendingPool lendingPool = ILendingPool(aaveAddressesProvider.getLendingPool());
    (,,,,,,,,,,, aTokenEthAddress,) = lendingPool.getReserveData(ETH_MOCK_ADDRESS);

    // Verify if the withdrawal is allowed
    AToken aTokenEth = AToken(aTokenEthAddress);
    require(aTokenEth.isTransferAllowed(address(this), ethAmount), "Withdrawal is not allowed.");

    // Make the call
    aTokenEth.redeem(ethAmount);
  }

  function depositTokenAave(address tokenAddress, uint tokenAmount) public onlyOwner {
    // Verify we have enough funds
    ERC20 token = ERC20(tokenAddress);
    require(tokenAmount <= token.balanceOf(address(this)), "Not enough tokens in contract to deposit.");

    // Give approval to Aave to transfer my tokens
    ILendingPool lendingPool = ILendingPool(aaveAddressesProvider.getLendingPool());
    token.approve(address(lendingPool), tokenAmount);

    // Make the call
    lendingPool.deposit(tokenAddress, tokenAmount, 0);
  }

  function withdrawTokenAave(address tokenAddress, uint tokenAmount) public onlyOwner {
    // Get the aToken address
    address aTokenAddress;
    ILendingPool lendingPool = ILendingPool(aaveAddressesProvider.getLendingPool());
    (,,,,,,,,,,, aTokenAddress,) = lendingPool.getReserveData(tokenAddress);

    // Verify if the withdrawal is allowed
    AToken atoken = AToken(aTokenAddress);
    require(atoken.isTransferAllowed(address(this), tokenAmount), "Withdrawal is not allowed.");

    // Make the call
    atoken.redeem(tokenAmount);
  }

  /*
    Uniswap methods
  */
  function addLiquidityUniswap(address tokenAddress, uint tokenAmount, uint ethAmount) public onlyOwner {
    ERC20 token = ERC20(tokenAddress);
    require(tokenAmount <= token.balanceOf(address(this)), "Not enough tokens in contract to add liquidity.");
    require(ethAmount <= address(this).balance, "Not enough Eth in contract to add liquidity.");

    token.approve(address(uniswapRouter), token.balanceOf(address(this)));

    uniswapRouter.addLiquidityETH{ value: ethAmount }(tokenAddress, tokenAmount, tokenAmount, ethAmount, msg.sender, now);
  }

  function swapEthForTokenUniswap(address tokenAddress, uint ethAmount) public onlyOwner returns (uint) {
    // Verify we have enough funds
    require(ethAmount <= address(this).balance, "Not enough Eth in contract to perform swap.");

    // Build arguments for uniswap router call
    address[] memory path = new address[](2);
    path[0] = uniswapRouter.WETH();
    path[1] = tokenAddress;

    // Make the call
    uint[] memory result = uniswapRouter.swapExactETHForTokens{ value: ethAmount }(0, path, address(this), now);
    return result[1]; // Returns the output amount
  }

  function swapTokenForEthUniswap(address tokenAddress, uint tokenAmount) public onlyOwner returns (uint) {
    // Verify we have enough funds
    ERC20 token = ERC20(tokenAddress);
    require(tokenAmount <= token.balanceOf(address(this)), "Not enough tokens in contract to perform swap.");

    // Approve uniswap to manage contract tokens
    token.approve(address(uniswapRouter), token.balanceOf(address(this)));

    // Build arguments for uniswap router call
    address[] memory path = new address[](2);
    path[0] = tokenAddress;
    path[1] = uniswapRouter.WETH();

    // Make the call
    uint[] memory result = uniswapRouter.swapExactTokensForETH(tokenAmount, 0, path, address(this), now);
    return result[1]; // Returns the output amount
  }

  function swapTokenForTokenUniswap(address fromTokenAddress, address toTokenAddress, uint tokenAmount) public onlyOwner returns (uint) {
    // Verify we have enough funds
    ERC20 fromToken = ERC20(fromTokenAddress);
    require(tokenAmount <= fromToken.balanceOf(address(this)), "Not enough tokens in contract to perform swap.");

    // Approve uniswap to manage contract Dai
    fromToken.approve(address(uniswapRouter), tokenAmount);

    // Build arguments for uniswap router call
    address[] memory path = new address[](2);
    path[0] = fromTokenAddress;
    path[0] = toTokenAddress;

    // Make the call
    uint[] memory result = uniswapRouter.swapExactTokensForTokens(tokenAmount, 0, path, address(this), now);
    return result[1];    
  }

  /*
    Kyber methods
  */
  function swapEthForTokenKyber(address tokenAddress, uint ethAmount) public onlyOwner returns (uint) {
    require(ethAmount <= address(this).balance, "Not enough Eth in contract to perform swap.");

    // Declare tokens involved in trade
    ERC20 eth = ERC20(ETH_MOCK_ADDRESS);
    ERC20 token = ERC20(tokenAddress);
    
    // Get the conversion rate
    uint minConversionRate;
    uint slippageRate;
    (minConversionRate, slippageRate) = kyberProxy.getExpectedRate(eth, token, ethAmount);
    require(minConversionRate != 0 || slippageRate != 0, "Trade is not possible at the moment.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint{ value: ethAmount }(eth, ethAmount, token, address(this), 10**18 * 10**6, minConversionRate, address(0), hint);
  }

  function swapTokenForEthKyber(address tokenAddress, uint tokenAmount) public onlyOwner returns (uint) {
    // Verify we have enough funds
    ERC20 eth = ERC20(ETH_MOCK_ADDRESS);
    ERC20 token = ERC20(tokenAddress);
    require(tokenAmount <= token.balanceOf(address(this)), "Not enough tokens in contract to perform swap.");

    // Mitigate ERC20 Approve front-running attack, by initially setting allowance to 0
    require(token.approve(KYBER_PROXY_ADDRESS, 0), "Failure to approve sender front running attack.");

    // Set the spender's token allowance to tokenQty
    require(token.approve(KYBER_PROXY_ADDRESS, tokenAmount), "Failure to approve sender for token amount.");

    // Get the conversion rate
    uint minConversionRate;
    uint slippageRate;
    (minConversionRate, slippageRate) = kyberProxy.getExpectedRate(token, eth, tokenAmount);
    require(minConversionRate != 0 || slippageRate != 0, "Trade is not possible at the moment.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint(token, tokenAmount, eth, address(this), 10**18 * 10**6, minConversionRate, address(0), hint);
  }

  function swapTokenForTokenKyber(address fromTokenAddress, address toTokenAddress, uint tokenAmount) public onlyOwner returns (uint) {
    ERC20 fromToken = ERC20(fromTokenAddress);
    ERC20 toToken = ERC20(toTokenAddress);

    // Verify we have enough funds
    require(tokenAmount <= fromToken.balanceOf(address(this)), "Not enough tokens in contract to perform swap.");

    // Mitigate ERC20 Approve front-running attack by initially setting allowance to 0
    require(fromToken.approve(KYBER_PROXY_ADDRESS, 0), "Failure to approve sender front running attack.");

    // Set the spender's token allowance to daiAmount
    require(fromToken.approve(KYBER_PROXY_ADDRESS, tokenAmount), "Failure to approve sender for dai amount.");

    // Get the conversion rate
    uint minConversionRate;
    uint slippageRate;
    (minConversionRate, slippageRate) = kyberProxy.getExpectedRate(fromToken, toToken, tokenAmount);
    require(minConversionRate != 0 || slippageRate != 0, "Trade is not possible at the moment.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint(fromToken, tokenAmount, toToken, address(this), 10**18 * 10**6, minConversionRate, address(0), hint);
  }

  /*
    Orfeed methods
  */
  function addOrfeedAsset(address assetAddress, string memory assetName) internal {
    orfeedAssets[assetAddress] = assetName;
  }

  function getEthBuyPriceUniswap(uint ethAmount) public view returns (uint) {
    return orfeed.getExchangeRate("ETH", "DAI", "BUY-UNISWAP-EXCHANGE", ethAmount);
  }

  function getEthSellPriceUniswap(uint ethAmount) public view returns (uint) {
    return orfeed.getExchangeRate("ETH", "DAI", "SELL-UNISWAP-EXCHANGE", ethAmount);
  }

  function getTokenBuyPriceUniswap(address tokenAddress, uint tokenAmount) public view returns (uint) {
    return orfeed.getExchangeRate(orfeedAssets[tokenAddress], "DAI", "BUY-UNISWAP-EXCHANGE", tokenAmount);
  }

  function getTokenSellPriceUniswap(address tokenAddress, uint tokenAmount) public view returns (uint) {
    return orfeed.getExchangeRate(orfeedAssets[tokenAddress], "DAI", "SELL-UNISWAP-EXCHANGE", tokenAmount);
  }

  function getEthBuyPriceKyber(uint ethAmount) public view returns (uint) {
    return orfeed.getExchangeRate("ETH", "DAI", "BUY-KYBER-EXCHANGE", ethAmount);
  }

  function getEthSellPriceKyber(uint ethAmount) public view returns (uint) {
    return orfeed.getExchangeRate("ETH", "DAI", "SELL-KYBER-EXCHANGE", ethAmount);
  }

  function getTokenBuyPriceKyber(address tokenAddress, uint tokenAmount) public view returns (uint) {
    return orfeed.getExchangeRate(orfeedAssets[tokenAddress], "DAI", "BUY-KYBER-EXCHANGE", tokenAmount);
  }

  function getTokenSellPriceKyber(address tokenAddress, uint tokenAmount) public view returns (uint) {
    return orfeed.getExchangeRate(orfeedAssets[tokenAddress], "DAI", "SELL-KYBER-EXCHANGE", tokenAmount);
  }

  /*
    Arbitrage methods
  */
  function arbSellUniswapBuyKyber(address tokenAddress, address mediatorAddress, uint tokenAmount) public onlyOwner {
    // Make sure we have enough tokens to perform the trade
    ERC20 token = ERC20(tokenAddress);
    require(tokenAmount <= token.balanceOf(address(this)), "Not enough tokens in contract to perform trade.");
    emit Log("Starting amount of tokens:");
    emit Log(tokenAmount);

    // Sell on Uniswap
    uint mediatorTokenAmount = swapTokenForTokenUniswap(tokenAddress, mediatorAddress, tokenAmount);

    // Buy on Kyber
    uint newTokenAmount = swapTokenForTokenKyber(mediatorAddress, tokenAddress, mediatorTokenAmount);
    emit Log("New amount of tokens:");
    emit Log(newTokenAmount);

    // Revert if no profit was made
    require(newTokenAmount > tokenAmount, "Reverted: no profit made.");
  }

  function arbSellKyberBuyUniswap(address tokenAddress, address mediatorAddress, uint tokenAmount) public onlyOwner {
    // Make sure we have enough tokens to perform the trade
    ERC20 token = ERC20(tokenAddress);
    require(tokenAmount <= token.balanceOf(address(this)), "Not enough tokens in contract to perform trade.");
    emit Log("Starting amount of tokens:");
    emit Log(tokenAmount);

    // Sell on Kyber
    uint mediatorTokenAmount = swapTokenForTokenKyber(tokenAddress, mediatorAddress, tokenAmount);

    // Buy on Uniswap
    uint newTokenAmount = swapTokenForTokenUniswap(mediatorAddress, tokenAddress, mediatorTokenAmount);
    emit Log("New amount of tokens:");
    emit Log(newTokenAmount);

    // Revert if no profit was made
    require(newTokenAmount > tokenAmount, "Reverted: no profit made.");
  }

  /*
    Deposit and Withdrawal methods
  */
  function depositEth() external payable {
    // Nothing to do
  }

  function depositToken(address tokenAddress, uint tokenAmount) external {
    ERC20 token = ERC20(tokenAddress);
    require (tokenAmount <= token.balanceOf(msg.sender), "Deposit amount exceeds holding amount.");
    token.transferFrom(msg.sender, address(this), tokenAmount);
  }

  function withdrawEth() external onlyOwner {
    msg.sender.transfer(address(this).balance);
  }

  function withdrawToken(address tokenAddress) external onlyOwner {
    ERC20 token = ERC20(tokenAddress);
    token.transfer(msg.sender, token.balanceOf(address(this)));
  }

  receive() external payable {
    // Nothing to do
  }
}