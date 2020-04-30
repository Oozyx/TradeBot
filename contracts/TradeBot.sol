pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

contract TradeBot {
  address internal constant UNISWAP_ROUTER_ADDRESS = 0xcDbE04934d89e97a24BCc07c3562DC8CF17d8167; // Rinkeby
  uint    internal constant TOKEN_18_DECIMALS      = (10**18);
  address                   owner;
  IUniswapV2Router01        uniswapRouter;

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
    uniswapRouter = IUniswapV2Router01(UNISWAP_ROUTER_ADDRESS);
  }

  /*
    Uniswap methods
   */
  function swapEthForTokenWithUniswap(uint ethAmount, address tokenAddress) public onlyOwner {
    // Verify we have enough funds
    require(ethAmount <= address(this).balance, "Not enought Eth in contract to perform swap.");

    // Build arguments for uniswap router call
    address[] memory path = new address[](2);
    path[0] = uniswapRouter.WETH();
    path[1] = tokenAddress;

    // Make the call and log the results
    uint[] memory result = uniswapRouter.swapExactETHForTokens.value(ethAmount)(1, path, address(this), now);
    emit Log("Uniswap Eth for token swap complete.");
    emit UniswapTrade(result[0], result[1]);
  }

  function swapTokenForEtherWithUniswap(uint tokenAmount, address tokenAddress) public onlyOwner {
    // Verify we have enough funds
    ERC20 token = ERC20(tokenAddress);
    require(tokenAmount * TOKEN_18_DECIMALS <= token.balanceOf(address(this)), "Not enough tokens in contract to perform swap.");

    // Build arguments for uniswap router call
    address[] memory path = new address[](2);
    path[0] = tokenAddress;
    path[1] = uniswapRouter.WETH();

    // Make the call and log the results
    uint[] memory result = uniswapRouter.swapExactTokensForETH(tokenAmount * TOKEN_18_DECIMALS, 1, path, address(this), now);
    emit Log("Uniswap token for Eth swap complete.");
    emit UniswapTrade(result[0], result[1]);
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
}