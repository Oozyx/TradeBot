pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./interfaces/IUniswapV2Router01.sol";
import "./interfaces/KyberNetworkProxyInterface.sol";
import "./interfaces/FlashLoanReceiverBase.sol";
import "./interfaces/ILendingPool.sol";

contract TradeBot is FlashLoanReceiverBase {
  /*
    Constants
  */
  address private constant  UNISWAP_ROUTER_ADDRESS  = 0xcDbE04934d89e97a24BCc07c3562DC8CF17d8167; // Rinkeby
  address private constant  KYBER_PROXY_ADDRESS     = 0xF77eC7Ed5f5B9a5aee4cfa6FFCaC6A4C315BaC76; // Rinkeby
  address private constant  ETH_MOCK_ADDRESS        = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  address private constant  AAVE_ADDRESSES_PROVIDER = 0x1c8756FD2B28e9426CDBDcC7E3c4d64fa9A54728; // Ropsten
  
  /*
    Members
  */
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
    uniswapRouter  = IUniswapV2Router01(UNISWAP_ROUTER_ADDRESS);
    kyberProxy     = KyberNetworkProxyInterface(KYBER_PROXY_ADDRESS);
    lendingPool    = ILendingPool(addressesProvider.getLendingPool());
  }

  /*
    Aave methods
  */
  function executeOperation(address _reserve, uint256 _amount, uint256 _fee, bytes calldata _params) external override {
    require(_amount <= getBalanceInternal(address(this), _reserve), "Invalid balance, was the flashLoan successful?");

    // Deserialize the parameters
    address mediatorCoin;
    string memory sellDexBuyDex;
    (mediatorCoin, sellDexBuyDex) = abi.decode(_params, (address, string));

    // if (keccak256(bytes(parameters.sellDex)) == keccak256("UNI") && keccak256(bytes(parameters.buyDex)) == keccak256("KYB")) {
    //   arbSellUniswapBuyKyber(_reserve, parameters.mediatorCoin, _amount);
    // } else if (keccak256(bytes(parameters.sellDex)) == keccak256("KYB") && keccak256(bytes(parameters.buyDex)) == keccak256("UNI")) {
    //   arbSellKyberBuyUniswap(_reserve, parameters.mediatorCoin, _amount);
    // }

    uint totalDebt = _amount.add(_fee);
    transferFundsBackToPoolInternal(_reserve, totalDebt);
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

  function swapTokenForTokenUniswap(address fromTokenAddress, address toTokenAddress, uint tokenAmount) public onlyOwner returns (uint) {
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
    Arbitrage methods
  */
  function arbExecute(address stableCoin, address mediatorCoin, uint amount, string memory sellDexBuyDex) public onlyOwner {
    // Serialize the command    
    bytes memory serializedCommand = abi.encode(mediatorCoin, sellDexBuyDex);

    // Call the flash loan function from Aave
    lendingPool.flashLoan(address(this), stableCoin, amount, serializedCommand);
  }

  function arbSellUniswapBuyKyber(address tokenAddress, address mediatorAddress, uint tokenAmount) public onlyOwner {
    // Make sure we have enough tokens to perform the trade
    ERC20 token = ERC20(tokenAddress);
    require(tokenAmount <= token.balanceOf(address(this)), "Not enough tokens in contract to perform trade.");

    // Sell on Uniswap
    uint mediatorTokenAmount = swapTokenForTokenUniswap(tokenAddress, mediatorAddress, tokenAmount);

    // Buy on Kyber
    uint newTokenAmount = swapTokenForTokenKyber(mediatorAddress, tokenAddress, mediatorTokenAmount);

    // Revert if no profit was made
    require(newTokenAmount > tokenAmount, "Reverted: no profit made.");
  }

  function arbSellKyberBuyUniswap(address tokenAddress, address mediatorAddress, uint tokenAmount) public onlyOwner {
    // Make sure we have enough tokens to perform the trade
    ERC20 token = ERC20(tokenAddress);
    require(tokenAmount <= token.balanceOf(address(this)), "Not enough tokens in contract to perform trade.");

    // Sell on Kyber
    uint mediatorTokenAmount = swapTokenForTokenKyber(tokenAddress, mediatorAddress, tokenAmount);

    // Buy on Uniswap
    uint newTokenAmount = swapTokenForTokenUniswap(mediatorAddress, tokenAddress, mediatorTokenAmount);

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
    withdraw(ETHER);
  }
}