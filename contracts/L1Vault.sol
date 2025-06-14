// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Multicall} from "./base/SelfMulticall.sol";

abstract contract Reader {
    address constant VAULT_EQUITY_PRECOMPILE_ADDRESS =
        0x0000000000000000000000000000000000000802;

    struct UserVaultEquity {
        uint64 equity;
        uint64 lockedUntilTimestamp;
    }

    function _userVaultEquity(
        address user,
        address vault
    ) internal view returns (UserVaultEquity memory) {
        bool success;
        bytes memory result;
        (success, result) = VAULT_EQUITY_PRECOMPILE_ADDRESS.staticcall(
            abi.encode(user, vault)
        );
        require(success, "VaultEquity precompile call failed");
        return abi.decode(result, (UserVaultEquity));
    }
}

interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

abstract contract Writer {
    ICoreWriter public constant coreWriter =
        ICoreWriter(0x3333333333333333333333333333333333333333);

    function _encode(
        uint24 actionId,
        bytes memory payload
    ) internal pure returns (bytes memory) {
        bytes1 version = bytes1(uint8(1));
        bytes3 aid = bytes3(actionId);
        return abi.encodePacked(version, aid, payload);
    }

    function _sendUsdClassTransfer(uint64 ntl, bool toPerp) internal {
        bytes memory payload = abi.encode(ntl, toPerp);
        coreWriter.sendRawAction(_encode(7, payload));
    }

    function _sendVaultTransfer(
        address vault,
        bool isDeposit,
        uint64 usd
    ) internal {
        bytes memory payload = abi.encode(vault, isDeposit, usd);
        coreWriter.sendRawAction(_encode(2, payload));
    }

    function _sendSpot(
        address destination,
        uint64 token,
        uint64 _wei
    ) internal {
        bytes memory payload = abi.encode(destination, token, _wei);
        coreWriter.sendRawAction(_encode(6, payload));
    }
}

contract L1Vault is
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

    address public immutable l1Vault;

    address internal constant bridge =
        0x2000000000000000000000000000000000000000; // USDC
    // 0x2222222222222222222222222222222222222222;  // HYPE

    uint256 public immutable minDeposit;

    // pending
    uint256 private constant VAULT_TIMELOCK = 60; // blocks // testnet // TODO: mainnet
    uint256 public vaultTimelock;
    uint256 public bridgePendings;
    mapping(address account => uint256 amount) public pendings;
    uint256 public totalPendings;

    // Fee
    uint256 public mgmtFeePpm; // parts per million (1e6) per year
    uint256 public lastFeeAccrual;
    address public feeReceiver;

    // spread
    uint256 public spreadBps; // 0-1000 (±10%), base: 10000

    event Finalize(address indexed account, uint256 amount);

    constructor(
        // IERC20 _asset,
        // string memory _name,
        // string memory _symbol,
        address _feeReceiver,
        address _l1Vault,
        uint256 _minDeposit
    )
        ERC4626(IERC20(0xd9CBEC81df392A88AEff575E962d149d57F4d6bc)) // USDC
        ERC20("HlpVault", "maxHlpVault")
        Ownable(msg.sender)
    {
        feeReceiver = _feeReceiver;
        lastFeeAccrual = block.timestamp;

        l1Vault = _l1Vault;
        minDeposit = _minDeposit;

        _mint(address(this), 1); // to avoid zero-supply edge-case
    }

    receive() external payable {}

    // ----------------------------
    // NAV & Oracle
    // ----------------------------

    function _valueSnapshot()
        internal
        view
        returns (uint256 vault, uint256 buffer)
    {
        vault = ((uint256(_userVaultEquity(address(this), l1Vault).equity) *
            10 ** decimals()) / (10 ** 6));
        buffer = IERC20(asset()).balanceOf(address(this));
    }

    function _sharePriceX18() internal view returns (uint256 px) {
        (uint256 vault, uint256 buf) = _valueSnapshot();
        uint256 nav = vault + buf - totalPendings + 1; // to avoid zero-asset edge-case
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

    function _l1Deposit(uint256 assets) internal {
        require(assets >= minDeposit, "deposit minimum.");

        uint64 l1Assets = uint64((assets * 10 ** 6) / 10 ** decimals());
        // bridging
        {
            IERC20(asset()).transfer(bridge, assets);
        }
        // spot -> perp
        {
            _sendUsdClassTransfer(l1Assets, true);
        }
        // vault
        {
            _sendVaultTransfer(l1Vault, true, l1Assets);
        }
    }

    function deposit(
        uint256 assets,
        address receiver
    ) public override whenNotPaused nonReentrant returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        _l1Deposit(assets);
        return shares;
    }

    function mint(
        uint256 shares,
        address receiver
    ) public override whenNotPaused nonReentrant returns (uint256) {
        uint256 assets = super.mint(shares, receiver);
        _l1Deposit(assets);
        return assets;
    }

    /**
     * @dev Withdraw/redeem common workflow.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        _burn(owner, shares);

        // SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        pendings[receiver] += assets;
        totalPendings += assets;

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function _l1Withdraw(uint256 assets) internal {
        // timestamp check (millsec -> sec (/1000))
        require(
            block.timestamp >=
                uint256(
                    _userVaultEquity(address(this), l1Vault)
                        .lockedUntilTimestamp
                ) /
                    1000 +
                    1,
            "not yet."
        );

        uint64 l1Assets = uint64((assets * 10 ** 6) / 10 ** decimals());
        // vault
        {
            _sendVaultTransfer(l1Vault, false, l1Assets);
        }

        vaultTimelock = block.number;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override whenNotPaused nonReentrant returns (uint256) {
        uint256 shares = super.withdraw(assets, receiver, owner);
        _l1Withdraw(assets);
        bridgePendings += assets;
        return shares;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override whenNotPaused nonReentrant returns (uint256) {
        uint256 assets = super.withdraw(shares, receiver, owner);
        _l1Withdraw(assets);
        bridgePendings += assets;
        return assets;
    }

    function withdrawBridge() external {
        // vault withdraw pending time
        require(block.number >= vaultTimelock + VAULT_TIMELOCK, "not yet.");

        // perp -> spot
        {
            _sendUsdClassTransfer(
                uint64((bridgePendings * 10 ** 6) / 10 ** decimals()),
                false
            );
        }
        // bridging
        {
            _sendSpot(bridge, /* tokenSpotIdx */ 0, uint64(bridgePendings));
        }

        bridgePendings = 0;
    }

    function finalize(
        address account
    ) external payable whenNotPaused nonReentrant returns (uint256 amount) {
        amount = pendings[account];
        // delete pendings[account];
        pendings[account] = 0;
        totalPendings -= amount;

        SafeERC20.safeTransfer(IERC20(asset()), account, amount);

        emit Finalize(account, amount);
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

    function freeze() external onlyOwner {
        _pause();
    }

    function unfreeze() external onlyOwner {
        _unpause();
    }

    function bufWithdraw(address account, uint256 amount) external onlyOwner {
        SafeERC20.safeTransfer(IERC20(asset()), account, amount);
    }
}
