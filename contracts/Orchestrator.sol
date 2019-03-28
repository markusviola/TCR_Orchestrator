pragma solidity ^0.5.4;

import "./ERC20Detailed.sol";
import "./ProxyFactory.sol";

interface IPLCRVoting {
    function init(address _token, address _tokenOwner) external;
}

interface IParameterizer {
    function init(address _token, address _plcr, uint256[] calldata _parameters) external;
}

interface IRegistry {
    function init(address _token, string calldata _name, address _parameterizer, address _voting) external;
}

contract Orchestrator {
    
    ProxyFactory public proxyFactory;
    IPLCRVoting public canonPLCR;
    IParameterizer public canonParam;
    IRegistry public canonRegistry;
    
    struct EnvInstance {
        address creator;
        address plcrInstance;
        address paramInstance;
        address regInstance;
        address erc20Instance;
    }
    
    mapping (uint256 => EnvInstance) public envInstances;
    
    uint256 instanceCtr;
    
    constructor () public {
        canonPLCR = IPLCRVoting(0x9cF553ED77E7eE375A657Aa2095bcaE9392b0FA6);
        canonParam = IParameterizer(0x3E20429F539f4c65e78D9De6BdD33FEE46B49885);
        canonRegistry = IRegistry(0x15EfAc3cCA03f1D5572B023287C0eef316F30974);
        proxyFactory = new ProxyFactory();
    }
    
    event onCreateEnvironment(address origin, IParameterizer param, IRegistry reg, ERC20Detailed token, IPLCRVoting plcr);
    
    function buildEnv(ERC20Detailed _token, string memory _registryName, uint256[] memory _parameters) public {
        
        IPLCRVoting plcr = IPLCRVoting(proxyFactory.createProxy(address(canonPLCR), ""));
        plcr.init(address(_token), msg.sender);
        
        IParameterizer param = IParameterizer(proxyFactory.createProxy(address(canonParam), ""));
        param.init(address(_token), address(plcr), _parameters);
        
        IRegistry reg = IRegistry(proxyFactory.createProxy(address(canonRegistry), ""));
        reg.init(address(_token), _registryName, address(param), address(plcr));
        
        envInstances[++instanceCtr] = EnvInstance({
            creator: msg.sender,
            plcrInstance: address(plcr),
            paramInstance: address(param),
            regInstance: address(reg),
            erc20Instance: address(_token)
        });
        
        emit onCreateEnvironment(msg.sender, param, reg, _token, plcr);
        
    }
    
    function buildEnvAndToken(uint256 _supply, string memory _tokenName, uint8 _decimals, string memory _symbol, uint256[] memory _parameters, string memory _registryName) public {
        
        ERC20Detailed token = new ERC20Detailed(msg.sender, _tokenName, _symbol, _decimals);
        token.mint(msg.sender, _supply);
    
        IPLCRVoting plcr = IPLCRVoting(proxyFactory.createProxy(address(canonPLCR), ""));
        plcr.init(address(token), msg.sender);
        
        IParameterizer param = IParameterizer(proxyFactory.createProxy(address(canonParam), ""));
        param.init(address(token), address(plcr), _parameters);
        
        IRegistry reg = IRegistry(proxyFactory.createProxy(address(canonRegistry), ""));
        reg.init(address(token), _registryName, address(param), address(plcr));
        
        envInstances[++instanceCtr] = EnvInstance({
            creator: msg.sender,
            plcrInstance: address(plcr),
            paramInstance: address(param),
            regInstance: address(reg),
            erc20Instance: address(token)
        });
        
        emit onCreateEnvironment(msg.sender, param, reg, token, plcr);
    }
    
    function getEnvInstances(uint256 _id, address _creator) public view returns(address _plcr, address _param, address _reg) {
        
        require(msg.sender == _creator);
        require(envInstances[_id].creator == _creator);
        
        _plcr = envInstances[_id].plcrInstance;
        _param = envInstances[_id].paramInstance;
        _reg = envInstances[_id].regInstance;
        
    }
    
    function getEnvCount() public view returns(uint256){
        return instanceCtr;
    }
    
}