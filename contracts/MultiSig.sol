// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MultiSigWallet is ReentrancyGuard {
    event Submit(
        uint256 indexed txId,
        address indexed destination,
        uint256 value,
        bytes data
    );
    event Confirm(address indexed owner, uint256 indexed txId);
    event Execute(uint256 indexed txId);

    address[3] public owners;
    mapping(address => bool) public isOwner;
    uint256 public constant REQUIRED = 2;

    struct Transaction {
        address destination;
        uint256 value;
        bytes data;
        bool executed;
        uint256 confirmations;
    }

    mapping(uint256 => Transaction) public transactions;
    mapping(uint256 => mapping(address => bool)) public confirmedBy;
    uint256 public txCount;

    modifier onlyOwner() {
        require(isOwner[msg.sender], "not owner");
        _;
    }
    modifier txExists(uint256 _txId) {
        require(_txId < txCount, "txId out of range");
        _;
    }
    modifier notExecuted(uint256 _txId) {
        require(!transactions[_txId].executed, "already executed");
        _;
    }
    modifier notConfirmed(uint256 _txId) {
        require(!confirmedBy[_txId][msg.sender], "already confirmed");
        _;
    }

    constructor(address[3] memory _owners) {
        for (uint256 i; i < 3; ++i) {
            address o = _owners[i];
            require(o != address(0), "zero addr");
            owners[i] = o;
            isOwner[o] = true;
        }
    }

    function submit(
        address _destination,
        uint256 _value,
        bytes calldata _data
    ) external onlyOwner nonReentrant returns (uint256 txId) {
        txId = txCount++;
        transactions[txId] = Transaction({
            destination: _destination,
            value: _value,
            data: _data,
            executed: false,
            confirmations: 0
        });
        emit Submit(txId, _destination, _value, _data);
        confirm(txId);
    }

    function confirm(
        uint256 _txId
    )
        public
        onlyOwner
        nonReentrant
        txExists(_txId)
        notExecuted(_txId)
        notConfirmed(_txId)
    {
        confirmedBy[_txId][msg.sender] = true;
        uint256 cnt = ++transactions[_txId].confirmations;
        emit Confirm(msg.sender, _txId);
        if (cnt >= REQUIRED) _execute(_txId);
    }

    function _execute(
        uint256 _txId
    ) internal txExists(_txId) notExecuted(_txId) {
        Transaction storage txn = transactions[_txId];
        txn.executed = true;
        (bool ok, ) = txn.destination.call{value: txn.value}(txn.data);
        require(ok, "exec failed");
        emit Execute(_txId);
    }

    receive() external payable {}
}
