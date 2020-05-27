pragma solidity ^0.6.0;

interface GasToken {
  function free(uint value) external returns (bool);
  function freeUpTo(uint value) external returns (uint);
  function freeFrom(address from, uint value) external returns (bool);
  function freeFromUpTo(address from, uint value) external returns (uint);
}