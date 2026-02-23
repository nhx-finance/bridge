// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BridgeSender
 * @dev Deployed on Hedera Testnet. Handles locking KESY and sending CCIP message.
 */
contract BridgeSender is Ownable {
    using SafeERC20 for IERC20;

    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector);
    error InvalidReceiver();
    error InvalidExtraArgs();

    IRouterClient private s_router;
    IERC20 private s_linkToken;
    IERC20 public s_kesyToken;

    mapping(uint64 => bool) public s_allowlistedChains;
    mapping(uint64 => mapping(bytes32 => bool)) public s_allowlistedReceivers;
    mapping(uint64 => bytes) public s_defaultExtraArgs;

    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        bytes receiver,
        address sender,
        uint256 amount,
        uint256 fees
    );

    constructor(address _router, address _link, address _kesy) Ownable(msg.sender) {
        s_router = IRouterClient(_router);
        s_linkToken = IERC20(_link);
        s_kesyToken = IERC20(_kesy);
    }

    modifier onlyAllowlistedChain(uint64 _destinationChainSelector) {
        if (!s_allowlistedChains[_destinationChainSelector])
            revert DestinationChainNotAllowlisted(_destinationChainSelector);
        _;
    }

    modifier onlyAllowlistedReceiver(uint64 _destinationChainSelector, bytes memory _receiver) {
        if (!s_allowlistedReceivers[_destinationChainSelector][keccak256(_receiver)])
            revert InvalidReceiver();
        _;
    }

    function allowlistDestinationChain(uint64 _destinationChainSelector, bool _allowed) external onlyOwner {
        s_allowlistedChains[_destinationChainSelector] = _allowed;
    }

    function allowlistReceiver(uint64 _destinationChainSelector, bytes calldata _receiver, bool _allowed) external onlyOwner {
        s_allowlistedReceivers[_destinationChainSelector][keccak256(_receiver)] = _allowed;
    }

    function setDefaultExtraArgs(uint64 _destinationChainSelector, bytes calldata _extraArgs) external onlyOwner {
        if (_extraArgs.length == 0) revert InvalidExtraArgs();
        s_defaultExtraArgs[_destinationChainSelector] = _extraArgs;
    }

    /**
     * @notice Sends a cross-chain message to mint wKESY on the destination chain.
     * @param _destinationChainSelector The identifier of the destination chain.
     * @param _receiver The encoded receiver bytes on the destination chain.
     * @param _amount The amount of KESY to bridge.
     */
    function bridgeKESY(
        uint64 _destinationChainSelector,
        bytes calldata _receiver,
        uint256 _amount
    )
        external
        onlyAllowlistedChain(_destinationChainSelector)
        onlyAllowlistedReceiver(_destinationChainSelector, _receiver)
        returns (bytes32 messageId)
    {
        return _bridgeKESY(_destinationChainSelector, _receiver, _amount, s_defaultExtraArgs[_destinationChainSelector]);
    }

    /**
     * @notice Sends a cross-chain message with per-call extraArgs override.
     * @param _destinationChainSelector The identifier of the destination chain.
     * @param _receiver The encoded receiver bytes on the destination chain.
     * @param _amount The amount of KESY to bridge.
     * @param _extraArgs Encoded chain-specific extraArgs for execution settings.
     */
    function bridgeKESYWithExtraArgs(
        uint64 _destinationChainSelector,
        bytes calldata _receiver,
        uint256 _amount,
        bytes calldata _extraArgs
    )
        external
        onlyAllowlistedChain(_destinationChainSelector)
        onlyAllowlistedReceiver(_destinationChainSelector, _receiver)
        returns (bytes32 messageId)
    {
        return _bridgeKESY(_destinationChainSelector, _receiver, _amount, _extraArgs);
    }

    function _bridgeKESY(
        uint64 _destinationChainSelector,
        bytes memory _receiver,
        uint256 _amount,
        bytes memory _extraArgs
    )
        internal
        returns (bytes32 messageId)
    {
        if (_extraArgs.length == 0) revert InvalidExtraArgs();

        // 1. Lock KESY tokens from the user
        s_kesyToken.safeTransferFrom(msg.sender, address(this), _amount);

        // 2. Construct the CCIP message
        // Since we are using messaging fallback (no CCT pool), we pack the mint instructions in 'data'
        bytes memory data = abi.encode(msg.sender, _amount);

        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: _receiver,
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: _extraArgs,
            feeToken: address(s_linkToken)
        });

        // 3. Calculate fees
        uint256 fees = s_router.getFee(_destinationChainSelector, evm2AnyMessage);

        if (fees > s_linkToken.balanceOf(address(this)))
            revert NotEnoughBalance(s_linkToken.balanceOf(address(this)), fees);

        // 4. Approve router to spend LINK for fees
        s_linkToken.approve(address(s_router), fees);

        // 5. Dispatch message
        messageId = s_router.ccipSend(_destinationChainSelector, evm2AnyMessage);

        emit MessageSent(messageId, _destinationChainSelector, _receiver, msg.sender, _amount, fees);

        return messageId;
    }

    function withdrawToken(address _tokenAddress, address _to) external onlyOwner {
        uint256 balance = IERC20(_tokenAddress).balanceOf(address(this));
        IERC20(_tokenAddress).safeTransfer(_to, balance);
    }
}
