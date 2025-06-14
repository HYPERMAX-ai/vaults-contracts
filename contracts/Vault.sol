// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Multicall} from "./base/SelfMulticall.sol";

// Interface for on-chain reads of spot, perp and buffer balances
abstract contract Reader {
    address constant POSITION_PRECOMPILE_ADDRESS =
        0x0000000000000000000000000000000000000800;
    address constant SPOT_BALANCE_PRECOMPILE_ADDRESS =
        0x0000000000000000000000000000000000000801;

    struct Position {
        int64 szi;
        uint64 entryNtl;
        int64 isolatedRawUsd;
        uint32 leverage;
        bool isIsolated;
    }

    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    function _position(
        address user,
        uint16 perp
    ) external view returns (Position memory) {
        bool success;
        bytes memory result;
        (success, result) = POSITION_PRECOMPILE_ADDRESS.staticcall(
            abi.encode(user, perp)
        );
        require(success, "Position precompile call failed");
        return abi.decode(result, (Position));
    }

    function _spotBalance(
        address user,
        uint64 token
    ) internal view returns (SpotBalance memory) {
        bool success;
        bytes memory result;
        (success, result) = SPOT_BALANCE_PRECOMPILE_ADDRESS.staticcall(
            abi.encode(user, token)
        );
        require(success, "SpotBalance precompile call failed");
        return abi.decode(result, (SpotBalance));
    }
}

// Gateway to forward orders to Hyperliquid
abstract contract Writer {
    // TODO
    function _execute(bytes calldata payload) internal {}
}

contract HyperBondVault is
    Reader,
    Writer,
    ERC4626,
    Ownable,
    Pausable,
    ReentrancyGuard,
    Multicall
{
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint8 internal immutable decimalsOffset;

    address internal constant bridge =
        0x2222222222222222222222222222222222222222;

    // Fee
    uint256 public mgmtFeePpm; // parts per million (1e6) per year
    uint256 public lastFeeAccrual;
    address public feeReceiver;

    // spread
    uint256 public spreadBps; // 0-1000 (±10%), base: 10000

    // TODO: Risk knobs
    bool oracleStale = true;
    uint256 public maxLeverage;
    uint256 public minUsdcBufferBps;
    mapping(uint256 => bool) public allowedMarkets;

    // TODO
    event NeedCoreFunds(address indexed ap, uint256 assets);

    modifier withinRisk() {
        // TODO
        _;
    }

    constructor(
        IERC20 _asset,
        uint8 _decimals,
        string memory _name,
        string memory _symbol,
        address _feeReceiver
    ) ERC4626(_asset) ERC20(_name, _symbol) Ownable(msg.sender) {
        feeReceiver = _feeReceiver;
        lastFeeAccrual = block.timestamp;

        decimalsOffset = 18 - _decimals;

        _mint(address(this), 1); // to avoid zero-supply edge-case
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return decimalsOffset;
    }

    // ----------------------------
    // NAV & Oracle
    // ----------------------------

    function _valueSnapshot()
        internal
        view
        returns (uint256 spot, uint256 perp, uint256 buffer)
    {
        // TODO

        buffer = IERC20(asset()).balanceOf(address(this));
    }

    function _sharePriceX18() internal view returns (uint256 px) {
        (uint256 spot, uint256 perp, uint256 buf) = _valueSnapshot();
        uint256 nav = spot + perp + buf;
        require(nav > 0, "NAV zero");
        px = (nav * 1e18) / totalSupply();
    }

    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding
    ) internal view override returns (uint256) {
        uint256 px = _sharePriceX18();
        uint256 adj = (px * (10000 + spreadBps)) / 10000;
        return assets.mulDiv(1e18, adj, rounding);
    }

    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view override returns (uint256) {
        uint256 px = _sharePriceX18();
        uint256 adj = (px * (10000 - spreadBps)) / 10000;
        return shares.mulDiv(adj, 1e18, rounding);
    }

    // ----------------------------
    // Trader Execution & Risk
    // ----------------------------
    function placeOrder(
        bytes calldata payload
    ) external onlyOwner whenNotPaused nonReentrant {
        _accrueFees();

        _execute(payload); // TODO
    }

    // ----------------------------
    // Fee
    // ----------------------------

    function accrueFees() public {
        _accrueFees();
    }

    function _accrueFees() internal {
        uint256 ts = block.timestamp;
        uint256 dt = ts - lastFeeAccrual;
        if (dt == 0 || mgmtFeePpm == 0) {
            lastFeeAccrual = ts;
            return;
        }
        uint256 fee = (totalSupply() * mgmtFeePpm * dt) / (1e6 * 365 days);
        if (fee > 0) _mint(feeReceiver, fee);
        lastFeeAccrual = ts;
    }

    // ----------------------------
    // Admin controls
    // ----------------------------

    function setSpread(uint256 bps) external onlyOwner {
        require(bps <= 1000, "too high");
        spreadBps = bps;
    }

    function setMgmtFee(uint256 ppm) external onlyOwner {
        mgmtFeePpm = ppm;
    }

    function setFeeReceiver(address recv) external onlyOwner {
        feeReceiver = recv;
    }

    function freeze() external onlyOwner {
        _pause();
    }

    function unfreeze() external onlyOwner {
        _unpause();
    }
}
