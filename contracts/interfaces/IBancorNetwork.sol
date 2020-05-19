pragma solidity ^0.6.0;

import "./ERC20.sol";

interface IBancorNetwork {
    function convert2(
        address[] calldata _path,
        uint256 _amount,
        uint256 _minReturn,
        address _affiliateAccount,
        uint256 _affiliateFee
    ) external payable returns (uint256);

    function claimAndConvert2(
        address[] calldata _path,
        uint256 _amount,
        uint256 _minReturn,
        address _affiliateAccount,
        uint256 _affiliateFee
    ) external returns (uint256);

    function convertFor2(
        address[] calldata _path,
        uint256 _amount,
        uint256 _minReturn,
        address _for,
        address _affiliateAccount,
        uint256 _affiliateFee
    ) external payable returns (uint256);

    function claimAndConvertFor2(
        address[] calldata _path,
        uint256 _amount,
        uint256 _minReturn,
        address _for,
        address _affiliateAccount,
        uint256 _affiliateFee
    ) external returns (uint256);

    function getReturnByPath(
      address[] calldata _path,
      uint256 _amount
    ) external view returns (uint256, uint256);
}