// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Local ERC20 double, installed at the three mainnet addresses using vm.etch.
contract MockToken {
    enum ReturnMode {
        Normal,
        Empty,
        False,
        Revert,
        Malformed
    }

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public immutable decimals;
    ReturnMode public returnMode;
    uint256 public feeBps;
    bool public noMovement;
    address public callbackTarget;
    bytes public callbackData;
    uint256 public callbackValue;
    bool public callbackSucceeded;
    bytes4 public callbackError;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function configure(ReturnMode mode, uint256 fee, bool skipMovement) external {
        returnMode = mode;
        feeBps = fee;
        noMovement = skipMovement;
    }

    function setCallback(address target, bytes calldata data, uint256 value) external {
        callbackTarget = target;
        callbackData = data;
        callbackValue = value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return _respond();
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return _respond();
    }

    function _move(address from, address to, uint256 amount) private {
        if (!noMovement) {
            require(balanceOf[from] >= amount, "balance");
            balanceOf[from] -= amount;
            balanceOf[to] += amount - amount * feeBps / 10_000;
        }
        if (callbackTarget != address(0)) {
            bytes memory result;
            (callbackSucceeded, result) = callbackTarget.call{value: callbackValue}(callbackData);
            if (result.length >= 4) callbackError = bytes4(result);
        }
    }

    function _respond() private view returns (bool) {
        if (returnMode == ReturnMode.Empty) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (returnMode == ReturnMode.Malformed) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (returnMode == ReturnMode.Revert) revert("token unavailable");
        return returnMode != ReturnMode.False;
    }
}
