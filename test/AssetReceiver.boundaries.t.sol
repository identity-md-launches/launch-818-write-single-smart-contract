// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReceiverTestBase} from "./helpers/ReceiverTestBase.sol";
import {MockToken} from "./helpers/MockToken.sol";
import {AssetReceiver} from "src/AssetReceiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract AssetReceiverBoundaryTest is ReceiverTestBase {
    event Deposited(address indexed sender, address indexed asset, uint256 amount, uint256 usdValue);
    event Withdrawn(address indexed asset, uint256 amount);

    function _asset(uint256 index) internal pure returns (address) {
        return index == 0 ? address(0) : index == 1 ? USDT : index == 2 ? USDC : IMD;
    }

    function _unit(uint256 index) internal pure returns (uint256) {
        return index == 0 ? 2600 : index == 3 ? 9 : 1e12;
    }

    function _balance(address asset, address account) internal view returns (uint256) {
        return asset == address(0) ? account.balance : MockToken(asset).balanceOf(account);
    }

    function _fundAndApprove(AssetReceiver target, address actor, address asset, uint256 amount) internal {
        if (asset == address(0)) {
            vm.deal(actor, actor.balance + amount);
        } else {
            MockToken(asset).mint(actor, amount);
            vm.prank(actor);
            MockToken(asset).approve(address(target), amount);
        }
    }

    function _send(AssetReceiver target, address actor, address asset, uint256 amount) internal {
        vm.prank(actor);
        if (asset == address(0)) target.depositETH{value: amount}();
        else target.depositToken(asset, amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzRemainingCapAcceptsMaximumThenRejectsOneUnit(uint8 assetSeed, uint256 prefixSeed) public {
        uint256 index = uint256(assetSeed) % 4;
        address asset = _asset(index);
        uint256 prefix = bound(prefixSeed, 1, 9999e6);
        _deposit(USDT, prefix);
        uint256 maximum = (CAP - prefix * 1e12) / _unit(index);
        _fundAndApprove(receiver, OUTSIDER, asset, maximum + 1);
        _send(receiver, OUTSIDER, asset, maximum);

        uint256 accepted = prefix * 1e12 + maximum * _unit(index);
        assertEq(receiver.totalAcceptedUsd(), accepted);
        assertEq(receiver.remainingCapacityUsd(), CAP - accepted);
        uint256 heldBefore = _balance(asset, address(receiver));
        uint256 donorBefore = _balance(asset, OUTSIDER);
        vm.prank(OUTSIDER);
        vm.expectRevert(AssetReceiver.CapExceeded.selector);
        if (index == 0) receiver.depositETH{value: 1}();
        else receiver.depositToken(asset, 1);

        assertEq(receiver.totalAcceptedUsd(), accepted);
        assertEq(_balance(asset, address(receiver)), heldBefore);
        assertEq(_balance(asset, OUTSIDER), donorBefore);
        if (index != 0) assertEq(MockToken(asset).allowance(OUTSIDER, address(receiver)), 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzSplittingBetweenSendersCannotChangeValue(uint8 assetSeed, uint256 amountSeed, uint256 splitSeed)
        public
    {
        uint256 index = uint256(assetSeed) % 4;
        address asset = _asset(index);
        uint256 amount = bound(amountSeed, 2, CAP / _unit(index));
        uint256 first = bound(splitSeed, 1, amount - 1);
        AssetReceiver lump = new AssetReceiver(OWNER, address(0));
        _fundAndApprove(lump, DONOR, asset, amount);
        _send(lump, DONOR, asset, amount);
        _fundAndApprove(receiver, DONOR, asset, first);
        _send(receiver, DONOR, asset, first);
        _fundAndApprove(receiver, OUTSIDER, asset, amount - first);
        _send(receiver, OUTSIDER, asset, amount - first);
        assertEq(receiver.totalAcceptedUsd(), lump.totalAcceptedUsd());
        assertEq(receiver.remainingCapacityUsd(), lump.remainingCapacityUsd());
        assertEq(_balance(asset, address(receiver)), amount);
        assertEq(_balance(asset, address(lump)), amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzPartialThenFullWithdrawalInEveryLifecycleState(
        uint8 assetSeed,
        uint256 amountSeed,
        uint256 partSeed,
        uint8 stateSeed
    ) public {
        uint256 index = uint256(assetSeed) % 4;
        address asset = _asset(index);
        uint256 amount = bound(amountSeed, 1, CAP / _unit(index));
        uint256 part = bound(partSeed, 1, amount);
        _fundAndApprove(receiver, DONOR, asset, amount);
        _send(receiver, DONOR, asset, amount);
        uint256 accepted = receiver.totalAcceptedUsd();
        uint256 state = uint256(stateSeed) % 3;
        if (state != 0) _pause();
        if (state == 2) {
            AssetReceiver next = new AssetReceiver(OWNER, address(receiver));
            vm.prank(OWNER);
            receiver.upgradeTo(address(next));
        }
        vm.expectEmit(true, false, false, true, address(receiver));
        emit Withdrawn(asset, part);
        vm.prank(BENEFICIARY);
        receiver.withdraw(asset, part);
        assertEq(_balance(asset, address(receiver)), amount - part);
        assertEq(_balance(asset, BENEFICIARY), part);
        if (part < amount) {
            vm.prank(BENEFICIARY);
            receiver.withdrawAll(asset);
        }
        assertEq(_balance(asset, address(receiver)), 0);
        assertEq(_balance(asset, BENEFICIARY), amount);
        assertEq(receiver.totalAcceptedUsd(), accepted);
        vm.prank(BENEFICIARY);
        vm.expectRevert(AssetReceiver.ZeroAmount.selector);
        receiver.withdrawAll(asset);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzFeeReceiptDeterminesValueAndDepositEvent(uint8 assetSeed, uint256 amountSeed, uint16 feeSeed)
        public
    {
        uint256 index = 1 + uint256(assetSeed) % 3;
        address asset = _asset(index);
        uint256 amount = bound(amountSeed, 1, CAP / _unit(index));
        uint256 fee = bound(uint256(feeSeed), 0, 9999);
        uint256 received = amount - amount * fee / 10_000;
        MockToken(asset).configure(MockToken.ReturnMode.Normal, fee, false);
        _fundAndApprove(receiver, DONOR, asset, amount);
        vm.expectEmit(true, true, false, true, address(receiver));
        emit Deposited(DONOR, asset, received, received * _unit(index));
        _send(receiver, DONOR, asset, amount);
        assertEq(MockToken(asset).balanceOf(DONOR), 0);
        assertEq(MockToken(asset).balanceOf(address(receiver)), received);
        assertEq(receiver.totalAcceptedUsd(), received * _unit(index));
    }

    function testFeeAdjustedReceiptCanFillExactCapAndOverageRollsBack() public {
        _deposit(USDT, 9999e6);
        MockToken token = MockToken(USDC);
        token.configure(MockToken.ReturnMode.Normal, 5000, false);
        _fundAndApprove(receiver, DONOR, USDC, 3e6);
        vm.prank(DONOR);
        vm.expectRevert(AssetReceiver.CapExceeded.selector);
        receiver.depositToken(USDC, 3e6); // $1.50 actually received, only $1 available.
        assertEq(token.balanceOf(DONOR), 3e6);
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(token.allowance(DONOR, address(receiver)), 3e6);
        assertEq(receiver.totalAcceptedUsd(), 9999e18);
        _send(receiver, DONOR, USDC, 2e6); // Gross $2, net $1 fits exactly.
        assertEq(receiver.totalAcceptedUsd(), CAP);
        assertEq(token.balanceOf(address(receiver)), 1e6);
    }

    function testEntireTransferFeeRevertsWithoutBurningDonorTokens() public {
        MockToken token = MockToken(IMD);
        token.configure(MockToken.ReturnMode.Normal, 10_000, false);
        _fundAndApprove(receiver, DONOR, IMD, 1);
        vm.prank(DONOR);
        vm.expectRevert(AssetReceiver.NoTokensReceived.selector);
        receiver.depositToken(IMD, 1);
        assertEq(token.balanceOf(DONOR), 1);
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(token.allowance(DONOR, address(receiver)), 1);
        assertEq(receiver.totalAcceptedUsd(), 0);
    }

    function testMaximumUintRevertsAtomicallyForEveryToken() public {
        for (uint256 i = 1; i < 4; ++i) {
            address asset = _asset(i);
            _fundAndApprove(receiver, DONOR, asset, type(uint256).max);
            vm.prank(DONOR);
            vm.expectRevert(AssetReceiver.CapExceeded.selector);
            receiver.depositToken(asset, type(uint256).max);
            assertEq(MockToken(asset).balanceOf(DONOR), type(uint256).max);
            assertEq(MockToken(asset).allowance(DONOR, address(receiver)), type(uint256).max);
            assertEq(MockToken(asset).balanceOf(address(receiver)), 0);
            assertEq(receiver.totalAcceptedUsd(), 0);
        }
    }

    function testAllWithdrawalTokenFailureModesAreAtomicAndRecoverable() public {
        for (uint256 i = 1; i < 4; ++i) {
            address asset = _asset(i);
            uint256 amount = i == 3 ? 1e18 : 1e6;
            _deposit(asset, amount);
            uint256 accepted = receiver.totalAcceptedUsd();
            for (uint256 mode = 2; mode <= 4; ++mode) {
                MockToken(asset).configure(MockToken.ReturnMode(mode), 0, false);
                for (uint256 all; all < 2; ++all) {
                    vm.prank(BENEFICIARY);
                    if (mode == 3) vm.expectRevert(bytes("token unavailable"));
                    else vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, asset));
                    if (all == 0) receiver.withdraw(asset, amount / 2);
                    else receiver.withdrawAll(asset);
                    assertEq(MockToken(asset).balanceOf(address(receiver)), amount);
                    assertEq(MockToken(asset).balanceOf(BENEFICIARY), 0);
                    assertEq(receiver.totalAcceptedUsd(), accepted);
                }
            }
            MockToken(asset).configure(MockToken.ReturnMode.Empty, 0, false);
            vm.prank(BENEFICIARY);
            receiver.withdrawAll(asset);
            assertEq(MockToken(asset).balanceOf(BENEFICIARY), amount);
            assertEq(MockToken(asset).balanceOf(address(receiver)), 0);
        }
    }

    function testAnApprovedDonorCannotBeDebitedByAnotherCaller() public {
        _fundAndApprove(receiver, DONOR, USDC, 100e6);
        vm.startPrank(OUTSIDER);
        MockToken(USDC).approve(address(receiver), 100e6);
        vm.expectRevert(bytes("balance"));
        receiver.depositToken(USDC, 100e6);
        vm.stopPrank();
        assertEq(MockToken(USDC).balanceOf(DONOR), 100e6);
        assertEq(MockToken(USDC).allowance(DONOR, address(receiver)), 100e6);
        assertEq(receiver.totalAcceptedUsd(), 0);
    }

    function testReceiveZeroPausedAndOverCapFailuresReturnFunds() public {
        vm.prank(DONOR);
        (bool ok, bytes memory reason) = address(receiver).call("");
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(AssetReceiver.ZeroAmount.selector));
        _pause();
        uint256 beforeBalance = DONOR.balance;
        vm.prank(DONOR);
        (ok, reason) = address(receiver).call{value: 1}("");
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(AssetReceiver.DepositsPaused.selector));
        assertEq(DONOR.balance, beforeBalance);
        vm.prank(OWNER);
        receiver.unpause();
        _deposit(USDC, 10_000e6);
        vm.prank(DONOR);
        (ok, reason) = address(receiver).call{value: 1}("");
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(AssetReceiver.CapExceeded.selector));
        assertEq(DONOR.balance, beforeBalance);
        assertEq(address(receiver).balance, 0);
        assertEq(receiver.totalAcceptedUsd(), CAP);
    }
}
