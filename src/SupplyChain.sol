// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Contrato SupplyChainTracker
/// @author Luis Carlos Gracia Puentes
/// @notice Contrato para terminar bloque Web3-React.
/// @dev Las funciones se definen de acuerdo a los requerimientos del planteamiento del proyecto final.

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract SupplyChainTracker is ReentrancyGuard {
    // --- Constants ---
    bytes32 private constant PRODUCER = keccak256("Producer");
    bytes32 private constant FACTORY = keccak256("Factory");
    bytes32 private constant RETAILER = keccak256("Retailer");
    bytes32 private constant CONSUMER = keccak256("Consumer");

    // --- Enums ---
    enum UserStatus { Pending, Approved, Rejected, Canceled }
    enum TransferStatus { Pending, Accepted, Rejected }

    // --- Structs ---
    struct Token {
        uint256 id;
        address creator;
        string name;
        uint256 totalSupply;
        string features;
        uint256 parentId;
        uint256 dateCreated;
        mapping(address => uint256) balance;
    }

    struct Transfer {
        uint256 id;
        address from;
        address to;
        uint256 tokenId;
        uint256 dateCreated;
        uint256 amount;
        TransferStatus status;
    }

    struct User {
        uint256 id;
        address userAddress;
        bytes32 role;
        UserStatus status;
    }

    // --- State Variables ---
    address public immutable admin;
    uint256 public nextTokenId = 1;
    uint256 public nextTransferId = 1;
    uint256 public nextUserId = 1;

    mapping(uint256 => Token) public tokens;
    mapping(uint256 => Transfer) public transfers;
    mapping(uint256 => User) public users;
    mapping(address => uint256) public addressToUserId;

    // --- Events ---
    event TokenCreated(uint256 indexed tokenId, address indexed creator, string name, uint256 totalSupply);
    event TransferRequested(uint256 indexed transferId, address indexed from, address indexed to, uint256 tokenId, uint256 amount);
    event TransferAccepted(uint256 indexed transferId);
    event TransferRejected(uint256 indexed transferId);
    event UserRoleRequested(address indexed user, bytes32 role);
    event UserStatusChanged(address indexed user, UserStatus status);

    // --- Modifiers ---
    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    modifier onlyApprovedUser() {
        uint256 userId = addressToUserId[msg.sender];
        require(userId != 0 && users[userId].status == UserStatus.Approved, "Not approved");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    // --- User Management ---
    function requestUserRole(bytes32 role) public {
        require(role != 0, "Invalid role");
        uint256 userId = addressToUserId[msg.sender];
        if (userId == 0) {
            userId = nextUserId++;
            users[userId] = User({
                id: userId,
                userAddress: msg.sender,
                role: role,
                status: UserStatus.Pending
            });
            addressToUserId[msg.sender] = userId;
        } else {
            users[userId].role = role;
            users[userId].status = UserStatus.Pending;
        }
        emit UserRoleRequested(msg.sender, role);
        emit UserStatusChanged(msg.sender, UserStatus.Pending);
    }

    function changeStatusUser(address userAddress, UserStatus newStatus) public onlyAdmin {
        uint256 userId = addressToUserId[userAddress];
        require(userId != 0, "User not found");
        users[userId].status = newStatus;
        emit UserStatusChanged(userAddress, newStatus);
    }

    function getUserInfo(address userAddress) public view returns (User memory) {
        uint256 userId = addressToUserId[userAddress];
        return userId == 0 ? User(0, address(0), "", UserStatus.Rejected) : users[userId];
    }

    // --- Token Management ---
    function createToken(
        string calldata name,
        uint256 totalSupply,
        string calldata features,
        uint256 parentId
    ) public onlyApprovedUser {
        require(bytes(name).length > 0, "Name empty");
        uint256 newId = nextTokenId++;
        Token storage tkn = tokens[newId];
        tkn.id = newId;
        tkn.creator = msg.sender;
        tkn.name = name;
        tkn.totalSupply = totalSupply;
        tkn.features = features;
        tkn.parentId = parentId;
        tkn.dateCreated = block.timestamp;
        tkn.balance[msg.sender] = totalSupply; // Initialize balance
        emit TokenCreated(newId, msg.sender, name, totalSupply);
    }

    function getToken(uint256 tokenId) public view returns (
        uint256 id,
        address creator,
        string memory name,
        uint256 totalSupply,
        uint256 parentId,
        uint256 dateCreated,
        uint256 balance
    ) {
        Token storage token = tokens[tokenId];
        return (
            token.id,
            token.creator,
            token.name,
            token.totalSupply,
            token.parentId,
            token.dateCreated,
            token.balance[msg.sender]
        );
    }

    function getTokenBalance(uint256 tokenId, address user) public view returns (uint256) {
        require(tokenId < nextTokenId, "Token does not exist");
        return tokens[tokenId].balance[user];
    }

    // --- Transfer Management ---
    function transfer(address to, uint256 tokenId, uint256 amount) public onlyApprovedUser nonReentrant {
        require(to != address(0) && to != msg.sender, "Invalid recipient");
        require(amount > 0, "Amount must be > 0");
        require(tokenId < nextTokenId, "Token does not exist");

        uint256 userId = addressToUserId[msg.sender];
        uint256 toId = addressToUserId[to];
        require(toId != 0, "Recipient not registered");
        require(!_isConsumer(users[userId].role), "Consumer cannot transfer");
        require(_isNextRole(users[userId].role, users[toId].role), "Invalid role transition");

        Token storage tkn = tokens[tokenId];
        require(tkn.balance[msg.sender] >= amount, "Insufficient balance");

        tkn.balance[msg.sender] -= amount;
        tkn.balance[to] += amount;

        uint256 newTransferId = nextTransferId++;
        transfers[newTransferId] = Transfer({
            id: newTransferId,
            from: msg.sender,
            to: to,
            tokenId: tokenId,
            dateCreated: block.timestamp,
            amount: amount,
            status: TransferStatus.Pending
        });
        emit TransferRequested(newTransferId, msg.sender, to, tokenId, amount);
    }

    function acceptTransfer(uint256 transferId) public onlyApprovedUser {
        Transfer storage tr = transfers[transferId];
        require(tr.status == TransferStatus.Pending, "Not pending");
        require(msg.sender == tr.to, "Not recipient");

        uint256 toId = addressToUserId[tr.to];
        require(_isNextRole(users[addressToUserId[tr.from]].role, users[toId].role), "Invalid role transition");

        tr.status = TransferStatus.Accepted;
        emit TransferAccepted(transferId);
    }

    function rejectTransfer(uint256 transferId) public nonReentrant {
        Transfer storage tr = transfers[transferId];
        require(tr.status == TransferStatus.Pending, "Not pending");
        require(msg.sender == tr.to || msg.sender == admin, "Not authorized");

        Token storage tkn = tokens[tr.tokenId];
        tkn.balance[tr.from] += tr.amount;
        tr.status = TransferStatus.Rejected;
        emit TransferRejected(transferId);
    }

    // --- Helper Functions ---
    function _isNextRole(bytes32 fromRole, bytes32 toRole) internal pure returns (bool) {
        return (
            (fromRole == PRODUCER && toRole == FACTORY) ||
            (fromRole == FACTORY && toRole == RETAILER) ||
            (fromRole == RETAILER && toRole == CONSUMER)
        );
    }

    function _isConsumer(bytes32 role) internal pure returns (bool) {
        return role == CONSUMER;
    }

    // Optimized: Single-pass for counting and collecting
    function getUserTokens(address user) public view returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](nextTokenId - 1);
        uint256 count = 0;
        for (uint256 i = 1; i < nextTokenId; i++) {
            Token storage t = tokens[i];
            if (t.creator == user || t.balance[user] > 0) {
                ids[count++] = i;
            }
        }
        // Trim array (Solidity doesn't support dynamic resizing)
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = ids[i];
        }
        return result;
    }

    function getUserTransfers(address user) public view returns (uint256[] memory) {
        uint256[] memory ids = new uint256[](nextTransferId - 1);
        uint256 count = 0;
        for (uint256 i = 1; i < nextTransferId; i++) {
            Transfer storage tr = transfers[i];
            if (tr.from == user || tr.to == user) {
                ids[count++] = i;
            }
        }
        uint256[] memory result = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = ids[i];
        }
        return result;
    }
}