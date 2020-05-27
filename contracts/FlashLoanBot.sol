pragma solidity ^0.6.0;

import "./TradeBot.sol";
import "./interfaces/FlashLoanReceiverBase.sol";
import "./interfaces/ILendingPool.sol";

contract FlashLoanBot is TradeBot, FlashLoanReceiverBase {
  /*
    Constants
  */
  address internal constant AAVE_ADDRESSES_PROVIDER   = 0x1c8756FD2B28e9426CDBDcC7E3c4d64fa9A54728; // Ropsten

  /*
    Members
  */
  ILendingPool internal immutable lendingPool;

  /*
    Constructors
  */
  constructor() FlashLoanReceiverBase(AAVE_ADDRESSES_PROVIDER) public {
    lendingPool = ILendingPool(addressesProvider.getLendingPool());
  }

  /*
    Arbitrage methods
  */
  function arbExecute(address stableCoin, address mediatorCoin, uint amount, string calldata sellDexBuyDex, uint gasTokenAmount) external override onlyOwner {
    if (gasTokenAmount > 0) {
      // Burn the gas token
      require(GasToken(GAS_TOKEN_ADDRESS).freeFromUpTo(msg.sender, gasTokenAmount) > 0, "Failed to free gas token.");
    }
    
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

    if (keccak256(bytes(sellDexBuyDex)) == keccak256("SELL_UV2_BUY_KYB")) {
      swapTokenForTokenKyber(mediatorCoin, _reserve, swapTokenForTokenUniswapV2(_reserve, mediatorCoin, _amount));
    } else if (keccak256(bytes(sellDexBuyDex)) == keccak256("SELL_UV2_BUY_UV1")) {
      swapTokenForTokenUniswapV1(mediatorCoin, _reserve, swapTokenForTokenUniswapV2(_reserve, mediatorCoin, _amount));
    } else if (keccak256(bytes(sellDexBuyDex)) == keccak256("SELL_KYB_BUY_UV2")) {
      swapTokenForTokenUniswapV2(mediatorCoin, _reserve, swapTokenForTokenKyber(_reserve, mediatorCoin, _amount));
    } else if (keccak256(bytes(sellDexBuyDex)) == keccak256("SELL_KYB_BUY_UV1")) {
      swapTokenForTokenUniswapV1(mediatorCoin, _reserve, swapTokenForTokenKyber(_reserve, mediatorCoin, _amount));
    } else if (keccak256(bytes(sellDexBuyDex)) == keccak256("SELL_UV1_BUY_UV2")) {
      swapTokenForTokenUniswapV2(mediatorCoin, _reserve, swapTokenForTokenUniswapV1(_reserve, mediatorCoin, _amount));
    } else if (keccak256(bytes(sellDexBuyDex)) == keccak256("SELL_UV1_BUY_KYB")) {
      swapTokenForTokenKyber(mediatorCoin, _reserve, swapTokenForTokenUniswapV1(_reserve, mediatorCoin, _amount));
    }

    uint totalDebt = _amount.add(_fee);
    transferFundsBackToPoolInternal(_reserve, totalDebt);
  }
}