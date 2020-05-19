pragma solidity ^0.6.0;

interface BancorNetworkPathFinder {
    function generatePath(address _sourceToken, address _targetToken) external view returns (address[] memory);
}