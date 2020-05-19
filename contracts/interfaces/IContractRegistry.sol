pragma solidity ^0.6.0;

interface IContractRegistry {
    function addressOf(bytes32 _contractName) external view returns (address);
}