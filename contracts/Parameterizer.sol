pragma solidity ^0.5.4;

import "./PLCRVoting.sol";
import "./ERC20Detailed.sol";
import "https://github.com/OpenZeppelin/openzeppelin-solidity/contracts/math/SafeMath.sol";

contract Parameterizer {
    using SafeMath for uint;
    
    struct PChallenge {
        address pChallenger;
        uint256 pIncentivePool;
        bool pIsConcluded;
        uint256 pStake;
        uint256 pWonTokens;
        mapping(address => bool) pIncentiveClaims;
    }

    struct Proposal {
        address pIssuer;
        uint256 pChallengeID;
        uint256 proposalExpiry;
        string paramName;
        uint256 paramVal;
        uint256 pDeposit;
        uint256 processBy;
    }
    
    mapping(bytes32 => uint256) public params;
    mapping(uint256 => PChallenge) public challenges;
    mapping(bytes32 => Proposal) public proposals;
    
    bytes32[] proposalNonce;
    uint256[] challengeNonce;
    
    
    ERC20Detailed public token;
    PLCRVoting public voting;
    uint256 public PROCESSBY = 0; //604800
    
    event NewProposal(address issuer, bytes32 proposalID, string name, uint value, uint deposit, uint appEndDate);
    event NewProposalChallenge(address challenger, bytes32 proposalID, uint challengeID, uint commitEndDate, uint revealEndDate);
    event PChallengerWon(bytes32 proposalID, uint challengeID, uint incentivePool, uint wonTokens);
    event PChallengerLost(bytes32 proposalID, uint challengeID, uint incentivePool, uint wonTokens);
    event ProposalPassed(bytes32 proposalID, string name, uint value);
    event ProposalExpired(bytes32 proposalID);
    event IncentiveClaimed(address voter, uint challengeID, uint incentive);
    event OperationSuccess(bool success);
    
    function init(address _token, address _plcr, uint256[] memory _parameters) public {
        
        require(address(token) == address(0));
        require(address(_plcr) != address(0) && address(voting) == address(0));

        token = ERC20Detailed(_token);
        voting = PLCRVoting(_plcr);
        
        //300,300,3600,3600,3600,3600,3600,3600,50,50,50,50
        set("minDeposit", _parameters[0]);
        set("pMinDeposit", _parameters[1]);
        set("applyStageLen", _parameters[2]);
        set("pApplyStageLen", _parameters[3]);
        set("commitStageLen", _parameters[4]);
        set("pCommitStageLen", _parameters[5]);
        set("revealStageLen", _parameters[6]);
        set("pRevealStageLen", _parameters[7]);
        set("dispensationPct", _parameters[8]);
        set("pDispensationPct", _parameters[9]);
        set("voteQuorum", _parameters[10]);
        set("pVoteQuorum", _parameters[11]);
        
    }

    function proposeAdjustment(string memory _paramName, uint _paramVal) public {
        uint minDeposit = get("pMinDeposit");
        bytes32 proposalID = keccak256(abi.encodePacked(_paramName, _paramVal));

        if (keccak256(abi.encodePacked(_paramName)) == keccak256(abi.encodePacked("dispensationPct")) ||
            keccak256(abi.encodePacked(_paramName)) == keccak256(abi.encodePacked("pDispensationPct"))) {
            require(_paramVal <= 100);
        }

        require(!exisitingProposal(proposalID)); 
        require(get(_paramName) != _paramVal); 

        Proposal storage proposal = proposals[proposalID]; 
        proposalNonce.push(proposalID);
        
        proposal.pIssuer = msg.sender;
        proposal.pChallengeID = 0; //i will check if omittable. 
        proposal.proposalExpiry = now.add(get("pApplyStageLen"));
        proposal.pDeposit = minDeposit;
        proposal.paramName = _paramName;
        proposal.processBy = now.add(get("pApplyStageLen")).add(get("pCommitStageLen")).add(get("pRevealStageLen")).add(PROCESSBY);
        proposal.paramVal = _paramVal;

        require(token.transferFrom(msg.sender, address(this), minDeposit));
        emit NewProposal(msg.sender, proposalID, _paramName, _paramVal, minDeposit, proposal.proposalExpiry);
    }

    function challengeProposal(bytes32 _proposalID) public {
        Proposal storage proposal = proposals[_proposalID];
        uint minDeposit = proposal.pDeposit;

        require(exisitingProposal(_proposalID) && proposal.pChallengeID == 0);
        
        proposal.pChallengeID = voting.startPoll(
            get("pVoteQuorum"),
            get("pCommitStageLen"),
            get("pRevealStageLen")
        );

        PChallenge storage _challenge = challenges[proposal.pChallengeID];
        
        challengeNonce.push(proposal.pChallengeID);
        _challenge.pChallenger = msg.sender;
        _challenge.pIncentivePool = SafeMath.sub(100, get("pDispensationPct")).mul(minDeposit).div(100);
        _challenge.pStake = minDeposit;
        _challenge.pIsConcluded = false; //i will check if omittable. 
        _challenge.pWonTokens = 0; //i will check if omittable. 
    
        require(token.transferFrom(msg.sender, address(this), minDeposit));

        (uint commitEndDate, uint revealEndDate,,,) = voting.pollMap(proposal.pChallengeID);
        emit NewProposalChallenge(msg.sender, _proposalID, proposal.pChallengeID, commitEndDate, revealEndDate);
    }

    //i will review this 
    function processProposalResult(bytes32 _proposalID) public {
        Proposal storage proposal = proposals[_proposalID];

        if (proposalPassed(_proposalID)) {
            set(proposal.paramName, proposal.paramVal);
            emit ProposalPassed(_proposalID, proposal.paramName, proposal.paramVal);
            delete proposals[_proposalID];
            require(token.transfer(proposal.pIssuer, proposal.pDeposit));
        } 
        else if (challengeCanBeConcluded(_proposalID)) {
            concludeChallenge(_proposalID);
        } 
        else if (now > proposal.processBy) {
            emit ProposalExpired(_proposalID);
            delete proposals[_proposalID];
            require(token.transfer(proposal.pIssuer, proposal.pDeposit));
        }
        else revert();

        assert(get("dispensationPct") <= 100);
        assert(get("pDispensationPct") <= 100);
        now.add(get("pApplyStageLen")).add(get("pCommitStageLen")).add(get("pRevealStageLen")).add(PROCESSBY);

        delete proposals[_proposalID];
        emit OperationSuccess(true);
    }

    //Needs to be looped.
    function claimIncentive(uint256 _challengeID) public {
        PChallenge storage challenge = challenges[_challengeID];
        require(incentiveClaimStatus(_challengeID,msg.sender) == false);
        require(challenge.pIsConcluded == true);

        uint voterStake = voting.getNumPassingTokens(msg.sender, _challengeID);
        uint incentive = voterStake.mul(challenge.pIncentivePool).div(challenge.pWonTokens);

        challenge.pWonTokens -= voterStake;
        challenge.pIncentivePool -= incentive;

        challenge.pIncentiveClaims[msg.sender] = true;

        emit IncentiveClaimed(msg.sender, _challengeID, incentive);
        require(token.transfer(msg.sender, incentive));
    }

    function batchClaimIncentives(uint256[] memory _challengeIDs) public {
        for(uint256 i = 0; i < _challengeIDs.length; i++) claimIncentive(_challengeIDs[i]);
    }

    function viewVoterIncentive(address _voter, uint _challengeID) public view returns(uint256) {
        uint256 voterStake = voting.getNumPassingTokens(_voter, _challengeID);
        uint256 wonTokens = challenges[_challengeID].pWonTokens;
        uint256 incentivePool = challenges[_challengeID].pIncentivePool;

        return voterStake.mul(incentivePool).div(wonTokens);
    }

    function incentiveClaimStatus(uint256 _challengeID, address _voter) public view returns(bool) {
        return challenges[_challengeID].pIncentiveClaims[_voter];
    }

    function proposalPassed(bytes32 _proposalID) view public returns (bool) {
        Proposal memory proposal = proposals[_proposalID];

        return (now > proposal.proposalExpiry &&
                now < proposal.processBy && 
                proposal.pChallengeID == 0);
    }

    function challengeCanBeConcluded(bytes32 _proposalID) view public returns (bool) {
        Proposal memory proposal = proposals[_proposalID];

        return (proposal.pChallengeID > 0 &&
                challenges[proposal.pChallengeID].pIsConcluded == false &&
                voting.pollEnded(proposal.pChallengeID));
    }

    function exisitingProposal(bytes32 _propID) view public returns(bool) {
        return proposals[_propID].processBy > 0;
    }
    
    function set(string memory _name, uint256 _value) public {
        params[keccak256(abi.encodePacked(_name))] = _value;
    }

    function get(string memory _name) public view returns(uint256 value){
        return params[keccak256(abi.encodePacked(_name))];
    }

    //i will review this 
    function concludeChallenge(bytes32 _proposalID) private {
        Proposal memory proposal = proposals[_proposalID];
        PChallenge storage challenge = challenges[proposal.pChallengeID];

        uint incentive = calculateIncentive(proposal.pChallengeID);

        challenge.pWonTokens = voting.getTotalNumberOfTokensForWinningOption(proposal.pChallengeID);
        challenge.pIsConcluded = true;

        if (voting.isPassed(proposal.pChallengeID)) { 
            if(proposal.processBy > now) {
                set(proposal.paramName, proposal.paramVal);
            }
            emit PChallengerLost(_proposalID, proposal.pChallengeID, challenge.pIncentivePool, challenge.pWonTokens);
            require(token.transfer(proposal.pIssuer, incentive));
        }
        else {
            emit PChallengerWon(_proposalID, proposal.pChallengeID, challenge.pIncentivePool, challenge.pWonTokens);
            require(token.transfer(challenge.pChallenger, incentive));
        }
    }

    function calculateIncentive(uint256 _challengeID) public view returns (uint256) {
        if(voting.getTotalNumberOfTokensForWinningOption(_challengeID) == 0) {
            return 2 * challenges[_challengeID].pStake;
        }

        return (2 * challenges[_challengeID].pStake) - challenges[_challengeID].pIncentivePool;
    }
    
    //FUNCTION TESTERS
    
    function __expireProposal(bytes32 _proposalID) public {
        proposals[_proposalID].proposalExpiry = now - 1;
        emit OperationSuccess(true);
    }
    
    //OTHERS
    
    function getProposalNonce() public view returns(bytes32[] memory){
        return proposalNonce;
    }
    
    function getChallengeNonce() public view returns(uint256[] memory){
        return challengeNonce;
    }
    
    function getChallenge(uint256 _challengeID) public view returns(bool _isConcluded, uint256 _incentivePool, address _challenger) {
        _challenger = challenges[_challengeID].pChallenger;
        _isConcluded = challenges[_challengeID].pIsConcluded;
        _incentivePool = challenges[_challengeID].pIncentivePool;
    }
    
    function getProposal(bytes32 _proposalID) public view returns(string memory _paramName, uint256 _paramVal, uint256 _challengeID, uint256 _proposalExpiry){
        _paramName = proposals[_proposalID].paramName;
        _paramVal =  proposals[_proposalID].paramVal;
        _challengeID = proposals[_proposalID].pChallengeID;
        _proposalExpiry = proposals[_proposalID].proposalExpiry;
    }
    
}