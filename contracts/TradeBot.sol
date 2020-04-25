pragma solidity ^0.5.0;

import "../node_modules/@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../node_modules/@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract UniswapFactoryInterface {
    // Public Variables
    address public exchangeTemplate;
    uint256 public tokenCount;
    // Create Exchange
    function createExchange(address token) external returns (address exchange);
    // Get Exchange and Token Info
    function getExchange(address token) external view returns (address exchange);
    function getToken(address exchange) external view returns (address token);
    function getTokenWithId(uint256 tokenId) external view returns (address token);
    // Never use
    function initializeFactory(address template) external;
}

contract UniswapExchangeInterface {
    // Address of ERC20 token sold on this exchange
    function tokenAddress() external view returns (address token);
    // Address of Uniswap Factory
    function factoryAddress() external view returns (address factory);
    // Provide Liquidity
    function addLiquidity(uint256 min_liquidity, uint256 max_tokens, uint256 deadline) external payable returns (uint256);
    function removeLiquidity(uint256 amount, uint256 min_eth, uint256 min_tokens, uint256 deadline) external returns (uint256, uint256);
    // Get Prices
    function getEthToTokenInputPrice(uint256 eth_sold) external view returns (uint256 tokens_bought);
    function getEthToTokenOutputPrice(uint256 tokens_bought) external view returns (uint256 eth_sold);
    function getTokenToEthInputPrice(uint256 tokens_sold) external view returns (uint256 eth_bought);
    function getTokenToEthOutputPrice(uint256 eth_bought) external view returns (uint256 tokens_sold);
    // Trade ETH to ERC20
    function ethToTokenSwapInput(uint256 min_tokens, uint256 deadline) external payable returns (uint256  tokens_bought);
    function ethToTokenTransferInput(uint256 min_tokens, uint256 deadline, address recipient) external payable returns (uint256  tokens_bought);
    function ethToTokenSwapOutput(uint256 tokens_bought, uint256 deadline) external payable returns (uint256  eth_sold);
    function ethToTokenTransferOutput(uint256 tokens_bought, uint256 deadline, address recipient) external payable returns (uint256  eth_sold);
    // Trade ERC20 to ETH
    function tokenToEthSwapInput(uint256 tokens_sold, uint256 min_eth, uint256 deadline) external returns (uint256  eth_bought);
    function tokenToEthTransferInput(uint256 tokens_sold, uint256 min_eth, uint256 deadline, address recipient) external returns (uint256  eth_bought);
    function tokenToEthSwapOutput(uint256 eth_bought, uint256 max_tokens, uint256 deadline) external returns (uint256  tokens_sold);
    function tokenToEthTransferOutput(uint256 eth_bought, uint256 max_tokens, uint256 deadline, address recipient) external returns (uint256  tokens_sold);
    // Trade ERC20 to ERC20
    function tokenToTokenSwapInput(uint256 tokens_sold, uint256 min_tokens_bought, uint256 min_eth_bought, uint256 deadline, address token_addr) external returns (uint256  tokens_bought);
    function tokenToTokenTransferInput(uint256 tokens_sold, uint256 min_tokens_bought, uint256 min_eth_bought, uint256 deadline, address recipient, address token_addr) external returns (uint256  tokens_bought);
    function tokenToTokenSwapOutput(uint256 tokens_bought, uint256 max_tokens_sold, uint256 max_eth_sold, uint256 deadline, address token_addr) external returns (uint256  tokens_sold);
    function tokenToTokenTransferOutput(uint256 tokens_bought, uint256 max_tokens_sold, uint256 max_eth_sold, uint256 deadline, address recipient, address token_addr) external returns (uint256  tokens_sold);
    // Trade ERC20 to Custom Pool
    function tokenToExchangeSwapInput(uint256 tokens_sold, uint256 min_tokens_bought, uint256 min_eth_bought, uint256 deadline, address exchange_addr) external returns (uint256  tokens_bought);
    function tokenToExchangeTransferInput(uint256 tokens_sold, uint256 min_tokens_bought, uint256 min_eth_bought, uint256 deadline, address recipient, address exchange_addr) external returns (uint256  tokens_bought);
    function tokenToExchangeSwapOutput(uint256 tokens_bought, uint256 max_tokens_sold, uint256 max_eth_sold, uint256 deadline, address exchange_addr) external returns (uint256  tokens_sold);
    function tokenToExchangeTransferOutput(uint256 tokens_bought, uint256 max_tokens_sold, uint256 max_eth_sold, uint256 deadline, address recipient, address exchange_addr) external returns (uint256  tokens_sold);
    // ERC20 comaptibility for liquidity tokens
    bytes32 public name;
    bytes32 public symbol;
    uint256 public decimals;
    function transfer(address _to, uint256 _value) external returns (bool);
    function transferFrom(address _from, address _to, uint256 value) external returns (bool);
    function approve(address _spender, uint256 _value) external returns (bool);
    function allowance(address _owner, address _spender) external view returns (uint256);
    function balanceOf(address _owner) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    // Never use
    function setup(address token_addr) external;
}

contract KyberNetworkProxyInterface {
    function maxGasPrice() public view returns(uint);
    function getUserCapInWei(address user) public view returns(uint);
    function getUserCapInTokenWei(address user, ERC20 token) public view returns(uint);
    function enabled() public view returns(bool);
    function info(bytes32 id) public view returns(uint);
    function getExpectedRate(ERC20 src, ERC20 dest, uint srcQty) public view returns (uint expectedRate, uint slippageRate);
    function tradeWithHint(ERC20 src, uint srcAmount, ERC20 dest, address destAddress, uint maxDestAmount, uint minConversionRate, address walletId, bytes memory hint) public payable returns(uint);
}

contract TradeBot {
  using SafeERC20 for ERC20;

  address internal constant UNISWAP_FACTORY_ADDRESS = 0xf5D915570BC477f9B8D6C0E980aA81757A3AaC36; // Rinkeby
  address internal constant KYBER_PROXY_ADDRESS     = 0xF77eC7Ed5f5B9a5aee4cfa6FFCaC6A4C315BaC76; // Rinkeby
  ERC20   constant internal KYBER_ETH_TOKEN_ADDRESS = ERC20(0x00eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee);
  uint    constant internal MAX_QTY                 = (10**28);
  bytes   constant PERM_HINT                        = "";
  address owner;
  UniswapFactoryInterface uniswapFactory;
  KyberNetworkProxyInterface kyberProxy;

  modifier onlyOwner() {
    require (
      msg.sender == owner,
      "Only owner can call this function."
    );
    _;
  }

  constructor() public {
    owner = msg.sender;
    uniswapFactory = UniswapFactoryInterface(UNISWAP_FACTORY_ADDRESS);
    kyberProxy = KyberNetworkProxyInterface(KYBER_PROXY_ADDRESS);
  }

  /*
    Uniswap methods
   */
  function swapEthForTokenWithUniswap(address tokenAddress) public payable {
    UniswapExchangeInterface exchange = UniswapExchangeInterface(uniswapFactory.getExchange(tokenAddress));
    uint tokenAmount = exchange.getEthToTokenInputPrice(msg.value);
    exchange.ethToTokenSwapInput.value(msg.value)(
      tokenAmount,
      now
    );
  }

  /*
    Kyber methods
   */
  // Returns (expected rate, slippage rate)
  function getConversionRatesKyber(ERC20 srcToken, ERC20 destToken, uint srcQty) public view returns (uint, uint) {
    return kyberProxy.getExpectedRate(srcToken, destToken, srcQty);
  }

  function swapEthForTokenWithKyber(ERC20 destToken) public payable {
    uint minConversionRate;

    // Get minimum conversion rate
    (minConversionRate, ) = getConversionRatesKyber(KYBER_ETH_TOKEN_ADDRESS, destToken, msg.value);

    // Make the swap to the destination address
    //tradeWithHint(ERC20 src, uint srcAmount, ERC20 dest, address destAddress, uint maxDestAmount, uint minConversionRate, address walletId, bytes memory hint)
    kyberProxy.tradeWithHint(
      KYBER_ETH_TOKEN_ADDRESS,
      msg.value,
      destToken,
      address(this),
      MAX_QTY,
      minConversionRate,
      address(0),
      PERM_HINT
    );
  }

  /*
    Withdrawal methods
   */
  function withdrawEth() external onlyOwner {
    //(bool success, ) = msg.sender.call.value(address(this).balance)("");
    msg.sender.transfer(address(this).balance);
    //require(success, "Transfer failed.");
  }

  function withdrawToken(address tokenAddress) external onlyOwner {
    ERC20 token = ERC20(tokenAddress);
    uint tokenBalance = token.balanceOf(address(this));
    token.safeTransfer(msg.sender, tokenBalance);
  }
}