pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router01.sol";
import "./interfaces/KyberNetworkProxyInterface.sol";
import "./interfaces/FlashLoanReceiverBase.sol";
import "./interfaces/ILendingPool.sol";

contract TradeBot is FlashLoanReceiverBase {
  /*
    Constants
  */
  address private constant  UNISWAP_FACTORY_ADDRESS = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f; // Ropsten
  address private constant  UNISWAP_ROUTER_ADDRESS  = 0xf164fC0Ec4E93095b804a4795bBe1e041497b92a; // Ropsten
  address private constant  KYBER_PROXY_ADDRESS     = 0x818E6FECD516Ecc3849DAf6845e3EC868087B755; // Ropsten
  address private constant  ETH_MOCK_ADDRESS        = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  address private constant  AAVE_ADDRESSES_PROVIDER = 0x1c8756FD2B28e9426CDBDcC7E3c4d64fa9A54728; // Ropsten
  
  /*
    Members
  */
  IUniswapV2Factory             private immutable uniswapFactory;
  IUniswapV2Router01            private immutable uniswapRouter;
  KyberNetworkProxyInterface    private immutable kyberProxy;
  ILendingPool                  private immutable lendingPool;

  /*
    Events
  */
  // event Log(string log);

  /*
    Constructors
  */
  constructor() FlashLoanReceiverBase(AAVE_ADDRESSES_PROVIDER) public {
    uniswapFactory = IUniswapV2Factory(UNISWAP_FACTORY_ADDRESS);
    uniswapRouter  = IUniswapV2Router01(UNISWAP_ROUTER_ADDRESS);
    kyberProxy     = KyberNetworkProxyInterface(KYBER_PROXY_ADDRESS);
    lendingPool    = ILendingPool(addressesProvider.getLendingPool());
  }

  /*
    Uniswap methods
  */
  function swapEthForTokenUniswap(address tokenAddress, uint ethAmount) internal returns (uint) {
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

  function swapTokenForEthUniswap(address tokenAddress, uint tokenAmount) internal returns (uint) {
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

  function swapTokenForTokenUniswap(address fromTokenAddress, address toTokenAddress, uint tokenAmount) public returns (uint) {
    if (fromTokenAddress == ETH_MOCK_ADDRESS) {
      return swapEthForTokenUniswap(toTokenAddress, tokenAmount);
    }
    
    if (toTokenAddress == ETH_MOCK_ADDRESS) {
      return swapTokenForEthUniswap(fromTokenAddress, tokenAmount);
    }
    
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
  function swapEthForTokenKyber(address tokenAddress, uint ethAmount) internal returns (uint) {
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
    uint slippageRate;
    (minConversionRate, slippageRate) = kyberProxy.getExpectedRate(token, eth, tokenAmount);
    require(minConversionRate != 0 || slippageRate != 0, "Trade is not possible at the moment.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint(token, tokenAmount, eth, address(this), 10**18 * 10**6, minConversionRate, address(0), hint);
  }

  function swapTokenForTokenKyber(address fromTokenAddress, address toTokenAddress, uint tokenAmount) public returns (uint) {
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
    uint slippageRate;
    (minConversionRate, slippageRate) = kyberProxy.getExpectedRate(fromToken, toToken, tokenAmount);
    require(minConversionRate != 0 || slippageRate != 0, "Trade is not possible at the moment.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    return kyberProxy.tradeWithHint(fromToken, tokenAmount, toToken, address(this), 10**18 * 10**6, minConversionRate, address(0), hint);
  }

  /*
    Arbitrage methods
  */
  function arbExecute(address stableCoin, address mediatorCoin, uint amount, string memory sellDexBuyDex) public onlyOwner {
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