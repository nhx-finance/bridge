// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IwKESY {
    function mint(address to, uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

/**
 * @title KESYOmniBridge
 * @dev Bi-directional bridge for KESY tokens using Chainlink CCIP.
 * Can act as a Hub (locks/unlocks native KESY) or a Spoke (burns/mints wKESY).
 */
contract KESYOmniBridge is CCIPReceiver, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees);
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector);
    error SourceChainNotAllowlisted(uint64 sourceChainSelector);
    error SenderNotAllowlisted(address sender);
    error InvalidReceiver();
    error InvalidExtraArgs();
    error InvalidBridgeType();

    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        bytes receiver,
        address sender,
        uint256 amount,
        uint256 fees
    );

    event MessageReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address sender,
        address recipient,
        uint256 amount
    );

    IERC20 public immutable i_linkToken;
    IERC20 public immutable i_token; // The token being bridged (KESY or wKESY)
    bool public immutable i_isHub;   // True if Hedera (locks/unlocks), False if EVM (burns/mints)

    // Routing configuration
    mapping(uint64 => bool) public s_allowlistedDestinationChains;
    mapping(uint64 => bool) public s_allowlistedSourceChains;
    mapping(uint64 => mapping(bytes32 => bool)) public s_allowlistedReceivers;
    mapping(uint64 => mapping(bytes32 => bool)) public s_allowlistedSenders;
    mapping(uint64 => bytes) public s_defaultExtraArgs;

    modifier onlyAllowlistedDestination(uint64 _destinationChainSelector) {
        if (!s_allowlistedDestinationChains[_destinationChainSelector])
            revert DestinationChainNotAllowlisted(_destinationChainSelector);
        _;
    }

    modifier onlyAllowlistedReceiver(uint64 _destinationChainSelector, bytes memory _receiver) {
        if (!s_allowlistedReceivers[_destinationChainSelector][keccak256(_receiver)])
            revert InvalidReceiver();
        _;
    }

    modifier onlyAllowlistedSource(uint64 _sourceChainSelector) {
        if (!s_allowlistedSourceChains[_sourceChainSelector])
            revert SourceChainNotAllowlisted(_sourceChainSelector);
        _;
    }

    modifier onlyAllowlistedSender(uint64 _sourceChainSelector, bytes memory _sender) {
        if (!s_allowlistedSenders[_sourceChainSelector][keccak256(_sender)])
            revert SenderNotAllowlisted(abi.decode(_sender, (address)));
        _;
    }

    constructor(address _router, address _link, address _token, bool _isHub) 
        CCIPReceiver(_router)
        Ownable(msg.sender)
    {
        i_linkToken = IERC20(_link);
        i_token = IERC20(_token);
        i_isHub = _isHub;
    }

    // ================================================================
    // │                        CONFIGURATION                         │
    // ================================================================

    function allowlistDestinationChain(uint64 _destinationChainSelector, bool _allowed) external onlyOwner {
        s_allowlistedDestinationChains[_destinationChainSelector] = _allowed;
    }

    function allowlistSourceChain(uint64 _sourceChainSelector, bool _allowed) external onlyOwner {
        s_allowlistedSourceChains[_sourceChainSelector] = _allowed;
    }

    function allowlistReceiver(uint64 _destinationChainSelector, bytes calldata _receiver, bool _allowed) external onlyOwner {
        s_allowlistedReceivers[_destinationChainSelector][keccak256(_receiver)] = _allowed;
    }

    function allowlistSender(uint64 _sourceChainSelector, bytes calldata _sender, bool _allowed) external onlyOwner {
        s_allowlistedSenders[_sourceChainSelector][keccak256(_sender)] = _allowed;
    }

    function setDefaultExtraArgs(uint64 _destinationChainSelector, bytes calldata _extraArgs) external onlyOwner {
        if (_extraArgs.length == 0) revert InvalidExtraArgs();
        s_defaultExtraArgs[_destinationChainSelector] = _extraArgs;
    }

    // ================================================================
    // │                        SEND LOGIC                            │
    // ================================================================

    /**
     * @notice Sends a cross-chain message to bridge tokens.
     * @param _destinationChainSelector The identifier of the destination chain.
     * @param _receiver The encoded receiver address on the destination chain.
     * @param _amount The amount of KESY/wKESY to bridge.
     */
    function bridgeKESY(
        uint64 _destinationChainSelector,
        bytes calldata _receiver,
        uint256 _amount
    )
        external
        nonReentrant
        returns (bytes32 messageId)
    {
        return _bridgeKESY(_destinationChainSelector, _receiver, _amount, s_defaultExtraArgs[_destinationChainSelector]);
    }

    function bridgeKESYWithExtraArgs(
        uint64 _destinationChainSelector,
        bytes calldata _receiver,
        uint256 _amount,
        bytes calldata _extraArgs
    )
        external
        nonReentrant
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
        onlyAllowlistedDestination(_destinationChainSelector)
        onlyAllowlistedReceiver(_destinationChainSelector, _receiver)
        returns (bytes32 messageId)
    {
        if (_extraArgs.length == 0) revert InvalidExtraArgs();

        // 1. Process tokens based on Role
        if (i_isHub) {
            // HUB (Hedera): Lock native KESY tokens from the user into the contract vault
            i_token.safeTransferFrom(msg.sender, address(this), _amount);
        } else {
            // SPOKE (EVM): Burn wKESY tokens from the user
            IwKESY(address(i_token)).burnFrom(msg.sender, _amount);
        }

        // 2. Construct CCIP message (packing recipient address and amount)
        bytes memory data = abi.encode(msg.sender, _amount);

        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: _receiver,
            data: data,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: _extraArgs,
            feeToken: address(i_linkToken)
        });

        // 3. Calculate fees
        uint256 fees = IRouterClient(this.getRouter()).getFee(_destinationChainSelector, evm2AnyMessage);
        if (fees > i_linkToken.balanceOf(address(this))) {
            revert NotEnoughBalance(i_linkToken.balanceOf(address(this)), fees);
        }

        // 4. Dispatch message
        i_linkToken.approve(address(this.getRouter()), fees);
        messageId = IRouterClient(this.getRouter()).ccipSend(_destinationChainSelector, evm2AnyMessage);

        emit MessageSent(messageId, _destinationChainSelector, _receiver, msg.sender, _amount, fees);

        return messageId;
    }

    // ================================================================
    // │                       RECEIVE LOGIC                          │
    // ================================================================

    function _ccipReceive(Client.Any2EVMMessage memory any2EvmMessage)
        internal
        override
        onlyAllowlistedSource(any2EvmMessage.sourceChainSelector)
        onlyAllowlistedSender(any2EvmMessage.sourceChainSelector, any2EvmMessage.sender)
    {
        (address recipient, uint256 amount) = abi.decode(any2EvmMessage.data, (address, uint256));

        // Process tokens based on Role
        if (i_isHub) {
            // HUB (Hedera): Unlock KESY tokens from vault and send to user
            i_token.safeTransfer(recipient, amount);
        } else {
            // SPOKE (EVM): Mint new wKESY tokens to the user
            IwKESY(address(i_token)).mint(recipient, amount);
        }

        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address)),
            recipient,
            amount
        );
    }

    // ================================================================
    // │                           ADMIN                              │
    // ================================================================

    /**
     * @notice Associates the contract with a Hedera HTS token.
     * @dev Required for Hedera tokens before the contract can receive them.
     */
    function associateToken(address _tokenAddr) external onlyOwner {
        require(i_isHub, "Only Hub needs association");
        (bool success, bytes memory result) = address(0x167).call(
            abi.encodeWithSignature("associateToken(address,address)", address(this), _tokenAddr)
        );
        require(success && (result.length == 0 || abi.decode(result, (int32)) == 22), "Association failed");
    }

    function withdrawToken(address _tokenAddress, address _to) external onlyOwner {
        uint256 balance = IERC20(_tokenAddress).balanceOf(address(this));
        IERC20(_tokenAddress).safeTransfer(_to, balance);
    }
}
