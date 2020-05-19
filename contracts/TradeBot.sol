pragma solidity ^0.6.0;

import "./interfaces/ERC20.sol";
import "./interfaces/KyberNetworkProxyInterface.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Router01.sol";
import "./interfaces/IBancorNetwork.sol";
import "./interfaces/IContractRegistry.sol";
import "./interfaces/BancorNetworkPathFinder.sol";
import "./libs/UniswapV2Library.sol";


contract TradeBot {
  /*
    Constants
  */
  address internal constant  UNISWAP_FACTORY_ADDRESS = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f; // Mainnet
  address internal constant  UNISWAP_ROUTER_ADDRESS  = 0xf164fC0Ec4E93095b804a4795bBe1e041497b92a; // Mainnet
  address internal constant  KYBER_PROXY_ADDRESS     = 0x818E6FECD516Ecc3849DAf6845e3EC868087B755; // Mainnet
  address internal constant  BANCOR_REGISTRY_ADDRESS = 0x52Ae12ABe5D8BD778BD5397F99cA900624CfADD4; // Mainnet
  address internal constant  ETH_BANCOR_ADDRESS      = 0xc0829421C1d260BD3cB3E0F06cfE2D52db2cE315; // Mainnet
  address internal constant  ETH_MOCK_ADDRESS        = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  
  /*
    Members
  */
  address                       internal immutable owner;
  IUniswapV2Factory             internal immutable uniswapFactory;
  IUniswapV2Router01            internal immutable uniswapRouter;
  KyberNetworkProxyInterface    internal immutable kyberProxy;
  IBancorNetwork                internal immutable bancorNetwork;
  BancorNetworkPathFinder       internal immutable bancorPathFinder;

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
    uniswapFactory   = IUniswapV2Factory(UNISWAP_FACTORY_ADDRESS);
    uniswapRouter    = IUniswapV2Router01(UNISWAP_ROUTER_ADDRESS);
    kyberProxy       = KyberNetworkProxyInterface(KYBER_PROXY_ADDRESS);
    bancorNetwork    = IBancorNetwork(IContractRegistry(BANCOR_REGISTRY_ADDRESS).addressOf(bytes32("BancorNetwork")));
    bancorPathFinder = BancorNetworkPathFinder(IContractRegistry(BANCOR_REGISTRY_ADDRESS).addressOf(bytes32("BancorNetworkPathFinder")));
  }

  /*
    Bancor methods
  */
  function getAmountOutBancor(address fromToken, address toToken, uint fromTokenAmount) external view returns (uint) {
    // Get the right eth address
    if (fromToken == ETH_MOCK_ADDRESS) {
      fromToken = ETH_BANCOR_ADDRESS;
    }
    if (toToken == ETH_MOCK_ADDRESS) {
      toToken = ETH_BANCOR_ADDRESS;
    }

    // Get the network path
    address[] memory path = bancorPathFinder.generatePath(fromToken, toToken);
    
    uint amountOut;
    uint fee;
    (amountOut, fee) = bancorNetwork.getReturnByPath(path, fromTokenAmount);
    return amountOut - fee;
  }

  function swapEthForTokenBancor(address tokenAddress, uint ethAmount) internal returns (uint) {
    // Get the network path
    address[] memory path = bancorPathFinder.generatePath(ETH_BANCOR_ADDRESS, tokenAddress);

    // Make the trade
    return bancorNetwork.convert2{ value: ethAmount }(path, ethAmount, 1, address(0), 0);
  }

  function swapTokenForEthBancor(address tokenAddress, uint tokenAmount) internal returns (uint) {
    // Get the network path
    address[] memory path = bancorPathFinder.generatePath(tokenAddress, ETH_BANCOR_ADDRESS);

    // Approve token amount
    ERC20(tokenAddress).approve(address(bancorNetwork), tokenAmount);

    // Make the trade
    return bancorNetwork.claimAndConvert2(path, tokenAmount, 1, address(0), 0);
  }

  function swapTokenForTokenBancor(address fromTokenAddress, address toTokenAddress, uint tokenAmount) internal returns (uint) {
    if (fromTokenAddress == ETH_MOCK_ADDRESS) {
      return swapEthForTokenBancor(toTokenAddress, tokenAmount);
    }
    
    if (toTokenAddress == ETH_MOCK_ADDRESS) {
      return swapTokenForEthBancor(fromTokenAddress, tokenAmount);
    }
  }

  /*
    Uniswap methods
  */
  function getAmountOutUniswap(address fromToken, address toToken, uint fromTokenAmount) external view returns (uint) {
    uint fromTokenReserves;
    uint toTokenReserves;
    if (fromToken == ETH_MOCK_ADDRESS) {
      fromToken = uniswapRouter.WETH();
    }
    if (toToken == ETH_MOCK_ADDRESS) {
      toToken = uniswapRouter.WETH();
    }
    (fromTokenReserves, toTokenReserves) = UniswapV2Library.getReserves(UNISWAP_FACTORY_ADDRESS, fromToken, toToken);

    return UniswapV2Library.getAmountOut(fromTokenAmount, fromTokenReserves, toTokenReserves);
  }

  function swapEthForTokenUniswap(address tokenAddress, uint ethAmount) internal returns (uint) {
    // Build arguments for uniswap router call
    address[] memory path = new address[](2);
    path[0] = uniswapRouter.WETH();
    path[1] = tokenAddress;

    // Make the call
    //uint tokenAmountOut = getAmountOutUniswap(path[0], path[1], ethAmount);
    uint[] memory result = uniswapRouter.swapExactETHForTokens{ value: ethAmount }(0, path, address(this), now);
    return result[1]; // Returns the output amount
  }

  function swapTokenForEthUniswap(address tokenAddress, uint tokenAmount) internal returns (uint) {
    // Approve uniswap to manage contract tokens
    ERC20 token = ERC20(tokenAddress);
    token.approve(address(uniswapRouter), token.balanceOf(address(this)));

    // Build arguments for uniswap router call
    address[] memory path = new address[](2);
    path[0] = tokenAddress;
    path[1] = uniswapRouter.WETH();

    // Make the call
    //uint tokenAmountOut = getAmountOutUniswap(path[0], path[1], tokenAmount);
    uint[] memory result = uniswapRouter.swapExactTokensForETH(tokenAmount, 0, path, address(this), now);
    return result[1]; // Returns the output amount
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
    // Get the conversion rate
    uint minConversionRate;
    (minConversionRate, ) = kyberProxy.getExpectedRate(ERC20(ETH_MOCK_ADDRESS), ERC20(tokenAddress), ethAmount);
    require(minConversionRate != 0, "Trade is not possible at the moment.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint{ value: ethAmount }(
        ERC20(ETH_MOCK_ADDRESS),
        ethAmount,
        ERC20(tokenAddress),
        address(this),
        10**18 * 10**6,
        minConversionRate,
        0x27FB3d86Cc42c710Cb049B9066d337C6A6F151A2,
        hint
      );
  }

  function swapTokenForEthKyber(address tokenAddress, uint tokenAmount) internal returns (uint) {
    // Set the spender's token allowance to tokenQty
    ERC20(tokenAddress).approve(KYBER_PROXY_ADDRESS, tokenAmount);

    // Get the conversion rate
    uint minConversionRate;
    (minConversionRate, ) = kyberProxy.getExpectedRate(ERC20(tokenAddress), ERC20(ETH_MOCK_ADDRESS), tokenAmount);
    require(minConversionRate != 0, "Trade is not possible at the moment.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint(
        ERC20(tokenAddress),
        tokenAmount,
        ERC20(ETH_MOCK_ADDRESS),
        address(this),
        10**18 * 10**6,
        minConversionRate,
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

  function arbSellUniswapBuyBancor(address tokenAddress, address mediatorAddress, uint tokenAmount) external {
    swapTokenForTokenBancor(mediatorAddress, tokenAddress, swapTokenForTokenUniswap(tokenAddress, mediatorAddress, tokenAmount));
  }

  function arbSellKyberBuyUniswap(address tokenAddress, address mediatorAddress, uint tokenAmount) external {
    swapTokenForTokenUniswap(mediatorAddress, tokenAddress, swapTokenForTokenKyber(tokenAddress, mediatorAddress, tokenAmount));
  }

  function arbSellKyberBuyBancor(address tokenAddress, address mediatorAddress, uint tokenAmount) external {
    swapTokenForTokenBancor(mediatorAddress, tokenAddress, swapTokenForTokenKyber(tokenAddress, mediatorAddress, tokenAmount));
  }

  function arbSellBancorBuyUniswap(address tokenAddress, address mediatorAddress, uint tokenAmount) external {
    swapTokenForTokenUniswap(mediatorAddress, tokenAddress, swapTokenForTokenBancor(tokenAddress, mediatorAddress, tokenAmount));
  }

  function arbSellBancorBuyKyber(address tokenAddress, address mediatorAddress, uint tokenAmount) external {
    swapTokenForTokenKyber(mediatorAddress, tokenAddress, swapTokenForTokenBancor(tokenAddress, mediatorAddress, tokenAmount));
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