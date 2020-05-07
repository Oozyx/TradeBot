pragma solidity ^0.6.6;

interface OrFeedInterface {
  function getExchangeRate (string calldata fromSymbol, string calldata toSymbol, string calldata venue, uint256 amount) external view returns (uint256);
  function getTokenDecimalCount (address tokenAddress) external view returns (uint256);
  function getTokenAddress (string calldata symbol) external view returns (address);
  function getSynthBytes32 (string calldata symbol) external view returns (bytes32);
  function getForexAddress (string calldata symbol) external view returns (address);
}