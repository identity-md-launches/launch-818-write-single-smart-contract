// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AssetReceiver} from "../../src/AssetReceiver.sol";
import {MockToken} from "./MockToken.sol";

abstract contract ReceiverTestBase is Test {
    AssetReceiver internal receiver;
    address internal constant OWNER = address(0xA11CE);
    address internal constant DONOR = address(0xB0B);
    address internal constant OUTSIDER = address(0xBAD);
    address internal constant BENEFICIARY = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    uint256 internal constant CAP = 10_000e18;

    function setUp() public virtual {
        vm.chainId(1);
        vm.etch(USDT, address(new MockToken(6)).code);
        vm.etch(USDC, address(new MockToken(6)).code);
        vm.etch(IMD, address(new MockToken(18)).code);
        MockToken(USDT).configure(MockToken.ReturnMode.Empty, 0, false);
        receiver = new AssetReceiver(OWNER, address(0));
        vm.deal(DONOR, 100 ether);
        vm.deal(BENEFICIARY, 0);
    }

    function _deposit(address asset, uint256 amount) internal {
        MockToken(asset).mint(DONOR, amount);
        vm.startPrank(DONOR);
        MockToken(asset).approve(address(receiver), amount);
        receiver.depositToken(asset, amount);
        vm.stopPrank();
    }

    function _depositETH(uint256 amount) internal {
        vm.prank(DONOR);
        receiver.depositETH{value: amount}();
    }

    function _pause() internal {
        vm.prank(OWNER);
        receiver.pause();
    }
}
