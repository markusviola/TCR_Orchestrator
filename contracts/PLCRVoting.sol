pragma solidity ^0.5.4;

import "./ERC20Detailed.sol";
import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/math/SafeMath.sol";

import "./DLL.sol";
import "./AttributeStore.sol";

contract PLCRVoting {

    event _VoteCommitted(uint pollID, uint numTokens, address voter);
    event _VoteRevealed(uint pollID, uint numTokens, uint votesFor, uint votesAgainst, uint choice, address voter, uint salt);
    event _PollCreated(uint voteQuorum, uint commitEndDate, uint revealEndDate, uint pollID, address creator);
    event _VotingRightsGranted(uint numTokens, address voter);
    event _VotingRightsWithdrawn(uint numTokens, address voter);
    event _TokensRescued(uint pollID, address voter);
    event OperationSuccess(bool success);

    using AttributeStore for AttributeStore.Data;
    using DLL for DLL.Data;
    using SafeMath for uint;

    struct Poll {
        uint commitEndDate;   
        uint revealEndDate;    
        uint voteQuorum;	    
        uint votesFor;		   
        uint votesAgainst;     
        mapping(address => bool) didCommit;  
        mapping(address => bool) didReveal;   
        mapping(address => uint) voteOptions; 
    }

    uint constant public INITIAL_POLL_NONCE = 0;
    uint public pollNonce;

    mapping(uint => Poll) public pollMap; 
    mapping(address => uint) public voteTokenBalance; 

    mapping(address => DLL.Data) dllMap;
    AttributeStore.Data store;

    ERC20Detailed public token;
    address private tokenOwner; //For testing

    function init(address _token, address _tokenOwner) public {
        require(address(token) == address(0));
        
        token = ERC20Detailed(_token);
        tokenOwner = _tokenOwner;
        pollNonce = INITIAL_POLL_NONCE;
    }
    
    //TESTING ONLY
    function tokenFaucet(uint256 _numTokens) public payable {
        token.transferFrom(tokenOwner, msg.sender, _numTokens);
        emit OperationSuccess(true);
    }

    function requestVotingRights(uint _numTokens) public {
        require(token.balanceOf(msg.sender) >= _numTokens);
        voteTokenBalance[msg.sender] += _numTokens;
        require(token.transferFrom(msg.sender, address(this), _numTokens));
        emit _VotingRightsGranted(_numTokens, msg.sender);
    }
    
    function getVotingBalance() public view returns(uint) {
        return voteTokenBalance[msg.sender];
    }


    function withdrawVotingRights(uint _numTokens) external {
        uint availableTokens = voteTokenBalance[msg.sender].sub(getLockedTokens(msg.sender));
        require(availableTokens >= _numTokens);
        voteTokenBalance[msg.sender] -= _numTokens;
        require(token.transfer(msg.sender, _numTokens));
        emit _VotingRightsWithdrawn(_numTokens, msg.sender);
    }


    function rescueTokens(uint _pollID) public {
        require(isExpired(pollMap[_pollID].revealEndDate));
        require(dllMap[msg.sender].contains(_pollID));

        dllMap[msg.sender].remove(_pollID);
        emit _TokensRescued(_pollID, msg.sender);
    }


    function rescueTokensInMultiplePolls(uint[] memory _pollIDs) public {
        for (uint i = 0; i < _pollIDs.length; i++) {
            rescueTokens(_pollIDs[i]);
        }
    }


    function commitVote(uint _pollID, bytes32 _secretHash, uint _numTokens, uint _prevPollID) public {
        require(commitPeriodActive(_pollID));


        if (voteTokenBalance[msg.sender] < _numTokens) {
            uint remainder = _numTokens.sub(voteTokenBalance[msg.sender]);
            requestVotingRights(remainder);
        }

        require(voteTokenBalance[msg.sender] >= _numTokens);
        require(_pollID != 0);
        require(_secretHash != 0);
        require(_prevPollID == 0 || dllMap[msg.sender].contains(_prevPollID));

        uint nextPollID = dllMap[msg.sender].getNext(_prevPollID);

        if (nextPollID == _pollID) {
            nextPollID = dllMap[msg.sender].getNext(_pollID);
        }

        require(validPosition(_prevPollID, nextPollID, msg.sender, _numTokens));
        dllMap[msg.sender].insert(_prevPollID, _pollID, nextPollID);

        bytes32 UUID = attrUUID(msg.sender, _pollID);

        store.setAttribute(UUID, "numTokens", _numTokens);
        store.setAttribute(UUID, "commitHash", uint(_secretHash));

        pollMap[_pollID].didCommit[msg.sender] = true;
        emit _VoteCommitted(_pollID, _numTokens, msg.sender);
    }


    function commitVotes(uint[] calldata _pollIDs, bytes32[] calldata _secretHashes, uint[] calldata _numsTokens, uint[] calldata _prevPollIDs) external {

        require(_pollIDs.length == _secretHashes.length);
        require(_pollIDs.length == _numsTokens.length);
        require(_pollIDs.length == _prevPollIDs.length);
        for (uint i = 0; i < _pollIDs.length; i++) {
            commitVote(_pollIDs[i], _secretHashes[i], _numsTokens[i], _prevPollIDs[i]);
        }
    }


    function validPosition(uint _prevID, uint _nextID, address _voter, uint _numTokens) public view returns (bool valid) {
        
        bool prevValid = (_numTokens >= getNumTokens(_voter, _prevID));
        bool nextValid = (_numTokens <= getNumTokens(_voter, _nextID) || _nextID == 0);
        return prevValid && nextValid;
    }


    function revealVote(uint _pollID, uint _voteOption, uint _salt) public {
        
        require(revealPeriodActive(_pollID));
        require(pollMap[_pollID].didCommit[msg.sender]);                        
        require(!pollMap[_pollID].didReveal[msg.sender]);                       
        require(keccak256(abi.encodePacked(_voteOption, _salt)) == getCommitHash(msg.sender, _pollID));

        uint numTokens = getNumTokens(msg.sender, _pollID);

        if (_voteOption == 1) {
            pollMap[_pollID].votesFor += numTokens;
        } else {
            pollMap[_pollID].votesAgainst += numTokens;
        }

        dllMap[msg.sender].remove(_pollID); // remove the node referring to this vote upon reveal
        pollMap[_pollID].didReveal[msg.sender] = true;
        pollMap[_pollID].voteOptions[msg.sender] = _voteOption;

        emit _VoteRevealed(_pollID, numTokens, pollMap[_pollID].votesFor, pollMap[_pollID].votesAgainst, _voteOption, msg.sender, _salt);
    }


    function revealVotes(uint[] calldata _pollIDs, uint[] calldata _voteOptions, uint[] calldata _salts) external {
        
        require(_pollIDs.length == _voteOptions.length);
        require(_pollIDs.length == _salts.length);

        for (uint i = 0; i < _pollIDs.length; i++) {
            revealVote(_pollIDs[i], _voteOptions[i], _salts[i]);
        }
    }


    function getNumPassingTokens(address _voter, uint _pollID) public view returns (uint correctVotes) {
        require(pollEnded(_pollID));
        require(pollMap[_pollID].didReveal[_voter]);

        uint winningChoice = isPassed(_pollID) ? 1 : 0;
        uint voterVoteOption = pollMap[_pollID].voteOptions[_voter];

        require(voterVoteOption == winningChoice, "Voter revealed, but not in the majority");

        return getNumTokens(_voter, _pollID);
    }

    function startPoll(uint _voteQuorum, uint _commitDuration, uint _revealDuration) public returns (uint pollID) {
        pollNonce = pollNonce + 1;

        uint commitEndDate = block.timestamp.add(_commitDuration);
        uint revealEndDate = commitEndDate.add(_revealDuration);

        pollMap[pollNonce] = Poll({
            voteQuorum: _voteQuorum,
            commitEndDate: commitEndDate,
            revealEndDate: revealEndDate,
            votesFor: 0,
            votesAgainst: 0
        });

        emit _PollCreated(_voteQuorum, commitEndDate, revealEndDate, pollNonce, msg.sender);
        return pollNonce;
    }


    function isPassed(uint _pollID) view public returns (bool passed) {
        require(pollEnded(_pollID));

        Poll memory poll = pollMap[_pollID];
        return (100 * poll.votesFor) > (poll.voteQuorum * (poll.votesFor + poll.votesAgainst));
    }


    function getTotalNumberOfTokensForWinningOption(uint _pollID) view public returns (uint numTokens) {
        require(pollEnded(_pollID));

        if (isPassed(_pollID))
            return pollMap[_pollID].votesFor;
        else
            return pollMap[_pollID].votesAgainst;
    }


    function pollEnded(uint _pollID) view public returns (bool ended) {
        require(pollExists(_pollID));

        return isExpired(pollMap[_pollID].revealEndDate);
    }


    function commitPeriodActive(uint _pollID) view public returns (bool active) {
        require(pollExists(_pollID));

        return !isExpired(pollMap[_pollID].commitEndDate);
    }


    function revealPeriodActive(uint _pollID) view public returns (bool active) {
        require(pollExists(_pollID));

        return !isExpired(pollMap[_pollID].revealEndDate) && !commitPeriodActive(_pollID);
    }


    function didCommit(address _voter, uint _pollID) view public returns (bool committed) {
        require(pollExists(_pollID));

        return pollMap[_pollID].didCommit[_voter];
    }


    function didReveal(address _voter, uint _pollID) view public returns (bool revealed) {
        require(pollExists(_pollID));

        return pollMap[_pollID].didReveal[_voter];
    }


    function pollExists(uint _pollID) view public returns (bool exists) {
        return (_pollID != 0 && _pollID <= pollNonce);
    }


    function getCommitHash(address _voter, uint _pollID) view public returns (bytes32 commitHash) {
        return bytes32(store.getAttribute(attrUUID(_voter, _pollID), "commitHash"));
    }


    function getNumTokens(address _voter, uint _pollID) view public returns (uint numTokens) {
        return store.getAttribute(attrUUID(_voter, _pollID), "numTokens");
    }


    function getLastNode(address _voter) view public returns (uint pollID) {
        return dllMap[_voter].getPrev(0);
    }

    function getLockedTokens(address _voter) view public returns (uint numTokens) {
        return getNumTokens(_voter, getLastNode(_voter));
    }


    function getInsertPointForNumTokens(address _voter, uint _numTokens, uint _pollID)
    view public returns (uint prevNode) {
        
        uint nodeID = getLastNode(_voter);
        uint tokensInNode = getNumTokens(_voter, nodeID);

        while(nodeID != 0) {
            
            tokensInNode = getNumTokens(_voter, nodeID);
            if(tokensInNode <= _numTokens) { 
                if(nodeID == _pollID) {
                    nodeID = dllMap[_voter].getPrev(nodeID);
                }
                return nodeID; 
            }
            nodeID = dllMap[_voter].getPrev(nodeID);
        }

        return nodeID;
    }

    function isExpired(uint _terminationDate) view public returns (bool expired) {
        return (block.timestamp > _terminationDate);
    }

    function attrUUID(address _user, uint _pollID) public pure returns (bytes32 UUID) {
        return keccak256(abi.encodePacked(_user, _pollID));
    }
    
    //FUNCTION TESTERS
    
    function __expireCommitDuration(uint256 _pollID) public {
        pollMap[_pollID].commitEndDate = block.timestamp - 1;
        emit OperationSuccess(true);
    }
    
    function __expireRevealDuration(uint256 _pollID) public {
        pollMap[_pollID].revealEndDate = block.timestamp - 1;
        emit OperationSuccess(true);
    }
    
    //OTHERS
    
    function getPoll(uint256 _pollID) public view returns(uint _commitEndDate, uint _revealEndDate){
        _commitEndDate = pollMap[_pollID].commitEndDate;
        _revealEndDate = pollMap[_pollID].revealEndDate;
    }
    
    function getPollNonce() public view returns(uint256){
        return pollNonce;
    }
    
    
}