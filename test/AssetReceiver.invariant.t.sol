// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReceiverTestBase} from "./helpers/ReceiverTestBase.sol";
import {AssetReceiver} from "../src/AssetReceiver.sol";
import {MockToken} from "./helpers/MockToken.sol";

contract ReceiverHandler is Test {
    AssetReceiver[] public versions;
    uint256[4] public deposited;
    uint256[4] public withdrawn;
    address[4] public assets;
    address private immutable admin;
    address private immutable beneficiary;

    constructor(AssetReceiver initial) {
        versions.push(initial);
        admin = initial.owner();
        beneficiary = initial.WITHDRAWER();
        assets = [address(0), initial.USDT(), initial.USDC(), initial.IMD()];
    }

    function count() external view returns (uint256) {
        return versions.length;
    }

    function current() public view returns (AssetReceiver) {
        return versions[versions.length - 1];
    }

    function deposit(uint8 assetSeed, uint256 amountSeed, bool plainTransfer) external {
        AssetReceiver active = current();
        if (active.paused()) return;
        uint256 index = uint256(assetSeed) % 4;
        uint256 unit = index == 0 ? 2600 : index == 3 ? 9 : 1e12;
        uint256 maximum = active.remainingCapacityUsd() / unit;
        if (maximum == 0) return;
        uint256 amount = bound(amountSeed, 1, min(maximum, 500e18 / unit));
        if (index == 0) {
            vm.deal(address(this), amount);
            if (plainTransfer) {
                (bool success,) = address(active).call{value: amount}("");
                require(success, "ETH deposit failed");
            } else {
                active.depositETH{value: amount}();
            }
        } else {
            MockToken token = MockToken(assets[index]);
            token.mint(address(this), amount);
            token.approve(address(active), amount);
            active.depositToken(assets[index], amount);
        }
        deposited[index] += amount;
    }

    function withdraw(uint8 versionSeed, uint8 assetSeed, uint256 amountSeed, bool all) external {
        AssetReceiver selected = versions[uint256(versionSeed) % versions.length];
        uint256 index = uint256(assetSeed) % 4;
        uint256 balance = index == 0 ? address(selected).balance : MockToken(assets[index]).balanceOf(address(selected));
        if (balance == 0) return;
        uint256 amount = all ? balance : bound(amountSeed, 1, balance);
        vm.prank(beneficiary);
        if (all) selected.withdrawAll(assets[index]);
        else selected.withdraw(assets[index], amount);
        withdrawn[index] += amount;
    }

    function togglePause() external {
        AssetReceiver active = current();
        bool isPaused = active.paused();
        vm.prank(admin);
        if (isPaused) active.unpause();
        else active.pause();
    }

    function upgrade() external {
        if (versions.length >= 5) return;
        AssetReceiver previous = current();
        if (!previous.paused()) {
            vm.prank(admin);
            previous.pause();
        }
        AssetReceiver replacement = new AssetReceiver(admin, address(previous));
        vm.prank(admin);
        previous.upgradeTo(address(replacement));
        versions.push(replacement);
    }

    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract AssetReceiverInvariantTest is ReceiverTestBase {
    ReceiverHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new ReceiverHandler(receiver);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ReceiverHandler.deposit.selector;
        selectors[1] = ReceiverHandler.withdraw.selector;
        selectors[2] = ReceiverHandler.togglePause.selector;
        selectors[3] = ReceiverHandler.upgrade.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantLifetimeValueIsExactAndCappedAcrossUpgrades() public view {
        uint256 expected = handler.deposited(0) * 2600 + (handler.deposited(1) + handler.deposited(2)) * 1e12
            + handler.deposited(3) * 9;
        assertEq(handler.current().totalAcceptedUsd(), expected);
        assertLe(expected, CAP);
    }

    function invariantEveryAssetIsConservedAcrossWithdrawalsAndUpgrades() public view {
        for (uint256 asset; asset < 4; ++asset) {
            uint256 held;
            for (uint256 version; version < handler.count(); ++version) {
                address vault = address(handler.versions(version));
                held += asset == 0 ? vault.balance : MockToken(handler.assets(asset)).balanceOf(vault);
            }
            uint256 paid = asset == 0 ? BENEFICIARY.balance : MockToken(handler.assets(asset)).balanceOf(BENEFICIARY);
            assertEq(paid, handler.withdrawn(asset));
            assertEq(held + paid, handler.deposited(asset));
        }
    }

    function invariantOnlyLatestVersionAcceptsDeposits() public view {
        uint256 count = handler.count();
        for (uint256 i; i < count; ++i) {
            AssetReceiver version = handler.versions(i);
            assertEq(version.owner(), OWNER);
            assertEq(version.WITHDRAWER(), BENEFICIARY);
            if (i + 1 < count) {
                assertEq(version.successor(), address(handler.versions(i + 1)));
                assertTrue(version.paused());
            } else {
                assertEq(version.successor(), address(0));
            }
        }
    }
}
