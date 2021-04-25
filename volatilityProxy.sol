// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import "https://github.com/smartcontractkit/chainlink/blob/develop/evm-contracts/src/v0.6/ChainlinkClient.sol";
import "https://github.com/smartcontractkit/chainlink/blob/develop/evm-contracts/src/v0.6/vendor/Ownable.sol";


contract volatilityProxy is ChainlinkClient, Ownable {
    address private oracle;
    uint256 private fee;
    bytes32 private jobId;
    
    mapping (string => uint) public assetPairToVolatility; 
    mapping (bytes32 => string) public pairLookUp;
    
    
    constructor() public {
        setPublicChainlinkToken();
        //setChainlinkToken(0xa36085F69e2889c224210F603D836748e7dC0088);
        oracle = 0xD7c0bDB4cec6890Bd704EF2A347E23fF552155b9; // oracle address
        jobId = "6668a59c07ce412892e1060dd4d9bb07"; //job id
        fee = 1 * 10 ** 17; // 0.1 LINK
    }
    
    function setJobId( bytes32 _jobId ) external onlyOwner {
        jobId = _jobId;
    }
    
    function updateVolatility(string memory _asset) public {
        Chainlink.Request memory req = buildChainlinkRequest(jobId, address(this), this.fulfill.selector);
        req.add("volatileTicker", _asset);
        bytes32 request = sendChainlinkRequestTo(oracle, req, fee);
        pairLookUp[request] = _asset;
        
    }

    //callback function for verification
    function fulfill(bytes32 _requestId, uint256 _volatillity) public recordChainlinkFulfillment(_requestId) {
        assetPairToVolatility[pairLookUp[_requestId]] = _volatillity;
    }
}

