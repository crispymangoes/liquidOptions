// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.7.0 <0.9.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/ERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC721/ERC721.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.6/interfaces/AggregatorV3Interface.sol";

contract optionLiquidityPool is Ownable {
    /*
    This project involes
    -erc721 for the option contacts
    -erc20 for the lp tokens
    -Price Oracles
    -liquidity pools
    */
    
    uint periodStart; // The block when the contract creation starts
    uint contractCreationPeriod = 208800; // How long you want the contract period to last
    uint withdrawPeriod = 7200; // How long you want the withdrawPeriodaw period to last
    uint totalB; //amount of DAI
    uint totalA; //amount of ETH
    uint lockedB;
    uint lockedA;
    uint LPoutstanding = 0;
    uint64 maxOptionLedgerSize = 65535;
    
    LPtoken LPTOKEN;
    optionFactory OPTIONFACTORY;
    AggregatorV3Interface internal priceFeed;
    IERC20 internal DAI;
    
    /**
     * Network: Kovan
     * Aggregator: DAI/ETH
     * Address: 0x22B58f1EbEDfCA50feF632bD73368b2FdA96D541
     * 
     * Network: Kovan
     * Contract: DAI
     * Address: 0xc4375b7de8af5a38a93548eb8453a498222c4ff2
    /*
    -Might want to keep TVL in terms of ETH, like how much ETH is locked! Not in terms of USD
    -ERC721 needs a view function or something so this contract can figure out all the logistics about the contracts it currently has out!
    
    Add an address to the NFTs that represent if that contract collateral is backed by the pool or by an NFT, if it is backed by the pool users can write their own contract and use their exsting contract as collateral
    How it works:
    1. Liquidity Providers put in equal amounts of DAI and ETH and recieve liquidity tokens in exchange
    */
    
    struct option{
        bool asset; //true for ETH, false for DAI
        uint strike; //Conversion to go from DAI to ETH if asset=true or ETH to DAI if asset=false Would really be GWEI to DAI
        uint expiration; //The block the contract expires on, must be exercised before this block
        uint amount;
    }
    
    mapping(uint => option) public optionLedger; //Maps a token_Id to an option contract
    mapping(uint => uint) public indexToTokenId; //Maps an index to a token id 
    
    modifier updateBlockPeriod {
        uint periodLength = periodStart + contractCreationPeriod + withdrawPeriod;
        if ( block.number >= periodLength ){
            periodStart = periodLength;
        }
        _;
    }
    
    constructor() {
    //NEED to deploy an ERC721 and ERC20 contract that this contract owns so it can mint/burn LPtokens and optionNFTs
    //initial liquidity is added here
    LPTOKEN = new LPtoken("LPtoken", "LPT");
    OPTIONFACTORY = new optionFactory("OptionFactory", "OF");
    priceFeed = AggregatorV3Interface(0x22B58f1EbEDfCA50feF632bD73368b2FdA96D541);
    DAI = IERC20(0x4F96Fe3b7A6Cf9725f59d353F723c1bDb64CA6Aa);
    periodStart = block.number;
    
    }
    
    fallback() payable external {} // allows incoming ether
    receive() payable external {}
    
    function getAddressLPtoken() public view returns(address){
        return address(LPTOKEN);
    }
    
    function getAddressFactory() public view returns(address){
        return address(OPTIONFACTORY);
    }
    
    function getThePrice() public view returns (int) {
        (
            uint80 roundID, 
            int price,
            uint startedAt,
            uint timeStamp,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        return price;
        /**
         * To get DAI to ETH take this number and divide by 10**18
         * To get ETH to DAI take this number and inverse it, then multiply by 10**18
        */
    }
    
    //function LPDeposit
    function LPDeposit( uint _amount_A, uint _amount_B ) payable external updateBlockPeriod {
        require(msg.value >= _amount_A, 'Not enough ETH sent');
        require(DAI.transferFrom(msg.sender, address(this), _amount_B), 'transferFrom failed.');
        uint AtoB = 1 / uint(getThePrice());
        uint TVL = totalB + totalA*AtoB; // Think A is in an 18 decimal format so you dont want to multiply by 18
        uint LPtoSender;
        if ( LPTOKEN.totalSupply() == 0 ) {
            LPtoSender = 1 * 10 ** 18;
        }
        else {
            LPtoSender = LPoutstanding * (_amount_A*AtoB + _amount_B) / TVL;
        }
        
        totalA = totalA + _amount_A;
        totalB = totalB + _amount_B;
        LPTOKEN.mintLPtokens(msg.sender, LPtoSender);
    }
    //function LPWithdraw
    // little tricky bc it withdraws all coins if you are in the withdrawal period, but if not then they need to pay a fee and won't get all coins
    // Another thing to note is that since a user could deposit DAI, then withdraw ETH, they don't pay any liquiidity fees, though I think it will be more expensive to do that
    function LPWithdraw(uint _amount, bool _asset, address payable _address) public updateBlockPeriod {
        require( msg.sender == _address, "You can only withdraw LPtokens you own");
        //require( block.number >= (periodStart + contractCreationPeriod), "Cannot withdraw during contractCreationPeriod!");
        uint AtoB = 1 / uint(getThePrice());
        uint TVL = totalB + totalA*AtoB; // Think A is in an 18 decimal format so you dont want to multiply by 18
        uint valuePerToken = TVL / LPTOKEN.totalSupply();
        LPTOKEN.burnLPtokens(_address, _amount); //dont need to call approve!
        
        //LPoutstanding = LPoutstanding - _amount;
        uint payout;
        if (_asset) { //user wants payout in ETH DOESN"T SEEM TO WORK HAD A GAS ERROR WHEN _asset WAS TRUE
            payout = _amount * valuePerToken / AtoB; //not sure if that is the correct way to convert the DAI to ETH
            //need to update totalA
            totalA = totalA - _amount; // need to have error checking making sure ratio between A and B is not too extreme
            _address.transfer(payout);
            //(bool success, ) = msg.sender.call{value: payout}("");
            //require(success, "Transfer failed.");
        }
        else { //user wants payout in DAI WAS ABLE TO RUN BUT TOUGH TO TELL IF IT WORKED SINCE IT TRANSFERRED SUCH A SMALL AMOUNT OF DAI
            payout = _amount * valuePerToken;
            totalB = totalB - _amount; // need to have error checking making sure ratio between A and B is not too extreme
            DAI.transferFrom(address(this), _address, payout);
        }
        
        
    }
    
    //function to calculate the re-balancing fee if they withdraw too early
    
    //funciton calculatePremiumView make it a function that just reads the chain and does math on the local node
    function calculatePremiumView( uint _expiration, uint _amount, uint _strike, uint _currentPrice, bool _asset, uint _ATR ) public pure returns(uint){
        //returns the amount of the underlying it is worth
        //premium multiplier function should be added to this, eventhough  there will be a dedicated funciton, this is to keep it a view function
        // intrinsic = (assetPrice - strikePrice)
        // if ( assetPrice > strikePrice) { premium = (assetPrice - strikePrice) + demandMultiplier * ( ATR * assetPrice/strikePrice * (0.05 ** (1/BLOCKS_TO_EXPIRATION))
        // else {premium = demandMultiplier * ( ATR * assetPrice/strikePrice * (0.05 ** (1/BLOCKS_TO_EXPIRATION))}
        //return premium
    }
    
    //function calculatePremium identical to the one above but this one is called by the contract and uses on chain resources
    function calculatePremium ( uint _expiration, uint _amount, uint _strike, bool _asset, uint _ATR ) internal returns(uint){
        //returns the amount of the underlying it is worth
        //Oracle to grab price!
        // intrinsic = (assetPrice - strikePrice)
        // if ( assetPrice > strikePrice) { premium = (assetPrice - strikePrice) + demandMultiplier * ( ATR * assetPrice/strikePrice * (0.05 ** (1/BLOCKS_TO_EXPIRATION))
        // else {premium = demandMultiplier * ( ATR * assetPrice/strikePrice * (0.05 ** (1/BLOCKS_TO_EXPIRATION))}
        //return premium
    }
    
    //function to mint erc721 tokens to represent option contract ownership
    //Strike should be in terms of the asset the premium is paid in.
    // Could also have the function determine the amount the option is for based off how much funds were sent to cover the premium
    // Initially expiration will always be the monthly expiration block
    function mintOption( uint _expiration, uint _amount, uint _strike, uint _slippage, bool _asset ) public updateBlockPeriod {
        require(block.number < (periodStart + contractCreationPeriod), "Cannot create contracts during the withdrawal period!");
        require(_amount > 1 * 10 ** 16, "option contract too small");
        uint i = 0;
        while ( maxOptionLedgerSize > i && optionLedger[indexToTokenId[i]].expiration > block.number ){ // Checks to find the earliest index where a contract is expired and it can right over it
            i++;
        }
        require( i < (maxOptionLedgerSize-1), "Max option contracts exist" );
        //calculate premium
        //requires for them to send money
        
        uint token_Id = uint(keccak256(abi.encodePacked(_expiration, _amount, _strike, msg.sender, block.number)));
        OPTIONFACTORY.createOption(msg.sender, token_Id);
        indexToTokenId[i] = token_Id;
        optionLedger[token_Id] = option(
            {
                asset: _asset,
                strike: _strike,
                expiration: _expiration,
                amount: _amount
            }
        );
    }
    
    function setOptionLedgerMaxSize( uint64 _size ) external onlyOwner {
        require( _size < 4294967294, "Provided size is too large!" );
        maxOptionLedgerSize = _size;
    }
    
    
    //function to calculate the demand multiplier but it only reads chain data and uses local resources
    
    //function identical to the one above but is used for onchain computation
    
    //functions to manage the optionBlocks, I think this would be called by an oracle, like a heart beat oracle
    
    //function to grab ATR from aggregator oracles
    
    //function to accept ERC721s, reads the data from them, then burns the token, then pays out msg.sender as long as they sent the required funds
    
}

contract LPtoken is ERC20, Ownable {
    //ERC20, Ownable
    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}
    function mintLPtokens(address _to, uint _amount) public onlyOwner {
        _mint(_to, _amount);
    }
    
    function burnLPtokens( address _from, uint _amount) public onlyOwner {
        _burn(_from, _amount);
    }
}

contract optionFactory is ERC721, Ownable {
    //ERC721, Ownable
    constructor(string memory _name, string memory _symbol) ERC721(_name, _symbol) {}
    function createOption( address _to, uint _nonce) public onlyOwner {
        _safeMint(_to, _nonce);
    }
}