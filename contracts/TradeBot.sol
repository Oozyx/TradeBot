pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./interfaces/KyberNetworkProxyInterface.sol";
import "./interfaces/FlashLoanReceiverBase.sol";
import "./interfaces/ILendingPool.sol";
import "./libs/UniswapV2Library.sol";

// Necessary imports for Uniswap V1
import "./interfaces/UniswapFactoryInterface.sol";
import "./interfaces/UniswapExchangeInterface.sol";

contract TradeBot is FlashLoanReceiverBase {
  /*
    Constants
  */
  address internal constant  UNISWAP_FACTORY_ADDRESS = 0xc0a47dFe034B400B47bDaD5FecDa2621de6c4d95; // Mainnet
  address internal constant  KYBER_PROXY_ADDRESS     = 0x818E6FECD516Ecc3849DAf6845e3EC868087B755; // Mainnet
  address internal constant  ETH_MOCK_ADDRESS        = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  address internal constant  AAVE_ADDRESSES_PROVIDER = 0x24a42fD28C976A61Df5D00D0599C34c4f90748c8; // Mainnet
  
  /*
    Members
  */
  UniswapFactoryInterface       internal immutable uniswapFactory;
  KyberNetworkProxyInterface    internal immutable kyberProxy;
  ILendingPool                  internal immutable lendingPool;

  /*
    Events
  */
  // event Log(string log);

  /*
    Constructors
  */
  constructor() FlashLoanReceiverBase(AAVE_ADDRESSES_PROVIDER) public {
    uniswapFactory   = UniswapFactoryInterface(UNISWAP_FACTORY_ADDRESS);
    kyberProxy       = KyberNetworkProxyInterface(KYBER_PROXY_ADDRESS);
    lendingPool      = ILendingPool(addressesProvider.getLendingPool());
  }

  /*
    Uniswap methods
  */
  function getAmountOutUniswap(address fromToken, address toToken, uint fromTokenAmount) external view returns (uint) {
    // Limited release, ETH needs to be a part of the trade
    require((fromToken == ETH_MOCK_ADDRESS || toToken == ETH_MOCK_ADDRESS), "ETH is not one of the tokens to be swapped.");

    UniswapExchangeInterface exchange;
    if (fromToken == ETH_MOCK_ADDRESS) {
      // Get the exchange
      exchange = UniswapExchangeInterface(uniswapFactory.getExchange(toToken));
      return exchange.getEthToTokenInputPrice(fromTokenAmount);
    }

    if (toToken == ETH_MOCK_ADDRESS) {
      // Get the exchange
      exchange = UniswapExchangeInterface(uniswapFactory.getExchange(fromToken));
      return exchange.getTokenToEthInputPrice(fromTokenAmount);
    }
  }

  function swapEthForTokenUniswap(address tokenAddress, uint ethAmount) internal returns (uint) {
    // Make sure we have enough ETH
    require(ethAmount <= address(this).balance, "Not enough Eth in contract to perform swap.");

    // Get the exchange
    UniswapExchangeInterface exchange = UniswapExchangeInterface(uniswapFactory.getExchange(tokenAddress));

    // Get the token amount that can be bought
    uint tokenAmount = exchange.getEthToTokenInputPrice(ethAmount);

    // Make the swap
    return exchange.ethToTokenSwapInput{ value: ethAmount }(tokenAmount, now);
  }

  function swapTokenForEthUniswap(address tokenAddress, uint tokenAmount) internal returns (uint) {
    // Verify we have enough funds
    ERC20 token = ERC20(tokenAddress);
    require(tokenAmount <= token.balanceOf(address(this)), "Not enough tokens in contract to perform swap.");

    // Get the exchange
    UniswapExchangeInterface exchange = UniswapExchangeInterface(uniswapFactory.getExchange(tokenAddress));

    // Get the amount of ETH that can be bought
    uint ethAmount = exchange.getTokenToEthInputPrice(tokenAmount);

    // Approve uniswap for transferring our tokens
    token.approve(address(exchange), tokenAmount);

    // Make the swap
    return exchange.tokenToEthSwapInput(tokenAmount, ethAmount, now);
  }

  function swapTokenForTokenUniswap(address fromTokenAddress, address toTokenAddress, uint tokenAmount) internal returns (uint) {
    // Limited release, ETH needs to be a part of the trade
    require((fromTokenAddress == ETH_MOCK_ADDRESS || toTokenAddress == ETH_MOCK_ADDRESS), "ETH is not one of the tokens to be swapped.");
    
    if (fromTokenAddress == ETH_MOCK_ADDRESS) {
      return swapEthForTokenUniswap(toTokenAddress, tokenAmount);
    }
    
    if (toTokenAddress == ETH_MOCK_ADDRESS) {
      return swapTokenForEthUniswap(fromTokenAddress, tokenAmount);
    }
  }

  /*
    Kyber methods
  */
  function getAmountOutKyber(address fromToken, address toToken, uint fromTokenAmount) external view returns (uint) {
    uint rate;
    (rate,) = kyberProxy.getExpectedRate(ERC20(fromToken), ERC20(toToken), fromTokenAmount);
    uint amountOut = fromTokenAmount.mul(rate);
    return amountOut.div(1000000000000000000);
  }

  function swapEthForTokenKyber(address tokenAddress, uint ethAmount) internal returns (uint) {
    require(ethAmount <= address(this).balance, "Not enough Eth in contract to perform swap.");

    // Declare tokens involved in trade
    ERC20 eth = ERC20(ETH_MOCK_ADDRESS);
    ERC20 token = ERC20(tokenAddress);
    
    // Get the conversion rate
    uint minConversionRate;
    (minConversionRate, ) = kyberProxy.getExpectedRate(eth, token, ethAmount);
    require(minConversionRate != 0, "Trade is not possible at the moment.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint{ value: ethAmount }(eth, ethAmount, token, address(this), 10**18 * 10**6, minConversionRate, address(0), hint);
  }

  function swapTokenForEthKyber(address tokenAddress, uint tokenAmount) internal returns (uint) {
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
    (minConversionRate, ) = kyberProxy.getExpectedRate(token, eth, tokenAmount);
    require(minConversionRate != 0, "Trade is not possible at the moment.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint(token, tokenAmount, eth, address(this), 10**18 * 10**6, minConversionRate, address(0), hint);
  }

  function swapTokenForTokenKyber(address fromTokenAddress, address toTokenAddress, uint tokenAmount) internal returns (uint) {
    if (fromTokenAddress == ETH_MOCK_ADDRESS) {
      return swapEthForTokenKyber(toTokenAddress, tokenAmount);
    }
    
    if (toTokenAddress == ETH_MOCK_ADDRESS) {
      return swapTokenForEthKyber(fromTokenAddress, tokenAmount);
    }

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
    (minConversionRate, ) = kyberProxy.getExpectedRate(fromToken, toToken, tokenAmount);
    require(minConversionRate != 0, "Trade is not possible at the moment.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint(fromToken, tokenAmount, toToken, address(this), 10**18 * 10**6, minConversionRate, address(0), hint);
  }

  /*
    Arbitrage methods
  */
  function arbExecute(address stableCoin, address mediatorCoin, uint amount, string calldata sellDexBuyDex) external onlyOwner {
    // Serialize the command    
    bytes memory serializedCommand = abi.encode(mediatorCoin, sellDexBuyDex);

    // Call the flash loan function from Aave
    lendingPool.flashLoan(address(this), stableCoin, amount, serializedCommand);
  }

  function executeOperation(address _reserve, uint256 _amount, uint256 _fee, bytes calldata _params) external override {
    require(_amount <= getBalanceInternal(address(this), _reserve), "Invalid balance, was the flashLoan successful?");

    // Deserialize the parameters
    address mediatorCoin;
    string memory sellDexBuyDex;
    (mediatorCoin, sellDexBuyDex) = abi.decode(_params, (address, string));

    if (keccak256(bytes(sellDexBuyDex)) == keccak256("SELL_UNI_BUY_KYB")) {
      arbSellUniswapBuyKyber(_reserve, mediatorCoin, _amount);
    } else if (keccak256(bytes(sellDexBuyDex)) == keccak256("SELL_KYB_BUY_UNI")) {
      arbSellKyberBuyUniswap(_reserve, mediatorCoin, _amount);
    }

    uint totalDebt = _amount.add(_fee);
    transferFundsBackToPoolInternal(_reserve, totalDebt);
  }

  function arbSellUniswapBuyKyber(address tokenAddress, address mediatorAddress, uint tokenAmount) internal {
    // Sell on Uniswap
    uint mediatorTokenAmount = swapTokenForTokenUniswap(tokenAddress, mediatorAddress, tokenAmount);

    // Buy on Kyber
    swapTokenForTokenKyber(mediatorAddress, tokenAddress, mediatorTokenAmount);

    // TODO: Revert if no profit was made
  }

  function arbSellKyberBuyUniswap(address tokenAddress, address mediatorAddress, uint tokenAmount) internal {
    // Sell on Kyber
    uint mediatorTokenAmount = swapTokenForTokenKyber(tokenAddress, mediatorAddress, tokenAmount);

    // Buy on Uniswap
    swapTokenForTokenUniswap(mediatorAddress, tokenAddress, mediatorTokenAmount);

    // TODO: Revert if no profit was made
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
    withdraw(ETHER);
  }
}