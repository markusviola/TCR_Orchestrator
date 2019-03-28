pragma solidity ^0.5.3;

contract ProxyFactory {
    
    event ProxyDeployed(address proxyAddress, address targetAddress);
    event ProxiesDeployed(address[] proxyAddresses, address targetAddress);

    function createProxy(address _target, bytes memory _data)
        public
        returns (address proxyContract)
    {
        proxyContract = createProxyImpl(_target, _data);

        emit ProxyDeployed(proxyContract, _target);
    }
    
    function createProxyImpl(address _target, bytes memory _data)
        internal
        returns (address proxyContract)
    {
        assembly {
            let contractCode := mload(0x40) 
           
            mstore(add(contractCode, 0x0b), _target) 
            mstore(sub(contractCode, 0x09), 0x000000000000000000603160008181600b9039f3600080808080368092803773) 
            mstore(add(contractCode, 0x2b), 0x5af43d828181803e808314602f57f35bfd000000000000000000000000000000) 

            proxyContract := create(0, contractCode, 60) // total length 60 bytes
            if iszero(extcodesize(proxyContract)) {
                revert(0, 0)
            }
           
            // check if the _data.length > 0 and if it is forward it to the newly created contract
            let dataLength := mload(_data) 
            if iszero(iszero(dataLength)) {
                if iszero(call(gas, proxyContract, 0, add(_data, 0x20), dataLength, 0, 0)) {
                    revert(0, 0)
                }
            }
        }
    }
}
