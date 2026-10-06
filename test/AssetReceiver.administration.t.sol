// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReceiverTestBase} from "./helpers/ReceiverTestBase.sol";
import {MockToken} from "./helpers/MockToken.sol";
import {AssetReceiver} from "src/AssetReceiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract AssetReceiverAdministrationTest is ReceiverTestBase {
    function testOverwrittenNomineeAndFormerOwnerCannotTakeControl() public {
        _depositETH(1 ether);
        vm.startPrank(OWNER);
        vm.expectRevert(AssetReceiver.InvalidAddress.selector);
        receiver.transferOwnership(address(receiver));
        receiver.transferOwnership(OUTSIDER);
        receiver.transferOwnership(DONOR);
        vm.stopPrank();
        vm.prank(OUTSIDER);
        vm.expectRevert(AssetReceiver.Unauthorized.selector);
        receiver.acceptOwnership();
        assertEq(receiver.owner(), OWNER);
        assertEq(receiver.pendingOwner(), DONOR);
        vm.prank(DONOR);
        receiver.acceptOwnership();
        assertEq(receiver.owner(), DONOR);
        assertEq(receiver.pendingOwner(), address(0));
        vm.prank(DONOR);
        vm.expectRevert(AssetReceiver.Unauthorized.selector);
        receiver.acceptOwnership();

        vm.prank(DONOR);
        receiver.pause();
        AssetReceiver next = new AssetReceiver(DONOR, address(receiver));
        vm.startPrank(OWNER);
        vm.expectRevert(AssetReceiver.Unauthorized.selector);
        receiver.unpause();
        vm.expectRevert(AssetReceiver.Unauthorized.selector);
        receiver.upgradeTo(address(next));
        vm.expectRevert(AssetReceiver.Unauthorized.selector);
        receiver.transferOwnership(OWNER);
        vm.stopPrank();
        vm.prank(DONOR);
        receiver.upgradeTo(address(next));
        vm.prank(DONOR);
        vm.expectRevert(AssetReceiver.Unauthorized.selector);
        receiver.withdrawAll(address(0));
        vm.prank(BENEFICIARY);
        receiver.withdrawAll(address(0));
        assertEq(BENEFICIARY.balance, 1 ether);
        assertEq(next.owner(), DONOR);
    }

    function testOwnershipChangeInvalidatesCandidateUntilOwnersAgree() public {
        _deposit(USDC, 100e6);
        _pause();
        AssetReceiver next = new AssetReceiver(OWNER, address(receiver));
        vm.prank(OWNER);
        receiver.transferOwnership(DONOR);
        vm.prank(DONOR);
        receiver.acceptOwnership();
        vm.prank(DONOR);
        vm.expectRevert(AssetReceiver.InvalidReplacement.selector);
        receiver.upgradeTo(address(next));
        assertEq(receiver.successor(), address(0));
        assertEq(receiver.totalAcceptedUsd(), 100e18);
        assertEq(MockToken(USDC).balanceOf(address(receiver)), 100e6);

        vm.prank(OWNER);
        next.transferOwnership(DONOR);
        vm.prank(DONOR);
        next.acceptOwnership();
        vm.prank(DONOR);
        receiver.upgradeTo(address(next));
        vm.prank(DONOR);
        next.depositETH{value: 1}();
        assertEq(next.totalAcceptedUsd(), 100e18 + 2600);
    }

    function testCompetingCandidateStaysInactiveAfterSelectedLineageAdvances() public {
        _depositETH(1 ether);
        _pause();
        AssetReceiver loser = new AssetReceiver(OWNER, address(receiver));
        AssetReceiver winner = new AssetReceiver(OWNER, address(receiver));
        vm.prank(OWNER);
        receiver.upgradeTo(address(winner));
        vm.prank(OWNER);
        winner.pause();
        AssetReceiver latest = new AssetReceiver(OWNER, address(winner));
        vm.prank(OWNER);
        winner.upgradeTo(address(latest));

        vm.prank(DONOR);
        vm.expectRevert(AssetReceiver.NotActivated.selector);
        loser.depositETH{value: 1}();
        vm.prank(OWNER);
        receiver.transferOwnership(DONOR);
        vm.prank(DONOR);
        receiver.acceptOwnership();
        vm.prank(DONOR);
        vm.expectRevert(AssetReceiver.Retired.selector);
        receiver.upgradeTo(address(loser));
        vm.prank(DONOR);
        vm.expectRevert(AssetReceiver.Retired.selector);
        receiver.unpause();
        assertEq(receiver.successor(), address(winner));
        assertEq(winner.successor(), address(latest));
        assertEq(latest.totalAcceptedUsd(), 2600e18);
        assertEq(address(receiver).balance, 1 ether);
    }

    function testRepeatedPauseAndUnpauseDoNotAlterCustodyOrAccounting() public {
        _depositETH(1);
        vm.startPrank(OWNER);
        vm.expectRevert(AssetReceiver.NotPaused.selector);
        receiver.unpause();
        receiver.pause();
        vm.expectRevert(AssetReceiver.DepositsPaused.selector);
        receiver.pause();
        receiver.unpause();
        vm.expectRevert(AssetReceiver.NotPaused.selector);
        receiver.unpause();
        vm.stopPrank();
        assertEq(address(receiver).balance, 1);
        assertEq(receiver.totalAcceptedUsd(), 2600);
        assertFalse(receiver.paused());
        _depositETH(1);
        assertEq(receiver.totalAcceptedUsd(), 5200);
    }

    function testAuthorizedTokenCallbackCannotChangeAdministrationDuringTransfers() public {
        // Make the callback caller the legitimate owner so only the reentrancy
        // guard, rather than a role mismatch, can stop these nested calls.
        receiver = new AssetReceiver(USDC, address(0));
        bytes[3] memory callbacks = [
            abi.encodeCall(AssetReceiver.pause, ()),
            abi.encodeCall(AssetReceiver.transferOwnership, (OUTSIDER)),
            abi.encodeCall(AssetReceiver.acceptOwnership, ())
        ];
        vm.prank(USDC);
        receiver.transferOwnership(USDC);
        for (uint256 i; i < callbacks.length; ++i) {
            MockToken(USDC).setCallback(address(receiver), callbacks[i], 0);
            _deposit(USDC, 1e6);
            assertFalse(MockToken(USDC).callbackSucceeded());
            assertEq(MockToken(USDC).callbackError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            vm.prank(BENEFICIARY);
            receiver.withdrawAll(USDC);
            assertFalse(MockToken(USDC).callbackSucceeded());
            assertEq(MockToken(USDC).callbackError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            assertEq(receiver.owner(), USDC);
            assertEq(receiver.pendingOwner(), USDC);
            assertFalse(receiver.paused());
            assertEq(receiver.totalAcceptedUsd(), (i + 1) * 1e18);
            assertEq(MockToken(USDC).balanceOf(BENEFICIARY), (i + 1) * 1e6);
        }
    }
}
