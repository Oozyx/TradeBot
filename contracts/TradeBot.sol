pragma solidity ^0.6.0;

import "./interfaces/IUniswapV2Router01.sol";
import "./interfaces/KyberNetworkProxyInterface.sol";
import "./interfaces/UniswapFactoryInterface.sol";
import "./interfaces/UniswapExchangeInterface.sol";
import "./interfaces/GasToken.sol";
import "./libs/UniswapV2Library.sol";
import "./utils/Withdrawable.sol";

contract TradeBot is Withdrawable {
  /*
    Constants
  */
  address internal constant UNISWAPV2_FACTORY_ADDRESS = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f; // Mainnet
  address internal constant UNISWAPV2_ROUTER_ADDRESS  = 0xf164fC0Ec4E93095b804a4795bBe1e041497b92a; // Mainnet
  address internal constant UNISWAPV1_FACTORY_ADDRESS = 0xc0a47dFe034B400B47bDaD5FecDa2621de6c4d95; // Mainnet
  address internal constant KYBER_PROXY_ADDRESS       = 0x818E6FECD516Ecc3849DAf6845e3EC868087B755; // Mainnet
  address internal constant GAS_TOKEN_ADDRESS         = 0x0000000000b3F879cb30FE243b4Dfee438691c04; // Mainnet
  address internal constant ETH_MOCK_ADDRESS          = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  
  /*
    Members
  */
  IUniswapV2Router01         internal immutable uniswapV2Router;
  UniswapFactoryInterface    internal immutable uniswapV1Factory;
  KyberNetworkProxyInterface internal immutable kyberProxy;

  /*
    Events
  */
  // event Log(string log);

  /*
    Constructors
  */
  constructor() public {
    uniswapV2Router  = IUniswapV2Router01(UNISWAPV2_ROUTER_ADDRESS);
    uniswapV1Factory = UniswapFactoryInterface(UNISWAPV1_FACTORY_ADDRESS);
    kyberProxy       = KyberNetworkProxyInterface(KYBER_PROXY_ADDRESS);
  }

  /*
    UniswapV1 methods
  */
  function getAmountOutUniswapV1(address fromToken, address toToken, uint fromTokenAmount) external view returns (uint) {
    if (fromToken == ETH_MOCK_ADDRESS) {
      return UniswapExchangeInterface(uniswapV1Factory.getExchange(toToken)).getEthToTokenInputPrice(fromTokenAmount);
    }

    if (toToken == ETH_MOCK_ADDRESS) {
      return UniswapExchangeInterface(uniswapV1Factory.getExchange(fromToken)).getTokenToEthInputPrice(fromTokenAmount);
    }
  }

  function swapEthForTokenUniswapV1(address tokenAddress, uint ethAmount) internal returns (uint) {
    // Get the exchange
    UniswapExchangeInterface exchange = UniswapExchangeInterface(uniswapV1Factory.getExchange(tokenAddress));

    // Make the swap
    return exchange.ethToTokenSwapInput{ value: ethAmount }(1, now);
  }

  function swapTokenForEthUniswapV1(address tokenAddress, uint tokenAmount) internal returns (uint) {
    // Get the exchange
    UniswapExchangeInterface exchange = UniswapExchangeInterface(uniswapV1Factory.getExchange(tokenAddress));

    // Approve the exchange
    ERC20 token = ERC20(tokenAddress);
    token.approve(address(exchange), tokenAmount);

    // Make the swap
    return exchange.tokenToEthSwapInput(tokenAmount, 1, now);
  }

  function swapTokenForTokenUniswapV1(address fromTokenAddress, address toTokenAddress, uint tokenAmount) internal returns (uint) {    
    if (fromTokenAddress == ETH_MOCK_ADDRESS) {
      return swapEthForTokenUniswapV1(toTokenAddress, tokenAmount);
    }
    
    if (toTokenAddress == ETH_MOCK_ADDRESS) {
      return swapTokenForEthUniswapV1(fromTokenAddress, tokenAmount);
    }
  }

  /*
    Uniswap V2 methods
  */
  function getAmountOutUniswapV2(address fromToken, address toToken, uint fromTokenAmount) external view returns (uint) {
    uint fromTokenReserves;
    uint toTokenReserves;
    if (fromToken == ETH_MOCK_ADDRESS) {
      fromToken = uniswapV2Router.WETH();
    }
    if (toToken == ETH_MOCK_ADDRESS) {
      toToken = uniswapV2Router.WETH();
    }
    (fromTokenReserves, toTokenReserves) = UniswapV2Library.getReserves(UNISWAPV2_FACTORY_ADDRESS, fromToken, toToken);

    return UniswapV2Library.getAmountOut(fromTokenAmount, fromTokenReserves, toTokenReserves);
  }

  function swapEthForTokenUniswapV2(address tokenAddress, uint ethAmount) internal returns (uint) {
    // Build arguments for uniswap router call
    address[] memory path = new address[](2);
    path[0] = uniswapV2Router.WETH();
    path[1] = tokenAddress;

    // Make the call
    uint[] memory result = uniswapV2Router.swapExactETHForTokens{ value: ethAmount }(0, path, address(this), now);
    return result[1]; // Returns the output amount
  }

  function swapTokenForEthUniswapV2(address tokenAddress, uint tokenAmount) internal returns (uint) {
    // Approve uniswap to manage contract tokens
    ERC20 token = ERC20(tokenAddress);
    token.approve(address(uniswapV2Router), token.balanceOf(address(this)));

    // Build arguments for uniswap router call
    address[] memory path = new address[](2);
    path[0] = tokenAddress;
    path[1] = uniswapV2Router.WETH();

    // Make the call
    uint[] memory result = uniswapV2Router.swapExactTokensForETH(tokenAmount, 0, path, address(this), now);
    return result[1]; // Returns the output amount
  }

  function swapTokenForTokenUniswapV2(address fromTokenAddress, address toTokenAddress, uint tokenAmount) internal returns (uint) {
    if (fromTokenAddress == ETH_MOCK_ADDRESS) {
      return swapEthForTokenUniswapV2(toTokenAddress, tokenAmount);
    }
    
    if (toTokenAddress == ETH_MOCK_ADDRESS) {
      return swapTokenForEthUniswapV2(fromTokenAddress, tokenAmount);
    }
    
    // Approve uniswap to manage contract Dai
    ERC20 fromToken = ERC20(fromTokenAddress);
    fromToken.approve(address(uniswapV2Router), tokenAmount);

    // Build arguments for uniswap router call
    address[] memory path = new address[](2);
    path[0] = fromTokenAddress;
    path[0] = toTokenAddress;

    // Make the call
    uint[] memory result = uniswapV2Router.swapExactTokensForTokens(tokenAmount, 0, path, address(this), now);
    return result[1];    
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
    // Declare tokens involved in trade
    ERC20 eth = ERC20(ETH_MOCK_ADDRESS);
    ERC20 token = ERC20(tokenAddress);

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint{ value: ethAmount }(eth, ethAmount, token, address(this), 10**18 * 10**6, 0, address(0), hint);
  }

  function swapTokenForEthKyber(address tokenAddress, uint tokenAmount) internal returns (uint) {
    // Verify we have enough funds
    ERC20 eth = ERC20(ETH_MOCK_ADDRESS);
    ERC20 token = ERC20(tokenAddress);

    // Set the spender's token allowance to tokenQty
    require(token.approve(KYBER_PROXY_ADDRESS, tokenAmount), "Failure to approve sender for token amount.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint(token, tokenAmount, eth, address(this), 10**18 * 10**6, 0, address(0), hint);
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

    // Set the spender's token allowance to daiAmount
    require(fromToken.approve(KYBER_PROXY_ADDRESS, tokenAmount), "Failure to approve sender for dai amount.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint(fromToken, tokenAmount, toToken, address(this), 10**18 * 10**6, 0, address(0), hint);
  }

  /*
    Arbitrage methods
  */
  function arbExecute(address stableCoin, address mediatorCoin, uint amount, string memory sellDexBuyDex, uint gasTokenAmount) virtual public onlyOwner {
    if (gasTokenAmount > 0) {
      // Burn the gas token
      require(GasToken(GAS_TOKEN_ADDRESS).freeFromUpTo(msg.sender, gasTokenAmount) > 0, "Failed to free gas token.");
    }

    if (keccak256(bytes(sellDexBuyDex)) == keccak256("SELL_UV2_BUY_KYB")) {
      swapTokenForTokenKyber(mediatorCoin, stableCoin, swapTokenForTokenUniswapV2(stableCoin, mediatorCoin, amount));
    } else if (keccak256(bytes(sellDexBuyDex)) == keccak256("SELL_UV2_BUY_UV1")) {
      swapTokenForTokenUniswapV1(mediatorCoin, stableCoin, swapTokenForTokenUniswapV2(stableCoin, mediatorCoin, amount));
    } else if (keccak256(bytes(sellDexBuyDex)) == keccak256("SELL_KYB_BUY_UV2")) {
      swapTokenForTokenUniswapV2(mediatorCoin, stableCoin, swapTokenForTokenKyber(stableCoin, mediatorCoin, amount));
    } else if (keccak256(bytes(sellDexBuyDex)) == keccak256("SELL_KYB_BUY_UV1")) {
      swapTokenForTokenUniswapV1(mediatorCoin, stableCoin, swapTokenForTokenKyber(stableCoin, mediatorCoin, amount));
    } else if (keccak256(bytes(sellDexBuyDex)) == keccak256("SELL_UV1_BUY_UV2")) {
      swapTokenForTokenUniswapV2(mediatorCoin, stableCoin, swapTokenForTokenUniswapV1(stableCoin, mediatorCoin, amount));
    } else if (keccak256(bytes(sellDexBuyDex)) == keccak256("SELL_UV1_BUY_KYB")) {
      swapTokenForTokenKyber(mediatorCoin, stableCoin, swapTokenForTokenUniswapV1(stableCoin, mediatorCoin, amount));
    }
  }

  /*
    Deposit and Withdrawal methods
  */
  function depositEth() external payable {
    // Nothing to do
  }

  function withdrawEth() external onlyOwner {
    withdraw(ETHER);
  }

  receive() payable external {}
}