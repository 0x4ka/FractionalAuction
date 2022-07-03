// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract fractionalAuction is ERC1155 {

//STORAGE
    address _protocolOwner;

    //@notice ユーザーのアドレスから各tokenIDのバランスを参照する
    //オークションの勝者に対してインクリメントする（後でClaimできるようにする）
    //インクリメントのタイミングは、次の入札にする（微妙）
    mapping(address => mapping(uint256 => uint256)) public _user2Id2balances;

    //@notice auctionIDからオークション情報を参照
    mapping(uint256 => auctionData) public _auctionId2data;

    //@notice　時系列評価（早い方のみ保持）と、支払い金額の合計を取得できる
    mapping(uint256 => mapping(address => uint256)) public _Id2User2PayedAmounts;
    mapping(address => mapping(uint256 => uint256)) public _user2id2block;

    //@notice 参加ユーザーのアドレスを格納
    address[] winnerAddress;

    //@notice 手前のブロック番号を保存
    uint256 previousBlock;

    // tokenIdとauctionIdは区別して実装する！！！
    struct auctionData {
        address auctionHost; //≒NFTの預入者
        uint256 price; //販売希望価格
        address contractAddr; //出品NFTのコントラクトアドレス
        uint256 tokenId; //出品NFTのトークンID
        uint256 startBlock; //開始時のブロック数
        uint256 blockSpan; //オークション開催の
        uint256 fractionalNum; //分割数
        address highestBider; //現時点での最高入札者
        uint256 maxBid; //各トークンIDの
        bool claimed;
    }

//INIT
    using Counters for Counters.Counter;
    Counters.Counter public auctionId;
    constructor() ERC1155("fractionalAuction"){_protocolOwner = msg.sender;}

// EVENT
    event eventBid(
        uint256 _currentIndex,
        uint256 _bidPrice,
        address highestBider
    );

// AUCTION
    function startAuction(
            address _contractAddr,
            uint256 _tokenId,
            uint256 _price,
            uint256 _fractionalNum,
            uint256 _blockSpan
        ) public returns(auctionData memory) {
        
        //ここに、デポジットさせてしまう
        address operatorAddress = IERC721(_contractAddr).getApproved(_tokenId);
        require(operatorAddress == address(this), 'approval not found');

        //INITIAL
        auctionId.increment();
        uint256 _newAuctionId = auctionId.current();

        //CHANGE STATE
        //@notice　ストレージに書く
        _auctionId2data[_newAuctionId] = auctionData({
            price: _price,
            highestBider: address(0),
            maxBid: 0,
            contractAddr: _contractAddr,
            tokenId: _tokenId,
            startBlock: block.number,
            blockSpan: _blockSpan,
            fractionalNum: _fractionalNum,
            claimed: false,
            host: msg.sender
        });

        //TRANSACTION
        //@notice オークションに出品される1155トークンが全てミントされる
        // 100分割であれば、任意のトークンIDを100個みんと
        _mintFNFT(msg.sender, _newAuctionId, _fractionalNum);

        return _auctionId2data[_newAuctionId];
    }

    //@notice 入札
    //@param _tokenId: オークションID
    //@param _bidPrice: 入札価格
    function bid(uint256 _auctionId, uint256 _bidPrice) public {
        //前のオークション勝者のストレージ格納を入れる
        //最後のオークションの場合は、bidのタイミングでストレージに書き込む（？）
        auctionData memory _auction = _auctionId2data[_auctionId];

        //@notice 開始時間を過ぎているか、かつ、終了時刻を過ぎていないか
        require(_auction.blockSpan != 0, "not start yet");
        require(block.number < _auction.startBlock + _auction.blockSpan * _auction.fractionalNum, "end of time");

        //reset
        if(previousBlock != currentIndex(_auctionId)) {
            //@notice　前回ブロックの最高入札者と入札額を保存
            _Id2User2PayedAmounts[_auctionId][_auctionId2data[_auctionId].highestBider] += _auctionId2data[_auctionId].maxBid;
            _user2id2block[_auctionId2data[_auctionId].highestBider][_auctionId] = previousBlock;
            _user2Id2balances[_auctionId2data[_auctionId].highestBider][_auctionId] += 1;
            winnerAddress.push(_auctionId2data[_auctionId].highestBider);

            //@notice 前回ブロックの最高入札者に対してバランスをインクリメントする。後でclaimしてミントできる
            _auctionId2data[_auctionId].maxBid = 0;
            _auctionId2data[_auctionId].highestBider = address(0);
        }

        //@notice　最小の価格差を上回った金額を入札しているか
        uint256 minimumIncrementBid = _auctionId2data[_auctionId].price / 1000;
        require(_auction.maxBid + minimumIncrementBid <= _bidPrice, "poor");

        //@notice 制限を抜けているユーザーは、maxBidを提示しているのと、暫定winnerとして記録
        _auctionId2data[_auctionId].maxBid = _bidPrice;
        _auctionId2data[_auctionId].highestBider = msg.sender;

        emit eventBid(
            currentIndex(_auctionId),
            _bidPrice,
            msg.sender
        );

        previousBlock = block.number;
    }

    //@notice bidでwinnerになった場合、勝った数だけトランスファーできる
    function claim(uint256 _auctionId) public {
        auctionData memory _auction = _auctionId2data[_auctionId];

        require(msg.sender == _auction.highestBider, "you cant");
        require(_auction.claimed == false, "already minted");

        // claimableをリセット
        _auctionId2data[_auctionId].claimed = true;

        // fNFTを送る
        require(_user2Id2balances[msg.sender][_auctionId] > 0, "canot claim");
        _mintFNFT(msg.sender, _auctionId, _user2Id2balances[msg.sender][_auctionId]);
    }

    function closeAuction(uint256 _auctionId) public {
        //オークションのホストのみ
        require(msg.sender == _auctionId2data[_auctionId].host);

        _Id2User2PayedAmounts[_auctionId][_auctionId2data[_auctionId].highestBider] += _auctionId2data[_auctionId].maxBid;
        _user2id2block[_auctionId2data[_auctionId].highestBider][_auctionId] = previousBlock;

        //@notice 前回ブロックの最高入札者に対してバランスをインクリメントする。後でclaimしてミントできる
        _user2Id2balances[_auctionId2data[_auctionId].highestBider][_auctionId] += 1;
        _auctionId2data[_auctionId].maxBid = 0;
        _auctionId2data[_auctionId].highestBider = address(0);
    }

    function withdrawNFT(uint256 _auctionId) public {
        address topUser = winnerAddress[0];
        address secondUser;

        for(uint256 i=1; i<_auctionId2data[_auctionId].fractionalNum; i++) {
            if(topUser < winnerAddress[i]){
                topUser = winnerAddress[i];
                secondUser = topUser;
            } else if (topUser == winnerAddress[i]) {
                if(_Id2User2PayedAmounts[_auctionId][topUser] < _Id2User2PayedAmounts[_auctionId][secondUser]){
                topUser = secondUser;
                }
            }
        }

        address _contractAddr = _auctionId2data[_auctionId].contractAddr;
        uint256 _tokenId = _auctionId2data[_auctionId].tokenId;
        //IERC721(_contractAddr).transferFrom(_auctionId2data[_auctionId].host, topUser, _tokenId);
    }

    //ブロックの区切り
    function currentIndex(uint256 _auctionId) public view returns(uint256) {
        uint256 _startBlock = _auctionId2data[_auctionId].startBlock;
        uint256 _blockSpan = _auctionId2data[_auctionId].blockSpan;
        uint256 _blockDuration = block.number - _startBlock;
        return _blockDuration / _blockSpan + 1; //指定したブロッック数で、インクリメントされる
    }
    
// FRACTIONAL
    //@notice _auctionHost: NFTをデポジットした人
    //@notice _auctionIdは、グローバルなオークションIDを示す
    //@notice _amountは、NFTの所有権をどれだけ分割したいかという数量
    function _mintFNFT(address _winner, uint256 _auctionId, uint256 _amount) internal { 
        _mint(_winner, _auctionId, _amount, "");
    }
}