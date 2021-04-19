// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.0 <0.9.0;

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
    TODO: Add events
    */
    
    uint public periodStart; // The block when the contract creation starts
    uint public contractCreationPeriod = 208800; // How long you want the contract period to last
    uint public withdrawPeriod = 7200; // How long you want the withdrawPeriodaw period to last
    uint public totalB; //amount of DAI
    uint public totalA; //amount of ETH
    uint public lockedB;
    uint public lockedA;
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
            , 
            int price,
            ,
            ,
            
        ) = priceFeed.latestRoundData();
        return price;
        /**
         * To get DAI to ETH take this number and divide by 10**18
         * To get ETH to DAI take this number and inverse it, then multiply by 10**18
        */
    }
    
    function LPDeposit( uint _amount_B ) payable external updateBlockPeriod {
        uint currentPrice = uint(getThePrice());
        if (_amount_B > 0){
            require(DAI.transferFrom(msg.sender, address(this), _amount_B), 'transferFrom failed.');
        }
        //Check to see if crypto caller sent is within a +- 10% dollar value of eachother.
        uint percentLPtoMint;
        if ( (msg.value * (10**18)/currentPrice)*1000 < _amount_B*1100 && (msg.value * (10**18)/currentPrice)*1000 > _amount_B*900 ){
            percentLPtoMint = 10000; // Mint full amount of LP for caller
        }
        else {
            percentLPtoMint = 9985; // Charge a 0.15% LP fee
            require(msg.value == 0 || _amount_B == 0, "Only send one asset when depositing one asset!");
            if ( _amount_B > msg.value){
                if (totalA > 0) {require((10**3 * totalB/(totalA * (10**18)/currentPrice)) < 1500, "Ratio between assets to large to only deposit DAI!");}
            }
            else {
                if (totalB > 0) {require((10**3 * (totalA * (10**18)/currentPrice)/totalB) < 1500, "Ratio between assets to large to only deposit ETH!");}
            }
        }
        
        uint TVL = totalB + totalA * (10**18)/currentPrice; // Think A is in an 18 decimal format so you dont want to multiply by 18
        uint LPtoSender;
        if ( LPTOKEN.totalSupply() == 0 ) {
            LPtoSender = 1 * 10 ** 18;
        }
        else {
            LPtoSender = LPTOKEN.totalSupply() * (msg.value * (10**18)/currentPrice + _amount_B) / TVL;
        }
        
        LPtoSender = LPtoSender * percentLPtoMint/10000;
        uint LPtoPool = LPtoSender * 10/1000; // Take 1% pool fee
        LPtoSender = LPtoSender * 990/1000;
        totalA = totalA + msg.value;
        totalB = totalB + _amount_B;
        //TODO: Investigate what is cheaper, doing two mints, or minting to contract address then transferring shares to caller
        // ALso I think  need to call approve before the transfer works
        LPTOKEN.mintLPtokens(msg.sender, LPtoSender);
        LPTOKEN.mintLPtokens(address(this), LPtoPool);
    }

    //TODO: Add logic to handle partial withdrawals during contractCreationPeriod
    function LPWithdraw(uint _amount, uint8 _asset, address payable _address) public updateBlockPeriod {
        require( msg.sender == _address, "You can only withdraw LPtokens you own");
        //require( block.number >= (periodStart + contractCreationPeriod), "Cannot withdraw during contractCreationPeriod!");
        
        uint currentPrice = uint(getThePrice());
        uint TVL = totalB + totalA * (10**18)/currentPrice; // Think A is in an 18 decimal format so you dont want to multiply by 18
        uint valuePerToken = TVL / LPTOKEN.totalSupply();
        LPTOKEN.burnLPtokens(_address, _amount); //dont need to call approve!
        
        uint payout;
        if (_asset == 0) { //user wants payout in ETH
            if (lockedA > 0) {require((10**3 * totalA/lockedA) > 1111, "Not enough liquidity in ETH to only withdraw it!");}
            if (totalA > 0) {require((10**3 * totalB/(totalA * (10**18)/currentPrice)) < 1500, "Ratio between assets to large to only withdraw ETH!");} // Make sure ratio between the assets is not greater than 3:2 DAI:ETH
            payout = (_amount * valuePerToken * currentPrice) / (10**18);
            payout = payout * 9985/10**4; // 0.15% LP fee;
            totalA = totalA - payout;
            _address.transfer(payout);
        }
        else if (_asset == 100){ //user wants payout in DAI
            if (lockedB > 0) {require((10**3 * totalB/lockedB) > 1111, "Not enough liquidity in DAI to only withdraw it!");}
            if (totalB > 0) {require((10**3 * (totalA * (10**18)/currentPrice)/totalB) < 1500, "Ratio between assets to large to only withdraw DAI!");} // Make sure ratio between the assets is not greater than 3:2 DAI:ETH
            payout = _amount * valuePerToken;
            payout = payout * 9985/10**4; // 0.15% LP fee;
            totalB = totalB - payout;
            DAI.transferFrom(address(this), _address, payout);
        }
        else if (_asset == 50) { // 50/50 Payout in ETH and DAI
            uint payoutA = (_amount * valuePerToken * currentPrice) / (2 * 10**18);
            uint payoutB = (_amount * valuePerToken) - (payoutA * (10**18)/currentPrice);//Take the total DAI value of what should be paid out, and subtract the DAI value of the ETH being paid out to get the remaining DAI payout
            totalA = totalA - payoutA;
            totalB = totalB - payoutB;
            _address.transfer(payoutA);
            DAI.transferFrom(address(this), _address, payoutB);
        }
    }
    
    //function to calculate the re-balancing fee if they withdraw too early
    
    function calculatePremium( uint _amount, uint _strike, bool _asset, uint _ATR, bool _action ) public view returns(uint){
        uint _expiration = periodStart + contractCreationPeriod;
        uint numberToDivideBy = 1; // Keep track of what you need to divide the final answer by at the end
        
        uint _currentPrice;
        if (_asset){
            _currentPrice = 10**36/uint(getThePrice()); //10**36 makes it current price IN DAI
        }
        else {
            _currentPrice = uint(getThePrice()); //CURRENT PRICE IN ETH
        }
        
        //Calculate the Demand Multiplier
        uint DM = calculateDemandMultiplier(_asset, _amount, _action);
        numberToDivideBy = numberToDivideBy * 10 ** 3;
        
        //Calculate Theta Multiplier
        uint theta = (10**3) * ((_expiration-periodStart) - ((block.number - periodStart) ** 2)/(_expiration-periodStart))/(_expiration-periodStart); 
        numberToDivideBy = numberToDivideBy * 10 ** 3;
        
        //Calculate Vega
        uint vega = _ATR; // should be in terms of how much _asset moves in the other asset price, IE for an ETH option, how much does ETH move in DAI
        numberToDivideBy = numberToDivideBy * 10 ** 18;
        
        //Calculate Total premium and delta
        uint totalPremium;
        uint delta;
        if (_currentPrice > _strike){
            uint priceDifference = (_currentPrice - _strike);
            totalPremium = _amount * ( priceDifference + vega * DM * theta );
        }
        else{ //This can't handle ATR being 132 but above if statement can?
            delta = (10**3) * _currentPrice/_strike; // 10**18 is used to preserver decimals
            totalPremium = _amount * ( vega * DM * theta * delta);
            numberToDivideBy = numberToDivideBy * 10 ** 3;
        }
        
        totalPremium = totalPremium/numberToDivideBy;
        return totalPremium;
    }
    
    function calculateDemandMultiplier(bool _asset, uint _amount, bool _action) public view returns(uint) {
        uint DM;
        uint newLockedA;
        uint newLockedB;
        if(_action){
            if (_asset){newLockedA = lockedA + _amount;}
            else{newLockedB = lockedB + _amount;}
        }
        else {
            if (_asset){newLockedA = lockedA - _amount;}
            else{newLockedB = lockedB - _amount;}
        }
        if(_asset) { //DM for ETH option
            require(newLockedA <= totalA, "Not enough liquiidity in pool");
            require(newLockedA >= 0, "Not enough liquiidity in pool");
            if (newLockedA == totalA) {DM = 1000000000000000000*10**3;}
            else{
                DM = 10**3*newLockedA/(totalA - newLockedA) + 1*10**3;
            }
        }
        else { //DM for DAI option
            require(newLockedB <= totalB, "Not enough liquiidity in pool");
            require(newLockedB >= 0, "Not enough liquiidity in pool");
            if (newLockedB == totalB) {DM = 1000000000000000000*10**3;}
            else {
                DM = 10**3*newLockedB/(totalB - newLockedB) + 1*10**3;
            }
        }
        
        return DM;
    }
    //TODO: Actually pull ATR value from Oracle
    function mintOption( uint _amount, uint _strike, bool _asset, uint _maxPremium, address payable _address ) payable public updateBlockPeriod {
        require( msg.sender == _address, "Cannot mint options for a different address");
        uint _expiration = periodStart + contractCreationPeriod;
        require(block.number < (periodStart + contractCreationPeriod), "Cannot create contracts during the withdrawal period!");
        require(_amount >= 1 * 10 ** 16, "option contract too small"); //MAKE SURE I CREATE A LARGE ENOUGH OPTION
        uint i = 0;
        while ( maxOptionLedgerSize > i && optionLedger[indexToTokenId[i]].expiration > block.number ){ // Checks to find the earliest index where a contract is expired and it can right over it
            i++;
        }
        require( i < (maxOptionLedgerSize-1), "Max option contracts exist" );
        
        //calculate premium
        uint _ATR;
        if (_asset){
            _ATR = 132217900000000000000;//get from oracle
        }
        else {
            _ATR = 40193800000000;//get from oracle
        }

        bool lockingFunds = true;
        uint premium = calculatePremium( _amount, _strike, _asset, _ATR, lockingFunds);
        require(premium <= _maxPremium, "Slippage requirement not met");
        if (_asset){
            require(DAI.transferFrom(msg.sender, address(this), premium), 'transferFrom failed.');
            totalB = totalB + premium;
            lockedA = lockedA + _amount;
        }
        else {
            require(msg.value >= premium, 'Not enough ETH sent');
            totalA = totalA + premium;
            lockedB = lockedB + _amount;
        
            // refund caller extra ETH they sent
            _address.transfer(msg.value - premium);
        }
        
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
    
    function exerciseOption( uint token_Id, address payable _address ) public payable updateBlockPeriod {
        require( msg.sender == _address, "You can only exercise contracts you own");
        require( OPTIONFACTORY.ownerOf(token_Id) == msg.sender, "Caller does not own contract");
        require( block.number < optionLedger[token_Id].expiration, "Contract is expired");
        //require to check if option is ITM
        OPTIONFACTORY.burnOption(token_Id);
        uint payment = (optionLedger[token_Id].strike * optionLedger[token_Id].amount) / 10**18;
        if (optionLedger[token_Id].asset) {
            //Its an ETH option so have them transfer the required DAI
            require(DAI.transferFrom(msg.sender, address(this), payment), 'transferFrom failed.');
             _address.transfer(optionLedger[token_Id].amount);
             totalB = totalB + payment;
             totalA = totalA - optionLedger[token_Id].amount;
             lockedA = lockedA - optionLedger[token_Id].amount;
        }
        else {
            //Its a DAI option so have them send ETH
            require(msg.value == payment, 'Not enough ETH sent');
            DAI.transferFrom(address(this), _address, optionLedger[token_Id].amount);
            totalA = totalA + payment;
            totalB = totalB - optionLedger[token_Id].amount;
            lockedB = lockedB - optionLedger[token_Id].amount;
        }
    }
    //TODO: Actually pull ATR value from Oracle
    function sellOption(uint _tokenId, uint _minPremium, address payable _address) public updateBlockPeriod {
        require( msg.sender == _address, "Cannot sell contract you do not own!");
        require( OPTIONFACTORY.ownerOf(_tokenId) == msg.sender, "Caller does not own contract");
        require( block.number < optionLedger[_tokenId].expiration, "Contract is expired");
        //calculate premium
        uint _ATR;
        if (optionLedger[_tokenId].asset){
            _ATR = 132217900000000000000;//get from oracle
        }
        else {
            _ATR = 40193800000000;//get from oracle
        }

        bool lockingFunds = false;
        uint premium = calculatePremium( optionLedger[_tokenId].amount, optionLedger[_tokenId].strike, optionLedger[_tokenId].asset, _ATR, lockingFunds);
        require(premium >= _minPremium, "Slippage requirement not met");
        OPTIONFACTORY.burnOption(_tokenId); //Burn the option
        if (optionLedger[_tokenId].asset) {
            lockedA = lockedA - optionLedger[_tokenId].amount;
            totalB = totalB - premium;
            DAI.transferFrom(address(this), _address, premium);
        }
        else {
            lockedB = lockedB - optionLedger[_tokenId].amount;
            totalA = totalA - premium;
            _address.transfer(premium);
        }
    }
    
    function setOptionLedgerMaxSize( uint64 _size ) external onlyOwner {
        require( _size < 4294967294, "Provided size is too large!" );
        maxOptionLedgerSize = _size;
    }
    //FOR DEVELOPMENT ONLY
    function withdrawAll(address payable _address) payable external onlyOwner {
        _address.transfer(address(this).balance);
        DAI.transferFrom(address(this), _address, totalB);
    }
    //TODO: Fail with error 'ERC20: transfer amount exceeds allowance'
    function withdrawOwnersLPT(address _address) external onlyOwner {
        uint contractBalance = LPTOKEN.balanceOf(address(this));
        require(LPTOKEN.transferFrom(address(this), _address, contractBalance), "LP token transferFrom failed!");
    }
    
    //TODO: 
    //functions to manage the optionBlocks, I think this would be called by an oracle, like a heart beat oracle
    //function to grab ATR from aggregator oracles
    
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
    
    function burnOption(uint _tokenId) public onlyOwner {
        _burn(_tokenId);
    }
}
