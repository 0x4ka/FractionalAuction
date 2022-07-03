// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract fractionalizedAuction is ERC1155 {

//STORAGE
    address _protocolOwner;
    uint256 previousSection;

    //@notice auctionIDからオークション情報を参照
    mapping(uint256 => auctionData) private _auctionData; // auctionId => Data
    mapping(uint256 => mapping(uint256 => fractionalAuctionData)) private _fractionalAuctions; // auctionId => 1 => fractionalAuctionData
    mapping(address => uint256[]) private _winningAuctions; // user.address => [1,2,3,4,...]
    mapping(address => uint256) private _winnerPaidAmount; // user.address => amount

    struct auctionData {
        address auctionHost; //≒NFTの預入者
        uint256 price; //販売希望価格
        address contractAddr; //出品NFTのコントラクトアドレス
        uint256 tokenId; //出品NFTのトークンID
        uint256 startBlock; //開始時のブロック数
        uint256 sectionSpan; //オークションあたりの開催スパン
        uint256 separateTo; //分割数
    }

    struct fractionalAuctionData {
        address winner; //最高入札者
        uint256 bidAmount; //一時的な最高入札額
        bool claimed; //ERC1155のミント可否
    }


//MODIFIER
    modifier AuctionOnGoing(uint256 _auctionId) {
        auctionData memory _auction = _auctionData[_auctionId];
        uint256 _auctionEndtime = _auction.startBlock + _auction.sectionSpan * _auction.separateTo;
        
        //REQUIRE
        require(_auction.sectionSpan != 0, "not start yet");
        require(block.number < _auctionEndtime, "end of time");
        _;
    }

    modifier OnlyAuctionHost(uint256 _auctionId) {
        require(msg.sender == _auctionData[_auctionId].auctionHost);
        _;
    }

//INIT
    using Counters for Counters.Counter;
    Counters.Counter public auctionId;
    constructor() ERC1155("FractionalizedAuction"){_protocolOwner = msg.sender;}

// AUCTION

    //@notice 出品
    //@param _contractAddr: 出品するNFTのコントラクトアドレス
    //@param _tokenId: 出品するNFTのトークンID
    //@param _price: 出品価格
    //@param _separateTo: フラクショナル数
    //@param _sectionSpan: 各オークションのセクション所要時間
    function startAuction(
            address _contractAddr,
            uint256 _tokenId,
            uint256 _price,
            uint256 _separateTo,
            uint256 _sectionSpan
        ) public returns(uint256) {

        //INITIAL
        auctionId.increment();
        uint256 _newAuctionId = auctionId.current();
        
        //NFTのコントロール権を移譲してもらう
        //address operatorAddress = IERC721(_contractAddr).getApproved(_tokenId);
        //require(operatorAddress == address(this), "approval not found");

        //CHANGE STATE
        _auctionData[_newAuctionId] = auctionData({
            auctionHost: msg.sender,
            price: _price,
            contractAddr: _contractAddr,
            tokenId: _tokenId,
            startBlock: block.number,
            sectionSpan: _sectionSpan,
            separateTo: _separateTo
        });

        return _newAuctionId;
    }

    //@notice 入札
    //@param _tokenId: オークションID
    //@param _bidPrice: 入札価格
    function bid(
            uint256 _auctionId,
            uint256 _bidPrice
        ) public AuctionOnGoing(_auctionId) {

        //FORPREVIOUS
        address _winner = _fractionalAuctions[_auctionId][previousSection].winner;
        _winningAuctions[_winner].push(previousSection);
        _winnerPaidAmount[_winner] = _fractionalAuctions[_auctionId][previousSection].bidAmount;

        //INIT
        uint256 _section = currentSection(_auctionId);

        //CHANGE STATE
        require(_fractionalAuctions[_auctionId][_section].bidAmount + (_auctionData[_auctionId].price / 1000) <= _bidPrice, "Lower than minIncrement");

        _fractionalAuctions[_auctionId][_section] = fractionalAuctionData({
            winner: msg.sender,
            bidAmount: _bidPrice,
            claimed: false
        });
        
        //AFTER
        previousSection = currentSection(_auctionId);
    }

    //@notice bidでwinnerになった場合、勝った数だけトランスファーできる
    function claimOfBatch(uint256 _auctionId) public {
        for(uint256 i=0; i<_winningAuctions[msg.sender].length; i++) {

            fractionalAuctionData memory _fractional = _fractionalAuctions[_auctionId][i];

            require(msg.sender == _fractional.winner, "you cant");
            require(_fractional.claimed == false, "already minted");
            _fractionalAuctions[_auctionId][i].claimed = true;

            // fNFTを送る
            _mintFNFT(msg.sender, _auctionId, 1);
        }
    }

    //@notice オークションを終了させる（オーナーは、プロトコルからお金を引き出し）
    //@param _auctionId: オークションID
    function closeAuction(uint256 _auctionId) public OnlyAuctionHost(_auctionId) {

        //FORPREVIOUS
        address _winner = _fractionalAuctions[_auctionId][previousSection].winner;
        _winningAuctions[_winner].push(previousSection);
        _winnerPaidAmount[_winner] = _fractionalAuctions[_auctionId][previousSection].bidAmount;

        //address _contractAddr = _auction[_auctionId].contractAddr;
        //uint256 _tokenId = _auction[_auctionId].tokenId;
        //IERC721(_contractAddr).transferFrom(_auction[_auctionId].host, topUser, _tokenId);
    }
    
//INTERNAL

    //@notice 落札者によるERC1155の発行
    //@param _winner: NFTをデポジットした人
    //@param _auctionIdは、グローバルなオークションIDを示す
    //@param _amountは、NFTの所有権をどれだけ分割したいかという数量
    function _mintFNFT(address _winner, uint256 _auctionId, uint256 _amount) internal { 
        _mint(_winner, _auctionId, _amount, "");
    }

    //@notice 現在のセクションを表示
    //@param _auctionId: オークションID
    function currentSection(uint256 _auctionId) internal view returns(uint256) {
        uint256 _startBlock = _auctionData[_auctionId].startBlock;
        uint256 _sectionSpan = _auctionData[_auctionId].sectionSpan;
        uint256 _blockDuration = block.number - _startBlock;
        return _blockDuration / _sectionSpan + 1;
    }

//VIEW
    function winningAmount_(address _user) public view returns(uint256){
        return _winningAuctions[_user].length;
    }

    function auction_(uint256 _auctionId) public view returns(auctionData memory) {
        return _auctionData[_auctionId];
    }

    function winningAuctions_(address _user) public view returns(uint256[] memory){
        return _winningAuctions[_user];
    }

    function fractionalAuctionData_(uint256 _auctionId, uint256 _section) public view returns(fractionalAuctionData memory) {
        return _fractionalAuctions[_auctionId][_section];
    }
}