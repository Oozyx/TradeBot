pragma solidity ^0.6.0;

import "./interfaces/ERC20.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IUniswapV2Router01.sol";
import "./interfaces/KyberNetworkProxyInterface.sol";
import "./interfaces/ILendingPoolAddressesProvider.sol";
import "./interfaces/ILendingPool.sol";
import "./interfaces/AToken.sol";

contract TradeBot {
  /*
    Constants
  */
  address private constant  UNISWAP_ROUTER_ADDRESS  = 0xcDbE04934d89e97a24BCc07c3562DC8CF17d8167; // Rinkeby
  address private constant  UNISWAP_FACTORY_ADDRESS = 0xe2f197885abe8ec7c866cFf76605FD06d4576218; // Rinkeby
  address private constant  KYBER_PROXY_ADDRESS     = 0xF77eC7Ed5f5B9a5aee4cfa6FFCaC6A4C315BaC76; // Rinkeby
  address private constant  ETH_MOCK_ADDRESS        = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  address private constant  AAVE_ADDRESSES_PROVIDER = 0x1c8756FD2B28e9426CDBDcC7E3c4d64fa9A54728; // Ropsten
  uint    private constant  TOKEN_18_DECIMALS       = (10**18);
  
  /*
    Members
  */
  address                       private immutable owner;
  IUniswapV2Factory             private immutable uniswapFactory;
  IUniswapV2Router01            private immutable uniswapRouter;
  KyberNetworkProxyInterface    private immutable kyberProxy;
  ILendingPoolAddressesProvider private immutable aaveAddressesProvider;

  /*
    Events
  */
  event Log(string log);

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
  }

  /*
    Aave methods
  */
  function depositEthAave(uint ethAmount) public onlyOwner {
    // Verify we have enough funds
    require(ethAmount * TOKEN_18_DECIMALS <= address(this).balance, "Not enough Eth in contract to deposit into Aave.");

    // Make the call
    ILendingPool lendingPool = ILendingPool(aaveAddressesProvider.getLendingPool());
    lendingPool.deposit{ value: ethAmount * TOKEN_18_DECIMALS }(ETH_MOCK_ADDRESS, ethAmount * TOKEN_18_DECIMALS, 0);
  }

  function withdrawEthAave(uint ethAmount) public onlyOwner {
    // Get the aToken address
    address aTokenEthAddress;
    ILendingPool lendingPool = ILendingPool(aaveAddressesProvider.getLendingPool());
    (,,,,,,,,,,, aTokenEthAddress,) = lendingPool.getReserveData(ETH_MOCK_ADDRESS);

    // Verify if the withdrawal is allowed
    AToken aTokenEth = AToken(aTokenEthAddress);
    require(aTokenEth.isTransferAllowed(address(this), ethAmount * TOKEN_18_DECIMALS), "Withdrawal is not allowed.");

    // Make the call
    aTokenEth.redeem(ethAmount * TOKEN_18_DECIMALS);
  }

  function depositTokenAave(address tokenAddress, uint tokenAmount) public onlyOwner {
    // Verify we have enough funds
    ERC20 token = ERC20(tokenAddress);
    require(tokenAmount * TOKEN_18_DECIMALS <= token.balanceOf(address(this)), "Not enough tokens in contract to deposit.");

    // Give approval to Aave to transfer my tokens
    ILendingPool lendingPool = ILendingPool(aaveAddressesProvider.getLendingPool());
    token.approve(address(lendingPool), tokenAmount * TOKEN_18_DECIMALS);

    // Make the call
    lendingPool.deposit(tokenAddress, tokenAmount * TOKEN_18_DECIMALS, 0);
  }

  function withdrawTokenAave(address tokenAddress, uint tokenAmount) public onlyOwner {
    // Get the aToken address
    address aTokenAddress;
    ILendingPool lendingPool = ILendingPool(aaveAddressesProvider.getLendingPool());
    (,,,,,,,,,,, aTokenAddress,) = lendingPool.getReserveData(tokenAddress);

    // Verify if the withdrawal is allowed
    AToken atoken = AToken(aTokenAddress);
    require(atoken.isTransferAllowed(address(this), tokenAmount * TOKEN_18_DECIMALS), "Withdrawal is not allowed.");

    // Make the call
    atoken.redeem(tokenAmount * TOKEN_18_DECIMALS);
  }

  /*
    Uniswap methods
  */
  function swapEthForTokenUniswap(address tokenAddress, uint ethAmount) public onlyOwner {
    // Verify we have enough funds
    require(ethAmount * TOKEN_18_DECIMALS <= address(this).balance, "Not enough Eth in contract to perform swap.");

    // Build arguments for uniswap router call
    address[] memory path = new address[](2);
    path[0] = uniswapRouter.WETH();
    path[1] = tokenAddress;

    // Make the call
    uniswapRouter.swapExactETHForTokens{ value: ethAmount * TOKEN_18_DECIMALS }(0, path, address(this), now);
  }

  function swapTokenForEtherUniswap(address tokenAddress, uint tokenAmount) public onlyOwner {
    // Verify we have enough funds
    ERC20 token = ERC20(tokenAddress);
    require(tokenAmount * TOKEN_18_DECIMALS <= token.balanceOf(address(this)), "Not enough tokens in contract to perform swap.");

    // Approve uniswap to manage contract tokens
    token.approve(address(uniswapRouter), token.balanceOf(address(this)));

    // Build arguments for uniswap router call
    address[] memory path = new address[](2);
    path[0] = tokenAddress;
    path[1] = uniswapRouter.WETH();

    // Make the call
    uniswapRouter.swapExactTokensForETH(tokenAmount * TOKEN_18_DECIMALS, 0, path, address(this), now);
  }

  /*
    Kyber methods
  */
  function swapEthForTokenKyber(address tokenAddress, uint ethAmount) public onlyOwner {
    require(ethAmount * TOKEN_18_DECIMALS <= address(this).balance, "Not enough Eth in contract to perform swap.");

    // Declare tokens involved in trade
    ERC20 eth = ERC20(ETH_MOCK_ADDRESS);
    ERC20 token = ERC20(tokenAddress);
    
    // Get the conversion rate
    uint minConversionRate;
    uint slippageRate;
    (minConversionRate, slippageRate) = kyberProxy.getExpectedRate(eth, token, ethAmount * TOKEN_18_DECIMALS);
    require(minConversionRate != 0 || slippageRate != 0, "Trade is not possible at the moment.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    kyberProxy.tradeWithHint{ value: ethAmount * TOKEN_18_DECIMALS }(eth, ethAmount * TOKEN_18_DECIMALS, token, address(this), 10**18 * 10**6, minConversionRate, address(0), hint);
  }

  function swapTokenForEtherKyber(address tokenAddress, uint tokenAmount) public onlyOwner {
    // Verify we have enough funds
    ERC20 eth = ERC20(ETH_MOCK_ADDRESS);
    ERC20 token = ERC20(tokenAddress);
    require(tokenAmount * TOKEN_18_DECIMALS <= token.balanceOf(address(this)), "Not enough tokens in contract to perform swap.");

    // Mitigate ERC20 Approve front-running attack, by initially setting allowance to 0
    require(token.approve(KYBER_PROXY_ADDRESS, 0), "Failure to approve sender front running attack.");

    // Set the spender's token allowance to tokenQty
    require(token.approve(KYBER_PROXY_ADDRESS, tokenAmount * TOKEN_18_DECIMALS), "Failure to approve sender for token amount.");

    // Get the conversion rate
    uint minConversionRate;
    uint slippageRate;
    (minConversionRate, slippageRate) = kyberProxy.getExpectedRate(token, eth, tokenAmount * TOKEN_18_DECIMALS);
    require(minConversionRate != 0 || slippageRate != 0, "Trade is not possible at the moment.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    kyberProxy.tradeWithHint(token, tokenAmount * TOKEN_18_DECIMALS, eth, address(this), 10**18 * 10**6, minConversionRate, address(0), hint);
  }

  /*
    Deposit and Withdrawal methods
  */
  function depositEth() external payable {
    // Nothing to do
  }

  function depositToken(address tokenAddress, uint tokenAmount) external {
    ERC20 token = ERC20(tokenAddress);
    require (tokenAmount * TOKEN_18_DECIMALS <= token.balanceOf(msg.sender), "Deposit amount exceeds holding amount.");
    token.transferFrom(msg.sender, address(this), tokenAmount * TOKEN_18_DECIMALS);
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