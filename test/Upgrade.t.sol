// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReceiverTestBase} from "./helpers/ReceiverTestBase.sol";
import {AssetReceiver} from "../src/AssetReceiver.sol";
import {MockToken} from "./helpers/MockToken.sol";

contract UpgradeTest is ReceiverTestBase {
    function testReplacementCarriesCapAndLeavesExistingFundsWithdrawable() public {
        _depositETH(1 ether);
        _deposit(USDC, 1000e6);
        _pause();
        AssetReceiver next = new AssetReceiver(OWNER, address(receiver));
        assertEq(next.totalAcceptedUsd(), 3600e18);
        vm.expectRevert(AssetReceiver.NotActivated.selector);
        next.depositETH{value: 1}();
        vm.expectRevert(AssetReceiver.NotActivated.selector);
        next.depositToken(USDC, 1);
        (bool success,) = address(next).call{value: 1}("");
        assertFalse(success);

        vm.prank(OWNER);
        receiver.upgradeTo(address(next));
        assertEq(receiver.successor(), address(next));
        assertEq(address(receiver).balance, 1 ether);
        assertEq(address(next).balance, 0);
        assertEq(MockToken(USDC).balanceOf(address(receiver)), 1000e6);

        vm.expectRevert(AssetReceiver.Retired.selector);
        receiver.depositETH{value: 1}();
        vm.expectRevert(AssetReceiver.Retired.selector);
        receiver.depositToken(USDC, 1);
        (success,) = address(receiver).call{value: 1}("");
        assertFalse(success);
        vm.startPrank(OWNER);
        vm.expectRevert(AssetReceiver.Retired.selector);
        receiver.unpause();
        vm.expectRevert(AssetReceiver.Retired.selector);
        receiver.upgradeTo(address(next));
        vm.stopPrank();

        MockToken(USDC).mint(DONOR, 6400e6);
        vm.startPrank(DONOR);
        MockToken(USDC).approve(address(next), 6400e6);
        next.depositToken(USDC, 6400e6);
        vm.stopPrank();
        assertEq(next.totalAcceptedUsd(), CAP);
        vm.expectRevert(AssetReceiver.CapExceeded.selector);
        next.depositETH{value: 1}();

        vm.startPrank(BENEFICIARY);
        receiver.withdraw(address(0), 0.5 ether);
        receiver.withdrawAll(address(0));
        receiver.withdrawAll(USDC);
        next.withdrawAll(USDC);
        vm.stopPrank();
        assertEq(BENEFICIARY.balance, 1 ether);
        assertEq(MockToken(USDC).balanceOf(BENEFICIARY), 7400e6);
        assertEq(next.totalAcceptedUsd(), CAP);
    }

    function testReplacementRequiresPauseAndValidPredecessor() public {
        vm.expectRevert(AssetReceiver.InvalidReplacement.selector);
        new AssetReceiver(OWNER, OUTSIDER);
        vm.expectRevert(AssetReceiver.InvalidReplacement.selector);
        new AssetReceiver(OWNER, address(receiver));
        vm.prank(OWNER);
        vm.expectRevert(AssetReceiver.NotPaused.selector);
        receiver.upgradeTo(OUTSIDER);
        _pause();
        vm.expectRevert(AssetReceiver.InvalidReplacement.selector);
        new AssetReceiver(OUTSIDER, address(receiver));

        vm.startPrank(OWNER);
        vm.expectRevert(AssetReceiver.InvalidReplacement.selector);
        receiver.upgradeTo(address(0));
        vm.expectRevert(AssetReceiver.InvalidReplacement.selector);
        receiver.upgradeTo(OUTSIDER);
        vm.expectRevert(AssetReceiver.InvalidReplacement.selector);
        receiver.upgradeTo(address(receiver));
        vm.stopPrank();
    }

    function testWrongLineageAndChangedOwnerRejected() public {
        _pause();
        AssetReceiver unrelated = new AssetReceiver(OWNER, address(0));
        vm.prank(OWNER);
        vm.expectRevert(AssetReceiver.InvalidReplacement.selector);
        receiver.upgradeTo(address(unrelated));
        AssetReceiver next = new AssetReceiver(OWNER, address(receiver));
        vm.prank(OWNER);
        next.transferOwnership(OUTSIDER);
        vm.prank(OUTSIDER);
        next.acceptOwnership();
        vm.prank(OWNER);
        vm.expectRevert(AssetReceiver.InvalidReplacement.selector);
        receiver.upgradeTo(address(next));
        assertEq(receiver.successor(), address(0));
    }

    function testStaleCandidateRejectedAfterMoreDeposits() public {
        _pause();
        AssetReceiver stale = new AssetReceiver(OWNER, address(receiver));
        vm.prank(OWNER);
        receiver.unpause();
        _depositETH(1 ether);
        _pause();
        vm.prank(OWNER);
        vm.expectRevert(AssetReceiver.InvalidReplacement.selector);
        receiver.upgradeTo(address(stale));
        AssetReceiver fresh = new AssetReceiver(OWNER, address(receiver));
        vm.prank(OWNER);
        receiver.upgradeTo(address(fresh));
        vm.expectRevert(AssetReceiver.NotActivated.selector);
        stale.depositETH{value: 1}();
        assertEq(fresh.totalAcceptedUsd(), 2600e18);
    }

    function testPendingReplacementCannotActivateItsOwnSuccessor() public {
        _pause();
        AssetReceiver pending = new AssetReceiver(OWNER, address(receiver));
        vm.prank(OWNER);
        pending.pause();
        AssetReceiver premature = new AssetReceiver(OWNER, address(pending));
        vm.prank(OWNER);
        vm.expectRevert(AssetReceiver.NotActivated.selector);
        pending.upgradeTo(address(premature));
        vm.expectRevert(AssetReceiver.NotActivated.selector);
        premature.depositETH{value: 1}();
        vm.prank(OWNER);
        receiver.upgradeTo(address(pending));
        vm.prank(OWNER);
        pending.upgradeTo(address(premature));
        premature.depositETH{value: 1}();
        assertEq(premature.totalAcceptedUsd(), 2600);
    }

    function testSecondUpgradeCarriesAllHistoricalDeposits() public {
        _deposit(USDT, 1000e6);
        _pause();
        AssetReceiver second = new AssetReceiver(OWNER, address(receiver));
        vm.prank(OWNER);
        receiver.upgradeTo(address(second));
        second.depositETH{value: 1 ether}();
        vm.prank(OWNER);
        second.pause();
        AssetReceiver third = new AssetReceiver(OWNER, address(second));
        vm.prank(OWNER);
        second.upgradeTo(address(third));
        assertEq(third.totalAcceptedUsd(), 3600e18);
        assertEq(third.remainingCapacityUsd(), 6400e18);
        vm.expectRevert(AssetReceiver.InvalidReplacement.selector);
        new AssetReceiver(OWNER, address(receiver));
    }
}
