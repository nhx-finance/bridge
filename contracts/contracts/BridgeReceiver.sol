// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {OwnerIsCreator} from "@chainlink/contracts-ccip/src/v0.8/shared/access/OwnerIsCreator.sol";

interface IwKESY {
    function mint(address _to, uint256 _amount) external;
}

/**
 * @title BridgeReceiver
 * @dev Deployed on Ethereum Sepolia. Handles receiving CCIP message and minting tokens.
 */
contract BridgeReceiver is CCIPReceiver, OwnerIsCreator {
    error SourceChainNotAllowlisted(uint64 sourceChainSelector);
    error SenderNotAllowlisted(bytes sender);

    IwKESY public s_wkesyToken;

    mapping(uint64 => bool) public s_allowlistedSourceChains;
    mapping(uint64 => mapping(bytes32 => bool)) public s_allowlistedSenders;

    event MessageReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        bytes sender,
        address user,
        uint256 amount
    );

    constructor(address _router, address _wkesy) CCIPReceiver(_router) {
        s_wkesyToken = IwKESY(_wkesy);
    }

    modifier onlyAllowlisted(uint64 _sourceChainSelector, bytes memory _sender) {
        if (!s_allowlistedSourceChains[_sourceChainSelector])
            revert SourceChainNotAllowlisted(_sourceChainSelector);
        if (!s_allowlistedSenders[_sourceChainSelector][keccak256(_sender)])
            revert SenderNotAllowlisted(_sender);
        _;
    }

    function allowlistSourceChain(uint64 _sourceChainSelector, bool _allowed) external onlyOwner {
        s_allowlistedSourceChains[_sourceChainSelector] = _allowed;
    }

    function allowlistSender(uint64 _sourceChainSelector, bytes calldata _sender, bool _allowed) external onlyOwner {
        s_allowlistedSenders[_sourceChainSelector][keccak256(_sender)] = _allowed;
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    )
        internal
        override
        onlyAllowlisted(any2EvmMessage.sourceChainSelector, any2EvmMessage.sender)
    {
        (address user, uint256 amount) = abi.decode(any2EvmMessage.data, (address, uint256));
        
        // Mint wKESY to the user
        s_wkesyToken.mint(user, amount);

        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector,
            any2EvmMessage.sender,
            user,
            amount
        );
    }
}
