pragma solidity ^0.6.0;

import "./interfaces/ERC20.sol";
import "./interfaces/KyberNetworkProxyInterface.sol";

// Necessary imports for Uniswap V1
import "./interfaces/UniswapFactoryInterface.sol";
import "./interfaces/UniswapExchangeInterface.sol";

contract TradeBot {
  /*
    Constants
  */
  address internal constant  UNISWAP_FACTORY_ADDRESS = 0xc0a47dFe034B400B47bDaD5FecDa2621de6c4d95; // Mainnet
  address internal constant  KYBER_PROXY_ADDRESS     = 0x818E6FECD516Ecc3849DAf6845e3EC868087B755; // Mainnet
  address internal constant  ETH_MOCK_ADDRESS        = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  
  /*
    Members
  */
  address                       internal immutable owner;
  UniswapFactoryInterface       internal immutable uniswapFactory;
  KyberNetworkProxyInterface    internal immutable kyberProxy;
  mapping(address => address)   internal uniswapExchanges;

  /*
    Modifiers
  */
  modifier onlyOwner() {
    require (
      msg.sender == owner,
      "Not owner."
    );
    _;
  }

  /*
    Constructors
  */
  constructor() public {
    owner            = msg.sender;
    uniswapFactory   = UniswapFactoryInterface(UNISWAP_FACTORY_ADDRESS);
    kyberProxy       = KyberNetworkProxyInterface(KYBER_PROXY_ADDRESS);
  }

  function tokenApprovals(address[] calldata tokenAddresses) external {
    for (uint i = 0; i < tokenAddresses.length; i++) {
      // Aprove Kyber
      ERC20(tokenAddresses[i]).approve(KYBER_PROXY_ADDRESS, 10**18 * 10**6);
      
      // Approve Uniswap
      // Get the exchange
      UniswapExchangeInterface exchange = UniswapExchangeInterface(uniswapFactory.getExchange(tokenAddresses[i]));
      uniswapExchanges[tokenAddresses[i]] = address(exchange);
    
      // Approve uniswap for transferring our tokens
      ERC20(tokenAddresses[i]).approve(address(exchange), 10**18 * 10**6);
    }
  }

  /*
    Uniswap methods
  */
  function getAmountOutUniswap(address fromToken, address toToken, uint fromTokenAmount) external view returns (uint) {
    if (fromToken == ETH_MOCK_ADDRESS) {
      return UniswapExchangeInterface(uniswapExchanges[toToken]).getEthToTokenInputPrice(fromTokenAmount);
    }

    if (toToken == ETH_MOCK_ADDRESS) {
      return UniswapExchangeInterface(uniswapExchanges[fromToken]).getTokenToEthInputPrice(fromTokenAmount);
    }
  }

  function swapEthForTokenUniswap(address tokenAddress, uint ethAmount) internal returns (uint) {
    // Get the exchange
    UniswapExchangeInterface exchange = UniswapExchangeInterface(uniswapExchanges[tokenAddress]);

    // Make the swap
    return exchange.ethToTokenSwapInput{ value: ethAmount }(1, now);
  }

  function swapTokenForEthUniswap(address tokenAddress, uint tokenAmount) internal returns (uint) {
    // Get the exchange
    UniswapExchangeInterface exchange = UniswapExchangeInterface(uniswapExchanges[tokenAddress]);

    // Make the swap
    return exchange.tokenToEthSwapInput(tokenAmount, 1, now);
  }

  function swapTokenForTokenUniswap(address fromTokenAddress, address toTokenAddress, uint tokenAmount) internal returns (uint) {    
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
  function getExpectedRateKyber(address fromToken, address toToken, uint fromTokenAmount) external view returns (uint) {
    uint rate;
    (rate,) = kyberProxy.getExpectedRate(ERC20(fromToken), ERC20(toToken), fromTokenAmount);
    return rate;
  }

  function swapEthForTokenKyber(address tokenAddress, uint ethAmount) internal returns (uint) {
    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint{ value: ethAmount }(
        ERC20(ETH_MOCK_ADDRESS),
        ethAmount,
        ERC20(tokenAddress),
        address(this),
        10**18 * 10**6,
        0,
        0x27FB3d86Cc42c710Cb049B9066d337C6A6F151A2,
        hint
      );
  }

  function swapTokenForEthKyber(address tokenAddress, uint tokenAmount) internal returns (uint) {
    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint(
        ERC20(tokenAddress),
        tokenAmount,
        ERC20(ETH_MOCK_ADDRESS),
        address(this),
        10**18 * 10**6,
        0,
        0x27FB3d86Cc42c710Cb049B9066d337C6A6F151A2,
        hint
      );
  }

  function swapTokenForTokenKyber(address fromTokenAddress, address toTokenAddress, uint tokenAmount) internal returns (uint) {
    if (fromTokenAddress == ETH_MOCK_ADDRESS) {
      return swapEthForTokenKyber(toTokenAddress, tokenAmount);
    }
    
    if (toTokenAddress == ETH_MOCK_ADDRESS) {
      return swapTokenForEthKyber(fromTokenAddress, tokenAmount);
    }
  }

  /*
    Arbitrage methods
  */

  function arbSellUniswapBuyKyber(address tokenAddress, address mediatorAddress, uint tokenAmount) external {
    swapTokenForTokenKyber(mediatorAddress, tokenAddress, swapTokenForTokenUniswap(tokenAddress, mediatorAddress, tokenAmount));
  }

  function arbSellKyberBuyUniswap(address tokenAddress, address mediatorAddress, uint tokenAmount) external {
    swapTokenForTokenUniswap(mediatorAddress, tokenAddress, swapTokenForTokenKyber(tokenAddress, mediatorAddress, tokenAmount));
  }

  /*
    Deposit and Withdrawal methods
  */
  function depositEth() external payable {
    // Nothing to do
  }

  function depositToken(address tokenAddress, uint tokenAmount) external {
    ERC20(tokenAddress).transferFrom(msg.sender, address(this), tokenAmount);
  }

  function withdrawEth() external onlyOwner {
    msg.sender.transfer(address(this).balance);
  }

  receive() external payable {
    // Nothing to do
  }
}