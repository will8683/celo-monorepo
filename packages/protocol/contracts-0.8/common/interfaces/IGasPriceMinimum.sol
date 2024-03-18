pragma solidity >=0.5.13 <0.9.0;

// TODO ass to GasPrice
interface GasPriceMinimum {
  function getGasPriceMinimum(address tokenAddress) external view returns (uint256);
  function updateGasPriceMinimum(uint256 blockGasTotal, uint256 blockGasLimit)
    external
    returns (uint256);
}
