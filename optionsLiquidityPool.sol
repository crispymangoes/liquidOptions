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
    */
    
    uint public periodStart; // The block when the contract creation starts
    uint public contractCreationPeriod = 208800; // How long you want the contract period to last
    uint public withdrawPeriod = 7200; // How long you want the withdrawPeriodaw period to last
    uint public totalB; //amount of DAI
    uint public totalA; //amount of ETH
    uint public lockedB;
    uint public lockedA;
    uint64 maxOptionLedgerSize = 65535;
    uint public VPT_test;
    uint public payout_test;
    uint public theta_test;
    uint public delta_test;
    uint public totalPremium_test;
    uint public DM_test;
    uint public theGreeks_test;
    
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
    
    //function LPDeposit
    //TODO: Remove _amount_A and just use msg.value
    //TODO: Add restrictions to single asset deposits when asset ratio is worse than 3:2
    //TODO: Add in LP fee for single asset transactions
    function LPDeposit( uint _amount_B ) payable external updateBlockPeriod {
        if (_amount_B > 0){
            require(DAI.transferFrom(msg.sender, address(this), _amount_B), 'transferFrom failed.');
        }
        uint TVL = totalB + totalA * (10**18)/uint(getThePrice()); // Think A is in an 18 decimal format so you dont want to multiply by 18
        uint LPtoSender;
        if ( LPTOKEN.totalSupply() == 0 ) {
            LPtoSender = 1 * 10 ** 18;
        }
        else {
            LPtoSender = LPTOKEN.totalSupply() * (msg.value * (10**18)/uint(getThePrice()) + _amount_B) / TVL;
        }
        
        totalA = totalA + msg.value;
        totalB = totalB + _amount_B;
        LPTOKEN.mintLPtokens(msg.sender, LPtoSender);
    }
    //function LPWithdraw
    // little tricky bc it withdraws all coins if you are in the withdrawal period, but if not then they need to pay a fee and won't get all coins
    // Another thing to note is that since a user could deposit DAI, then withdraw ETH, they don't pay any liquiidity fees, though I think it will be more expensive to do that
    //TODO: Add restrictions to single asset withdrawals when asset ratio is worse than 3:2
    //TODO: Add in LP fee for single asset transactions
    function LPWithdraw(uint _amount, uint8 _asset, address payable _address) public updateBlockPeriod {
        require( msg.sender == _address, "You can only withdraw LPtokens you own");
        //require( block.number >= (periodStart + contractCreationPeriod), "Cannot withdraw during contractCreationPeriod!");
        //uint AtoB = 1 / uint(getThePrice());
        uint TVL = totalB + totalA * (10**18)/uint(getThePrice()); // Think A is in an 18 decimal format so you dont want to multiply by 18
        uint valuePerToken = TVL / LPTOKEN.totalSupply();
        VPT_test = valuePerToken;
        LPTOKEN.burnLPtokens(_address, _amount); //dont need to call approve!
        
        //LPoutstanding = LPoutstanding - _amount;
        uint payout;
        if (_asset == 0) { //user wants payout in ETH DOESN"T SEEM TO WORK HAD A GAS ERROR WHEN _asset WAS TRUE
            payout = (_amount * valuePerToken * uint(getThePrice())) / (10**18); //not sure if that is the correct way to convert the DAI to ETH
            payout_test = payout;
            //need to update totalA
            totalA = totalA - payout; // need to have error checking making sure ratio between A and B is not too extreme
            //_address.transfer(payout);
            _address.transfer(payout);
            //(bool success, ) = msg.sender.call{value: payout}("");
            //require(success, "Transfer failed.");
        }
        else if (_asset == 100){ //user wants payout in DAI WAS ABLE TO RUN BUT TOUGH TO TELL IF IT WORKED SINCE IT TRANSFERRED SUCH A SMALL AMOUNT OF DAI
            payout = _amount * valuePerToken;
            totalB = totalB - payout; // need to have error checking making sure ratio between A and B is not too extreme
            DAI.transferFrom(address(this), _address, payout);
        }
        else if (_asset == 50) {
            
        }
        
        
    }
    
    //function to calculate the re-balancing fee if they withdraw too early
    
    //funciton calculatePremiumView make it a function that just reads the chain and does math on the local node
    function calculatePremium( uint _amount, uint _strike, bool _asset, uint _ATR, bool _action ) public view returns(uint){
        uint _expiration = periodStart + contractCreationPeriod;
        uint numberToDivideBy = 1; // Keep track of what you need to divide the final answer by at the end
        
        uint _currentPrice;
        if (_asset){
            _currentPrice = 10**36/uint(getThePrice()); //10**36 makes it current price IN DAI
            //_currentPrice = _currentPrice * 10**18; //To put it at same magnitude as _strike
        }
        else {
            _currentPrice = uint(getThePrice()); //CURRENT PRICE IN ETH
        }
        
        //Calculate the Demand Multiplier
        uint DM = calculateDemandMultiplier(_asset, _amount, _action);
        numberToDivideBy = numberToDivideBy * 10 ** 3;
        
        //Calculate Theta Multiplier
        //TODO: contractCreationPeriod in below function should be replaces with expiration-periodStart it'll work when all expirations happen on the same day, but needs to be updated.
        // when ability to change expiration is made
        uint theta = (10**3) * (contractCreationPeriod - ((block.number - periodStart) ** 2)/contractCreationPeriod)/contractCreationPeriod; 
        numberToDivideBy = numberToDivideBy * 10 ** 3;
        
        //Calculate Vega
        uint vega = _ATR; // should be in terms of how much _asset moves in the other asset price, IE for an ETH option, how much does ETH move in DAI
        numberToDivideBy = numberToDivideBy * 10 ** 18;
        
        //Calculate Total premium and delta
        uint totalPremium;
        uint delta;
        if (_currentPrice > _strike){
            uint priceDifference = (_currentPrice - _strike);
            totalPremium = _amount * ( (priceDifference + vega) * DM * theta );
        }
        else{ //This can't handle ATR being 132 but above if statement can?
            delta = (10**3) * _currentPrice/_strike; // 10**18 is used to preserver decimals
            totalPremium = _amount * ( vega * DM * theta * delta);
            numberToDivideBy = numberToDivideBy * 10 ** 3;
        }
        
        
        totalPremium = totalPremium/numberToDivideBy;
        //theta_test = theta;
        //delta_test = delta;
        //totalPremium_test = totalPremium;
        //DM_test = DM;
        return totalPremium;
        
    }
    
    function calculateDemandMultiplier(bool _asset, uint _amount, bool _action) public view returns(uint) {
        uint DM;
        uint newLockedA;
        uint newLockedB;
        if(_action){
            newLockedA = lockedA + _amount;
            newLockedB = lockedB + _amount;
        }
        else {
            newLockedA = lockedA - _amount;
            newLockedB = lockedB - _amount;
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
        uint _ATR = 132217900000000000000;//get from oracle

        bool lockingFunds = true;
        uint premium = calculatePremium( _amount, _strike, _asset, _ATR, lockingFunds);
        if (_asset){
            require(premium <= _maxPremium, "Slippage requirement not met");
            require(DAI.transferFrom(msg.sender, address(this), premium), 'transferFrom failed.');
            totalB = totalB + premium;
            lockedA = lockedA + _amount;
        }
        else {
            require(premium <= _maxPremium, "Slippage requirement not met");
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
    
    function exerciseOption( uint token_Id, address payable _address ) public payable {
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
    
    function sellOption() public {}
    
    function setOptionLedgerMaxSize( uint64 _size ) external onlyOwner {
        require( _size < 4294967294, "Provided size is too large!" );
        maxOptionLedgerSize = _size;
    }
    //FOR DEVELOPMENT ONLY
    function withdrawAll(address payable _address) payable external onlyOwner {
        _address.transfer(address(this).balance);
        DAI.transferFrom(address(this), _address, totalB);
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
