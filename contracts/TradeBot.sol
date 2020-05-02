pragma solidity ^0.6.0;

interface ERC20 {
    function totalSupply() external view returns (uint supply);
    function balanceOf(address _owner) external view returns (uint balance);
    function transfer(address _to, uint _value) external returns (bool success);
    function transferFrom(address _from, address _to, uint _value) external returns (bool success);
    function approve(address _spender, uint _value) external returns (bool success);
    function allowance(address _owner, address _spender) external view returns (uint remaining);
    function decimals() external view returns(uint digits);
    event Approval(address indexed _owner, address indexed _spender, uint _value);
}

interface IUniswapV2Factory {
  event PairCreated(address indexed token0, address indexed token1, address pair, uint);

  function getPair(address tokenA, address tokenB) external view returns (address pair);
  function allPairs(uint) external view returns (address pair);
  function allPairsLength() external view returns (uint);

  function feeTo() external view returns (address);
  function feeToSetter() external view returns (address);

  function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Pair {
  event Mint(address indexed sender, uint amount0, uint amount1);
  event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
  event Swap(
    address indexed sender,
    uint amount0In,
    uint amount1In,
    uint amount0Out,
    uint amount1Out,
    address indexed to
  );
  event Sync(uint112 reserve0, uint112 reserve1);

  function MINIMUM_LIQUIDITY() external pure returns (uint);
  function factory() external view returns (address);
  function token0() external view returns (address);
  function token1() external view returns (address);
  function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
  function price0CumulativeLast() external view returns (uint);
  function price1CumulativeLast() external view returns (uint);
  function kLast() external view returns (uint);

  function mint(address to) external returns (uint liquidity);
  function burn(address to) external returns (uint amount0, uint amount1);
  function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
  function skim(address to) external;
  function sync() external;

  function initialize(address, address) external;
}

interface IUniswapV2Router01 {
  function WETH() external view returns (address);

  function addLiquidity(
    address tokenA,
    address tokenB,
    uint amountADesired,
    uint amountBDesired,
    uint amountAMin,
    uint amountBMin,
    address to,
    uint deadline
  ) external returns (uint amountA, uint amountB, uint liquidity);
  function addLiquidityETH(
    address token,
    uint amountTokenDesired,
    uint amountTokenMin,
    uint amountETHMin,
    address to,
    uint deadline
  ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
  function removeLiquidity(
    address tokenA,
    address tokenB,
    uint liquidity,
    uint amountAMin,
    uint amountBMin,
    address to,
    uint deadline
  ) external returns (uint amountA, uint amountB);
  function removeLiquidityETH(
    address token,
    uint liquidity,
    uint amountTokenMin,
    uint amountETHMin,
    address to,
    uint deadline
  ) external returns (uint amountToken, uint amountETH);
  function removeLiquidityWithPermit(
    address tokenA,
    address tokenB,
    uint liquidity,
    uint amountAMin,
    uint amountBMin,
    address to,
    uint deadline,
    bool approveMax, uint8 v, bytes32 r, bytes32 s
  ) external returns (uint amountA, uint amountB);
  function removeLiquidityETHWithPermit(
    address token,
    uint liquidity,
    uint amountTokenMin,
    uint amountETHMin,
    address to,
    uint deadline,
    bool approveMax, uint8 v, bytes32 r, bytes32 s
  ) external returns (uint amountToken, uint amountETH);
  function swapExactTokensForTokens(
    uint amountIn,
    uint amountOutMin,
    address[] calldata path,
    address to,
    uint deadline
  ) external returns (uint[] memory amounts);
  function swapTokensForExactTokens(
    uint amountOut,
    uint amountInMax,
    address[] calldata path,
    address to,
    uint deadline
  ) external returns (uint[] memory amounts);
  function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
    external
    payable
    returns (uint[] memory amounts);
  function swapTokensForExactETH(uint amountOut, uint amountInMax, address[] calldata path, address to, uint deadline)
    external
    returns (uint[] memory amounts);
  function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
    external
    returns (uint[] memory amounts);
  function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, uint deadline)
    external
    payable
    returns (uint[] memory amounts);
}

interface KyberNetworkProxyInterface {
    function maxGasPrice() external view returns(uint);
    function getUserCapInWei(address user) external view returns(uint);
    function getUserCapInTokenWei(address user, ERC20 token) external view returns(uint);
    function enabled() external view returns(bool);
    function info(bytes32 id) external view returns(uint);

    function getExpectedRate(ERC20 src, ERC20 dest, uint srcQty) external view
        returns (uint expectedRate, uint slippageRate);

    function tradeWithHint(ERC20 src, uint srcAmount, ERC20 dest, address destAddress, uint maxDestAmount,
        uint minConversionRate, address walletId, bytes calldata hint) external payable returns(uint);
}

contract TradeBot {
  address            internal constant  UNISWAP_ROUTER_ADDRESS  = 0xcDbE04934d89e97a24BCc07c3562DC8CF17d8167; // Rinkeby
  address            internal constant  UNISWAP_FACTORY_ADDRESS = 0xe2f197885abe8ec7c866cFf76605FD06d4576218; // Rinkeby
  address            internal constant  KYBER_PROXY_ADDRESS     = 0xF77eC7Ed5f5B9a5aee4cfa6FFCaC6A4C315BaC76; // Rinkeby
  address            internal constant  ETH_KYBER_ADDRESS       = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; 
  uint               internal constant  TOKEN_18_DECIMALS       = (10**18);
  address            public   immutable owner;
  IUniswapV2Factory  public   immutable uniswapFactory;
  IUniswapV2Router01 public   immutable uniswapRouter;
  KyberNetworkProxyInterface public immutable kyberProxy;

  event Log(string log);
  event UniswapTrade(uint inputAmount, uint outputAmount);

  modifier onlyOwner() {
    require (
      msg.sender == owner,
      "Only owner can call this function."
    );
    _;
  }

  constructor() public {
    owner = msg.sender;
    uniswapFactory = IUniswapV2Factory(UNISWAP_FACTORY_ADDRESS);
    uniswapRouter = IUniswapV2Router01(UNISWAP_ROUTER_ADDRESS);
    kyberProxy = KyberNetworkProxyInterface(KYBER_PROXY_ADDRESS);
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

    // Make the call and log the results
    uint[] memory result = uniswapRouter.swapExactETHForTokens{ value: ethAmount * TOKEN_18_DECIMALS }(0, path, address(this), now + 15);
    emit Log("Uniswap Eth for token swap complete.");
    emit UniswapTrade(result[0], result[1]);
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

    // Make the call and log the results
    uint[] memory result = uniswapRouter.swapExactTokensForETH(tokenAmount * TOKEN_18_DECIMALS, 0, path, address(this), now);
    emit Log("Uniswap token for Eth swap complete.");
    emit UniswapTrade(result[0], result[1]);
  }

  /*
    Kyber methods
   */
  function swapEthForTokenKyber(address tokenAddress, uint ethAmount) public onlyOwner {
    require(ethAmount * TOKEN_18_DECIMALS <= address(this).balance, "Not enough Eth in contract to perform swap.");

    // Declare tokens involved in trade
    ERC20 eth = ERC20(ETH_KYBER_ADDRESS);
    ERC20 token = ERC20(tokenAddress);
    
    // Get the conversion rate
    uint minConversionRate;
    uint slippageRate;
    (minConversionRate, slippageRate) = kyberProxy.getExpectedRate(eth, token, ethAmount * TOKEN_18_DECIMALS);
    require(minConversionRate != 0 || slippageRate != 0, "Trade is not possible at the moment.");

    // Make the trade. Max amount arbitrarily chosen to be 1 million
    bytes memory hint;
    kyberProxy.tradeWithHint{ value: ethAmount * TOKEN_18_DECIMALS }(eth, ethAmount * TOKEN_18_DECIMALS, token, address(this), 10**18 * 10**6, minConversionRate, 0x0000000000000000000000000000000000000004, hint);
  }

  function swapTokenForEtherKyber(address tokenAddress, uint tokenAmount) public onlyOwner {
    // Verify we have enough funds
    ERC20 eth = ERC20(ETH_KYBER_ADDRESS);
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

    // Make the trade. Max amount arbitrarily chosen to be 1 million\
    bytes memory hint;
    kyberProxy.tradeWithHint(token, tokenAmount * TOKEN_18_DECIMALS, eth, address(this), 10**18 * 10**6, minConversionRate, 0x0000000000000000000000000000000000000004, hint);
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