// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AssetReceiver
/// @notice Mainnet collection of at most $10,000 in lifetime deposits, at fixed prices.
/// @dev Upgrades retire this address in favor of a replacement; they never execute replacement code here.
contract AssetReceiver is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant WITHDRAWER = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 public constant CAP_USD = 10_000e18;
    uint256 public constant ETH_PRICE_USD = 2600;
    uint256 public constant IMD_PRICE_USD = 9;

    address public owner;
    address public pendingOwner;
    bool public paused;
    address public successor;
    address public immutable predecessor;
    /// @notice Lifetime accepted value in USD with 18 decimals, including predecessor deposits.
    uint256 public totalAcceptedUsd;

    error Unauthorized();
    error InvalidAddress();
    error ZeroAmount();
    error UnsupportedAsset();
    error DepositsPaused();
    error NotPaused();
    error Retired();
    error NotActivated();
    error InvalidReplacement();
    error CapExceeded();
    error NoTokensReceived();
    error InsufficientBalance();
    error EthTransferFailed();

    event Deposited(address indexed sender, address indexed asset, uint256 amount, uint256 usdValue);
    event Withdrawn(address indexed asset, uint256 amount);
    event PauseChanged(bool paused);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Upgraded(address indexed replacement, uint256 carriedAcceptedUsd);

    /// @param initialOwner Explicit administrator; the deploying factory receives no privileges.
    /// @param previousReceiver Zero for the first deployment, otherwise the paused receiver being replaced.
    constructor(address initialOwner, address previousReceiver) {
        if (initialOwner == address(0) || initialOwner == address(this)) revert InvalidAddress();
        owner = initialOwner;
        predecessor = previousReceiver;
        if (previousReceiver != address(0)) {
            if (previousReceiver.code.length == 0) revert InvalidReplacement();
            AssetReceiver previous = AssetReceiver(payable(previousReceiver));
            if (
                !previous.paused() || previous.successor() != address(0) || previous.owner() != initialOwner
                    || previous.WITHDRAWER() != WITHDRAWER
            ) revert InvalidReplacement();
            uint256 accepted = previous.totalAcceptedUsd();
            if (accepted > CAP_USD) revert InvalidReplacement();
            totalAcceptedUsd = accepted;
        }
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyWithdrawer() {
        if (msg.sender != WITHDRAWER) revert Unauthorized();
        _;
    }

    /// @notice Plain ETH transfers obey the same pause and cap checks as depositETH.
    receive() external payable nonReentrant {
        _depositETH();
    }

    function depositETH() external payable nonReentrant {
        _depositETH();
    }

    /// @notice Approve this contract first. Only the caller's tokens can be pulled.
    /// @dev The cap uses the actual balance increase, including for a token that charges transfer fees.
    function depositToken(address asset, uint256 amount) external nonReentrant {
        _requireActive();
        if (amount == 0) revert ZeroAmount();
        uint256 unitValue = _tokenUnitValue(asset);
        IERC20 token = IERC20(asset);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance <= beforeBalance) revert NoTokensReceived();
        uint256 received = afterBalance - beforeBalance;
        uint256 value = _account(received, unitValue);
        emit Deposited(msg.sender, asset, received, value);
    }

    /// @notice Withdraw any positive amount, even while paused or retired. ETH is address(0).
    /// @dev Only WITHDRAWER can call, and every payout goes to WITHDRAWER. ERC20 recovery is also allowed.
    function withdraw(address asset, uint256 amount) external onlyWithdrawer nonReentrant {
        _withdraw(asset, amount);
    }

    /// @notice Withdraw the full current balance of one asset, including unsolicited transfers.
    function withdrawAll(address asset) external onlyWithdrawer nonReentrant {
        uint256 amount = asset == address(0) ? address(this).balance : IERC20(asset).balanceOf(address(this));
        _withdraw(asset, amount);
    }

    function pause() external onlyOwner nonReentrant {
        if (paused) revert DepositsPaused();
        paused = true;
        emit PauseChanged(true);
    }

    function unpause() external onlyOwner nonReentrant {
        if (successor != address(0)) revert Retired();
        if (!paused) revert NotPaused();
        paused = false;
        emit PauseChanged(false);
    }

    function transferOwnership(address newOwner) external onlyOwner nonReentrant {
        if (newOwner == address(0) || newOwner == address(this)) revert InvalidAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external nonReentrant {
        if (msg.sender != pendingOwner) revert Unauthorized();
        address previousOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, msg.sender);
    }

    /// @notice Permanently retire deposits here and activate a reviewed replacement at a new address.
    /// @dev Pause, deploy a replacement with this address as predecessor, then call this function.
    ///      The carried cap must match. Funds stay here and only WITHDRAWER can withdraw them.
    ///      Getter compatibility is a sanity check, not proof of the replacement's behavior.
    function upgradeTo(address replacement) external onlyOwner nonReentrant {
        if (successor != address(0)) revert Retired();
        if (!paused) revert NotPaused();
        _requireActivated();
        if (replacement == address(this) || replacement.code.length == 0) revert InvalidReplacement();
        AssetReceiver next = AssetReceiver(payable(replacement));
        if (
            next.predecessor() != address(this) || next.owner() != owner || next.WITHDRAWER() != WITHDRAWER
                || next.CAP_USD() != CAP_USD || next.totalAcceptedUsd() != totalAcceptedUsd
                || next.successor() != address(0)
        ) revert InvalidReplacement();
        successor = replacement;
        emit Upgraded(replacement, totalAcceptedUsd);
    }

    function remainingCapacityUsd() external view returns (uint256) {
        return CAP_USD - totalAcceptedUsd;
    }

    function _requireActive() private view {
        if (successor != address(0)) revert Retired();
        if (paused) revert DepositsPaused();
        _requireActivated();
    }

    function _requireActivated() private view {
        if (predecessor != address(0) && AssetReceiver(payable(predecessor)).successor() != address(this)) {
            revert NotActivated();
        }
    }

    function _depositETH() private {
        _requireActive();
        if (msg.value == 0) revert ZeroAmount();
        uint256 value = _account(msg.value, ETH_PRICE_USD);
        emit Deposited(msg.sender, address(0), msg.value, value);
    }

    function _account(uint256 amount, uint256 unitValue) private returns (uint256 value) {
        // Compare before multiplying: no overflow and no lost sub-dollar dust.
        if (amount > (CAP_USD - totalAcceptedUsd) / unitValue) revert CapExceeded();
        value = amount * unitValue;
        totalAcceptedUsd += value;
    }

    function _tokenUnitValue(address asset) private pure returns (uint256) {
        if (asset == USDT || asset == USDC) return 1e12; // $1, six token decimals -> USD with 18 decimals.
        if (asset == IMD) return IMD_PRICE_USD; // $9, eighteen token decimals.
        revert UnsupportedAsset();
    }

    function _withdraw(address asset, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        // Withdrawals deliberately do not reduce lifetime accepted value.
        if (asset == address(0)) {
            if (amount > address(this).balance) revert InsufficientBalance();
            (bool success,) = payable(WITHDRAWER).call{value: amount}("");
            if (!success) revert EthTransferFailed();
        } else {
            IERC20 token = IERC20(asset);
            if (amount > token.balanceOf(address(this))) revert InsufficientBalance();
            token.safeTransfer(WITHDRAWER, amount);
        }
        emit Withdrawn(asset, amount);
    }
}
