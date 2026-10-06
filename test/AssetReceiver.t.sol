// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReceiverTestBase} from "./helpers/ReceiverTestBase.sol";
import {MockToken} from "./helpers/MockToken.sol";
import {AssetReceiver} from "../src/AssetReceiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract WithdrawalCallback {
    AssetReceiver private immutable receiver;
    bool private immutable rejects;
    bool public reentrySucceeded;
    bytes4 public reentryError;

    constructor(AssetReceiver receiver_, bool rejects_) {
        receiver = receiver_;
        rejects = rejects_;
    }

    receive() external payable {
        require(!rejects, "reject ETH");
        bytes memory result;
        (reentrySucceeded, result) = address(receiver).call(abi.encodeCall(receiver.withdraw, (address(0), 1)));
        if (result.length >= 4) reentryError = bytes4(result);
    }
}

contract DeploymentFactory {
    function deploy(address owner) external returns (AssetReceiver) {
        return new AssetReceiver{salt: bytes32(uint256(123))}(owner, address(0));
    }
}

contract AssetReceiverTest is ReceiverTestBase {
    function testConstructorAndFactoryOwnership() public {
        DeploymentFactory factory = new DeploymentFactory();
        AssetReceiver deployed = factory.deploy(OWNER);
        assertEq(deployed.owner(), OWNER);
        assertEq(deployed.WITHDRAWER(), BENEFICIARY);
        assertEq(deployed.predecessor(), address(0));
        assertEq(deployed.totalAcceptedUsd(), 0);
        vm.prank(address(factory));
        vm.expectRevert(AssetReceiver.Unauthorized.selector);
        deployed.pause();
        vm.expectRevert(AssetReceiver.InvalidAddress.selector);
        new AssetReceiver(address(0), address(0));
    }

    function testRuntimeMeetsProtectedOpcodeAndSizeRules() public view {
        bytes memory code = address(receiver).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function testMixedAssetsReachExactCap() public {
        _depositETH(1 ether); // $2,600
        _deposit(USDT, 2000e6);
        _deposit(USDC, 900e6);
        _deposit(IMD, 500e18); // $4,500
        assertEq(receiver.totalAcceptedUsd(), CAP);
        assertEq(receiver.remainingCapacityUsd(), 0);
        assertEq(address(receiver).balance, 1 ether);
        assertEq(MockToken(USDT).balanceOf(address(receiver)), 2000e6);
        vm.expectRevert(AssetReceiver.CapExceeded.selector);
        receiver.depositETH{value: 1}();
    }

    function testReceiveAndUnknownCalldata() public {
        vm.prank(DONOR);
        (bool success,) = address(receiver).call{value: 0.5 ether}("");
        assertTrue(success);
        assertEq(receiver.totalAcceptedUsd(), 1300e18);
        (success,) = address(receiver).call{value: 1}(hex"12345678");
        assertFalse(success);
        assertEq(address(receiver).balance, 0.5 ether);
    }

    function testEthBoundaryAndOneWeiOverflow() public {
        uint256 maxEth = CAP / 2600;
        _depositETH(maxEth);
        assertEq(receiver.totalAcceptedUsd(), maxEth * 2600);
        vm.prank(DONOR);
        vm.expectRevert(AssetReceiver.CapExceeded.selector);
        receiver.depositETH{value: 1}();
        assertEq(address(receiver).balance, maxEth);
    }

    function testImdBoundaryAndOneUnitOverflow() public {
        uint256 maxImd = CAP / 9;
        _deposit(IMD, maxImd);
        MockToken(IMD).mint(DONOR, 1);
        vm.startPrank(DONOR);
        MockToken(IMD).approve(address(receiver), 1);
        vm.expectRevert(AssetReceiver.CapExceeded.selector);
        receiver.depositToken(IMD, 1);
        vm.stopPrank();
        assertEq(receiver.totalAcceptedUsd(), maxImd * 9);
        assertEq(MockToken(IMD).balanceOf(DONOR), 1);
    }

    function testStablecoinCapAndOverageRollback() public {
        _deposit(USDC, 10_000e6);
        MockToken(USDT).mint(DONOR, 1);
        vm.startPrank(DONOR);
        MockToken(USDT).approve(address(receiver), 1);
        vm.expectRevert(AssetReceiver.CapExceeded.selector);
        receiver.depositToken(USDT, 1);
        vm.stopPrank();
        assertEq(MockToken(USDT).balanceOf(DONOR), 1);
        assertEq(MockToken(USDT).allowance(DONOR, address(receiver)), 1);
        assertEq(MockToken(USDT).balanceOf(address(receiver)), 0);
    }

    function testDustCannotBypassAccounting() public {
        for (uint256 i; i < 10; ++i) {
            _depositETH(1);
            _deposit(IMD, 1);
        }
        _deposit(USDC, 1);
        assertEq(receiver.totalAcceptedUsd(), 26_090 + 1e12);
    }

    function testZeroAndUnsupportedDeposits() public {
        address unsupported = address(new MockToken(18));
        vm.expectRevert(AssetReceiver.ZeroAmount.selector);
        receiver.depositETH();
        vm.expectRevert(AssetReceiver.ZeroAmount.selector);
        receiver.depositToken(USDC, 0);
        vm.expectRevert(AssetReceiver.UnsupportedAsset.selector);
        receiver.depositToken(address(0), 1);
        vm.expectRevert(AssetReceiver.UnsupportedAsset.selector);
        receiver.depositToken(unsupported, 1);
    }

    function testAllowanceAndBalanceFailuresAreAtomic() public {
        MockToken(USDC).mint(DONOR, 100e6);
        vm.startPrank(DONOR);
        vm.expectRevert(bytes("allowance"));
        receiver.depositToken(USDC, 100e6);
        MockToken(USDC).approve(address(receiver), 200e6);
        vm.expectRevert(bytes("balance"));
        receiver.depositToken(USDC, 200e6);
        vm.stopPrank();
        assertEq(receiver.totalAcceptedUsd(), 0);
        assertEq(MockToken(USDC).balanceOf(DONOR), 100e6);
        assertEq(MockToken(USDC).allowance(DONOR, address(receiver)), 200e6);
    }

    function testFeeOnTransferCountsActualReceipt() public {
        MockToken(IMD).configure(MockToken.ReturnMode.Normal, 1000, false);
        _deposit(IMD, 100e18);
        assertEq(MockToken(IMD).balanceOf(address(receiver)), 90e18);
        assertEq(receiver.totalAcceptedUsd(), 810e18);
    }

    function testFalseMalformedAndRevertingTokenDepositsRollback() public {
        MockToken token = MockToken(USDC);
        token.mint(DONOR, 100e6);
        vm.prank(DONOR);
        token.approve(address(receiver), 100e6);
        for (uint256 i = 2; i <= 4; ++i) {
            token.configure(MockToken.ReturnMode(i), 0, false);
            vm.prank(DONOR);
            if (i == 3) vm.expectRevert(bytes("token unavailable"));
            else vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, USDC));
            receiver.depositToken(USDC, 100e6);
            assertEq(receiver.totalAcceptedUsd(), 0);
            assertEq(token.balanceOf(DONOR), 100e6);
            assertEq(token.balanceOf(address(receiver)), 0);
            assertEq(token.allowance(DONOR, address(receiver)), 100e6);
        }
    }

    function testSuccessfulTokenCallWithoutMovementIsRejected() public {
        MockToken(USDC).configure(MockToken.ReturnMode.Normal, 0, true);
        vm.prank(DONOR);
        MockToken(USDC).approve(address(receiver), 1);
        vm.prank(DONOR);
        vm.expectRevert(AssetReceiver.NoTokensReceived.selector);
        receiver.depositToken(USDC, 1);
        assertEq(receiver.totalAcceptedUsd(), 0);
    }

    function testTokenCallbackCannotReenterDeposit() public {
        vm.deal(USDC, 1);
        MockToken(USDC).setCallback(address(receiver), abi.encodeCall(receiver.depositETH, ()), 1);
        _deposit(USDC, 100e6);
        assertFalse(MockToken(USDC).callbackSucceeded());
        assertEq(MockToken(USDC).callbackError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(receiver.totalAcceptedUsd(), 100e18);
        assertEq(address(receiver).balance, 0);
    }

    function testOnlySpecifiedAddressWithdrawsEvenAfterOwnershipTransfer() public {
        _depositETH(1 ether);
        vm.prank(OWNER);
        receiver.transferOwnership(OUTSIDER);
        vm.prank(OUTSIDER);
        receiver.acceptOwnership();
        address[3] memory unauthorized = [OWNER, OUTSIDER, DONOR];
        for (uint256 i; i < unauthorized.length; ++i) {
            vm.startPrank(unauthorized[i]);
            vm.expectRevert(AssetReceiver.Unauthorized.selector);
            receiver.withdraw(address(0), 1);
            vm.expectRevert(AssetReceiver.Unauthorized.selector);
            receiver.withdrawAll(address(0));
            vm.stopPrank();
        }
        vm.prank(BENEFICIARY);
        receiver.withdrawAll(address(0));
        assertEq(BENEFICIARY.balance, 1 ether);
    }

    function testPartialAndFullWithdrawalOfAllAssetsWhilePaused() public {
        _depositETH(1 ether);
        _deposit(USDT, 100e6);
        _deposit(USDC, 100e6);
        _deposit(IMD, 100e18);
        _pause();
        address[4] memory assets = [address(0), USDT, USDC, IMD];
        uint256[4] memory amounts = [uint256(1 ether), 100e6, 100e6, 100e18];
        for (uint256 i; i < assets.length; ++i) {
            vm.startPrank(BENEFICIARY);
            receiver.withdraw(assets[i], amounts[i] / 2);
            receiver.withdrawAll(assets[i]);
            vm.stopPrank();
            if (i == 0) {
                assertEq(address(receiver).balance, 0);
                assertEq(BENEFICIARY.balance, amounts[i]);
            } else {
                assertEq(MockToken(assets[i]).balanceOf(address(receiver)), 0);
                assertEq(MockToken(assets[i]).balanceOf(BENEFICIARY), amounts[i]);
            }
        }
        assertEq(receiver.totalAcceptedUsd(), 3700e18);
    }

    function testWithdrawalsDoNotReopenCap() public {
        _deposit(USDC, 10_000e6);
        vm.prank(BENEFICIARY);
        receiver.withdrawAll(USDC);
        assertEq(receiver.totalAcceptedUsd(), CAP);
        vm.prank(DONOR);
        vm.expectRevert(AssetReceiver.CapExceeded.selector);
        receiver.depositETH{value: 1}();
    }

    function testInvalidWithdrawals() public {
        _depositETH(1 ether);
        _deposit(USDC, 1e6);
        vm.startPrank(BENEFICIARY);
        vm.expectRevert(AssetReceiver.ZeroAmount.selector);
        receiver.withdraw(address(0), 0);
        vm.expectRevert(AssetReceiver.InsufficientBalance.selector);
        receiver.withdraw(address(0), 1 ether + 1);
        vm.expectRevert(AssetReceiver.InsufficientBalance.selector);
        receiver.withdraw(USDC, 1e6 + 1);
        vm.expectRevert(AssetReceiver.ZeroAmount.selector);
        receiver.withdrawAll(USDT);
        vm.stopPrank();
    }

    function testRevertingEthRecipientKeepsFundsAvailable() public {
        _depositETH(1 ether);
        vm.etch(BENEFICIARY, address(new WithdrawalCallback(receiver, true)).code);
        vm.prank(BENEFICIARY);
        vm.expectRevert(AssetReceiver.EthTransferFailed.selector);
        receiver.withdrawAll(address(0));
        assertEq(address(receiver).balance, 1 ether);
        assertEq(receiver.totalAcceptedUsd(), 2600e18);
        vm.etch(BENEFICIARY, hex"");
        vm.prank(BENEFICIARY);
        receiver.withdrawAll(address(0));
        assertEq(BENEFICIARY.balance, 1 ether);
    }

    function testAuthorizedRecipientCannotReenterWithdrawal() public {
        _depositETH(1 ether);
        vm.etch(BENEFICIARY, address(new WithdrawalCallback(receiver, false)).code);
        vm.prank(BENEFICIARY);
        receiver.withdraw(address(0), 0.5 ether);
        assertFalse(WithdrawalCallback(payable(BENEFICIARY)).reentrySucceeded());
        assertEq(
            WithdrawalCallback(payable(BENEFICIARY)).reentryError(),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector
        );
        assertEq(address(receiver).balance, 0.5 ether);
        assertEq(BENEFICIARY.balance, 0.5 ether);
    }

    function testTokenWithdrawalFailureRollsBack() public {
        _deposit(USDC, 100e6);
        MockToken(USDC).configure(MockToken.ReturnMode.False, 0, false);
        vm.prank(BENEFICIARY);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, USDC));
        receiver.withdrawAll(USDC);
        assertEq(MockToken(USDC).balanceOf(address(receiver)), 100e6);
        assertEq(MockToken(USDC).balanceOf(BENEFICIARY), 0);
    }

    function testHugeTokenAmountRevertsWithCapErrorWithoutOverflow() public {
        MockToken(USDC).mint(DONOR, type(uint256).max);
        vm.startPrank(DONOR);
        MockToken(USDC).approve(address(receiver), type(uint256).max);
        vm.expectRevert(AssetReceiver.CapExceeded.selector);
        receiver.depositToken(USDC, type(uint256).max);
        vm.stopPrank();
        assertEq(MockToken(USDC).balanceOf(DONOR), type(uint256).max);
        assertEq(receiver.totalAcceptedUsd(), 0);
    }

    function testUnsolicitedAssetsAreRecoverableButNotRecordedAsDeposits() public {
        _pause();
        vm.deal(address(receiver), 5 ether); // Models ETH forced in without executing receive().
        MockToken unexpected = new MockToken(18);
        unexpected.mint(DONOR, 100e18);
        vm.prank(DONOR);
        unexpected.transfer(address(receiver), 100e18);
        MockToken(USDC).mint(address(receiver), 20_000e6);
        assertEq(receiver.totalAcceptedUsd(), 0);
        vm.startPrank(BENEFICIARY);
        receiver.withdrawAll(address(0));
        receiver.withdrawAll(address(unexpected));
        receiver.withdrawAll(USDC);
        vm.stopPrank();
        assertEq(BENEFICIARY.balance, 5 ether);
        assertEq(unexpected.balanceOf(BENEFICIARY), 100e18);
        assertEq(MockToken(USDC).balanceOf(BENEFICIARY), 20_000e6);
    }

    function testPauseChecksAllDepositPathsAndCanResume() public {
        _pause();
        vm.expectRevert(AssetReceiver.DepositsPaused.selector);
        receiver.depositETH{value: 1}();
        (bool success,) = address(receiver).call{value: 1}("");
        assertFalse(success);
        vm.expectRevert(AssetReceiver.DepositsPaused.selector);
        receiver.depositToken(USDC, 1);
        vm.prank(OWNER);
        receiver.unpause();
        _depositETH(1);
        _deposit(USDT, 1);
    }

    function testUnauthorizedAdministration() public {
        vm.startPrank(OUTSIDER);
        vm.expectRevert(AssetReceiver.Unauthorized.selector);
        receiver.pause();
        vm.expectRevert(AssetReceiver.Unauthorized.selector);
        receiver.unpause();
        vm.expectRevert(AssetReceiver.Unauthorized.selector);
        receiver.transferOwnership(OUTSIDER);
        vm.expectRevert(AssetReceiver.Unauthorized.selector);
        receiver.acceptOwnership();
        vm.expectRevert(AssetReceiver.Unauthorized.selector);
        receiver.upgradeTo(OUTSIDER);
        vm.stopPrank();
    }

    function testOwnershipHandoverRequiresAcceptance() public {
        vm.startPrank(OWNER);
        vm.expectRevert(AssetReceiver.InvalidAddress.selector);
        receiver.transferOwnership(address(0));
        receiver.transferOwnership(OUTSIDER);
        receiver.pause();
        vm.stopPrank();
        assertEq(receiver.owner(), OWNER);
        vm.prank(OUTSIDER);
        vm.expectRevert(AssetReceiver.Unauthorized.selector);
        receiver.unpause();
        vm.prank(OUTSIDER);
        receiver.acceptOwnership();
        assertEq(receiver.owner(), OUTSIDER);
        assertEq(receiver.pendingOwner(), address(0));
        vm.prank(OWNER);
        vm.expectRevert(AssetReceiver.Unauthorized.selector);
        receiver.unpause();
        vm.prank(OUTSIDER);
        receiver.unpause();
    }

    function testFuzzMixedAmountsConserveValue(uint96 ethSeed, uint96 stableSeed, uint96 imdSeed) public {
        uint256 ethAmount = bound(uint256(ethSeed), 1, 1 ether);
        uint256 stableAmount = bound(uint256(stableSeed), 1, 2000e6);
        uint256 imdAmount = bound(uint256(imdSeed), 1, 500e18);
        _depositETH(ethAmount);
        _deposit(USDC, stableAmount);
        _deposit(IMD, imdAmount);
        uint256 expected = ethAmount * 2600 + stableAmount * 1e12 + imdAmount * 9;
        assertEq(receiver.totalAcceptedUsd(), expected);
        assertLe(expected, CAP);
        vm.startPrank(BENEFICIARY);
        receiver.withdrawAll(address(0));
        receiver.withdrawAll(USDC);
        receiver.withdrawAll(IMD);
        vm.stopPrank();
        assertEq(BENEFICIARY.balance, ethAmount);
        assertEq(MockToken(USDC).balanceOf(BENEFICIARY), stableAmount);
        assertEq(MockToken(IMD).balanceOf(BENEFICIARY), imdAmount);
        assertEq(receiver.totalAcceptedUsd(), expected);
    }
}
