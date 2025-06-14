// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Timelock is Ownable, ReentrancyGuard {
    event Queued(
        bytes32 indexed txHash,
        address target,
        uint256 value,
        bytes data,
        uint256 eta
    );
    event Executed(
        bytes32 indexed txHash,
        address target,
        uint256 value,
        bytes data
    );
    event Cancelled(bytes32 indexed txHash);

    uint256 public delay;
    mapping(bytes32 => bool) public queued;

    constructor(uint256 _delay) Ownable(msg.sender) {
        delay = _delay;
    }

    function queue(
        address _target,
        uint256 _value,
        bytes calldata _data
    ) external onlyOwner returns (bytes32 txHash) {
        uint256 eta = block.timestamp + delay;
        txHash = keccak256(abi.encode(_target, _value, _data, eta));
        queued[txHash] = true;
        emit Queued(txHash, _target, _value, _data, eta);
    }

    function cancel(bytes32 _txHash) external onlyOwner {
        require(queued[_txHash], "not queued");
        queued[_txHash] = false;
        emit Cancelled(_txHash);
    }

    function execute(
        address _target,
        uint256 _value,
        bytes calldata _data,
        uint256 _eta
    ) external payable onlyOwner returns (bytes memory) {
        bytes32 txHash = keccak256(abi.encode(_target, _value, _data, _eta));
        require(queued[txHash], "tx not queued");
        require(block.timestamp >= _eta, "eta not reached");
        queued[txHash] = false;
        (bool ok, bytes memory res) = _target.call{value: _value}(_data);
        require(ok, "exec failed");
        emit Executed(txHash, _target, _value, _data);
        return res;
    }
}
