// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReceiverTestBase} from "./helpers/ReceiverTestBase.sol";
import {MockToken} from "./helpers/MockToken.sol";
import {AssetReceiver} from "src/AssetReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev The model changes only after successful calls. Bounds use ghost accounting,
/// not the receiver's own reported capacity or balances. Expected failures are checked
/// for exact revert data and unchanged custody/administration/allowances.
contract AdversarialReceiverHandler is Test {
    using SafeERC20 for IERC20;

    uint256 internal constant LIMIT = 10_000e18;
    address internal constant SECOND_ADMIN = address(0xA22CE);
    address public immutable beneficiary;
    address public immutable firstAdmin;
    address[3] public actors = [address(0xD001), address(0xD002), address(0xD003)];
    address[4] public assets;
    uint256[4] public initialPerActor = [uint256(100 ether), 100_000e6, 100_000e6, 10_000e18];
    AssetReceiver[] public versions;
    mapping(uint256 => uint256[4]) public deposited;
    mapping(uint256 => uint256[4]) public donated;
    mapping(uint256 => uint256[4]) public paid;
    mapping(uint256 => uint256) public accepted;
    mapping(uint256 => address) public admin;
    mapping(uint256 => address) public pendingAdmin;
    mapping(uint256 => bool) public isPaused;
    uint256 public successfulDeposits;
    uint256 public rejectedCalls;

    constructor(AssetReceiver initial) {
        versions.push(initial);
        beneficiary = initial.WITHDRAWER();
        firstAdmin = initial.owner();
        admin[0] = firstAdmin;
        assets = [address(0), initial.USDT(), initial.USDC(), initial.IMD()];
        for (uint256 a; a < actors.length; ++a) {
            vm.deal(actors[a], initialPerActor[0]);
            for (uint256 t = 1; t < 4; ++t) {
                MockToken(assets[t]).mint(actors[a], initialPerActor[t]);
            }
        }
    }

    function count() external view returns (uint256) {
        return versions.length;
    }

    function held(uint256 version, uint256 asset) public view returns (uint256) {
        return deposited[version][asset] + donated[version][asset] - paid[version][asset];
    }

    function balance(uint256 asset, address account) public view returns (uint256) {
        return asset == 0 ? account.balance : MockToken(assets[asset]).balanceOf(account);
    }

    function _unit(uint256 index) private pure returns (uint256) {
        return index == 0 ? 2600 : index == 3 ? 9 : 1e12;
    }

    function _version(uint8 seed) private view returns (uint256) {
        // Favor the current receiver but continue attacking retired ones.
        return seed % 4 == 0 ? uint256(seed) % versions.length : versions.length - 1;
    }

    function _stateHash(uint256 version, address actor) private view returns (bytes32 result) {
        AssetReceiver target = versions[version];
        result = keccak256(
            abi.encode(
                target.owner(),
                target.pendingOwner(),
                target.paused(),
                target.successor(),
                target.totalAcceptedUsd(),
                target.remainingCapacityUsd()
            )
        );
        for (uint256 i; i < 4; ++i) {
            result =
                keccak256(abi.encode(result, balance(i, address(target)), balance(i, actor), balance(i, beneficiary)));
            if (i != 0) {
                result = keccak256(abi.encode(result, MockToken(assets[i]).allowance(actor, address(target))));
            }
        }
    }

    function _invoke(uint256 version, address actor, bytes memory data, uint256 value, bytes4 expectedError) private {
        bytes32 beforeState;
        if (expectedError != bytes4(0)) beforeState = _stateHash(version, actor);
        vm.prank(actor);
        (bool ok, bytes memory result) = address(versions[version]).call{value: value}(data);
        if (expectedError == bytes4(0)) {
            assertTrue(ok, "valid action must succeed");
        } else {
            assertFalse(ok, "invalid action succeeded");
            assertEq(result, abi.encodeWithSelector(expectedError), "wrong failure reason");
            assertEq(_stateHash(version, actor), beforeState, "failed action changed state");
            ++rejectedCalls;
        }
    }

    function deposit(uint8 versionSeed, uint8 actorSeed, uint8 assetSeed, uint256 amountSeed, uint8 mode) public {
        uint256 v = _version(versionSeed);
        uint256 t = uint256(assetSeed) % 4;
        address actor = actors[uint256(actorSeed) % 3];
        uint256 maximum = (LIMIT - accepted[v]) / _unit(t);
        uint256 amount;
        uint256 choice = uint256(mode) % 6;
        if (choice == 0) amount = 0;
        else if (choice == 1) amount = maximum + 1;
        else if (choice == 2) amount = maximum;
        else if (choice == 3 || maximum == 0) amount = 1;
        else amount = bound(amountSeed, 1, _min(maximum, 500e18 / _unit(t)));

        bytes4 error;
        if (v + 1 < versions.length) error = AssetReceiver.Retired.selector;
        else if (isPaused[v]) error = AssetReceiver.DepositsPaused.selector;
        else if (amount == 0) error = AssetReceiver.ZeroAmount.selector;
        else if (amount > maximum) error = AssetReceiver.CapExceeded.selector;

        if (t != 0) {
            vm.prank(actor);
            MockToken(assets[t]).approve(address(versions[v]), amount);
        }
        bytes memory data = t == 0
            ? (mode % 2 == 0 ? bytes("") : abi.encodeCall(AssetReceiver.depositETH, ()))
            : abi.encodeCall(AssetReceiver.depositToken, (assets[t], amount));
        _invoke(v, actor, data, t == 0 ? amount : 0, error);
        if (error == bytes4(0)) {
            deposited[v][t] += amount;
            accepted[v] += amount * _unit(t);
            ++successfulDeposits;
        }
    }

    function withdraw(uint8 versionSeed, uint8 assetSeed, uint256 amountSeed, uint8 mode, bool authorized, bool all)
        external
    {
        uint256 v = uint256(versionSeed) % versions.length;
        uint256 t = uint256(assetSeed) % 4;
        uint256 available = held(v, t);
        uint256 amount =
            mode % 3 == 0 ? 0 : mode % 3 == 1 ? available + 1 : (available == 0 ? 1 : bound(amountSeed, 1, available));
        if (all) amount = available;
        // Include the owner as an unauthorized withdrawer: these roles are separate.
        address actor = authorized ? beneficiary : (mode % 2 == 0 ? admin[v] : actors[0]);
        bytes4 error;
        if (!authorized) error = AssetReceiver.Unauthorized.selector;
        else if (amount == 0) error = AssetReceiver.ZeroAmount.selector;
        else if (amount > available) error = AssetReceiver.InsufficientBalance.selector;
        bytes memory data = all
            ? abi.encodeCall(AssetReceiver.withdrawAll, (assets[t]))
            : abi.encodeCall(AssetReceiver.withdraw, (assets[t], amount));
        _invoke(v, actor, data, 0, error);
        if (error == bytes4(0)) paid[v][t] += amount;
    }

    function donateToken(uint8 versionSeed, uint8 actorSeed, uint8 assetSeed, uint256 amountSeed) external {
        uint256 v = uint256(versionSeed) % versions.length;
        uint256 t = 1 + uint256(assetSeed) % 3;
        address actor = actors[uint256(actorSeed) % 3];
        uint256 available = balance(t, actor);
        // Leave enough funding for any subsequent maximum-cap deposit attempt.
        uint256 reserve = LIMIT / _unit(t) + 1;
        if (available <= reserve) return;
        uint256 amount = bound(amountSeed, 1, _min(available - reserve, 25e18 / _unit(t)));
        vm.prank(actor);
        IERC20(assets[t]).safeTransfer(address(versions[v]), amount);
        donated[v][t] += amount;
    }

    function togglePause(uint8 versionSeed) external {
        uint256 v = uint256(versionSeed) % versions.length;
        bool beforePause = isPaused[v];
        bytes4 error = beforePause && v + 1 < versions.length ? AssetReceiver.Retired.selector : bytes4(0);
        _invoke(
            v,
            admin[v],
            beforePause ? abi.encodeCall(AssetReceiver.unpause, ()) : abi.encodeCall(AssetReceiver.pause, ()),
            0,
            error
        );
        if (error == bytes4(0)) isPaused[v] = !beforePause;
    }

    function handover(uint8 versionSeed, bool accept) external {
        uint256 v = uint256(versionSeed) % versions.length;
        if (accept && pendingAdmin[v] != address(0)) {
            _invoke(v, pendingAdmin[v], abi.encodeCall(AssetReceiver.acceptOwnership, ()), 0, bytes4(0));
            admin[v] = pendingAdmin[v];
            pendingAdmin[v] = address(0);
        } else {
            address next = admin[v] == firstAdmin ? SECOND_ADMIN : firstAdmin;
            _invoke(v, admin[v], abi.encodeCall(AssetReceiver.transferOwnership, (next)), 0, bytes4(0));
            pendingAdmin[v] = next;
        }
    }

    function unauthorizedAdmin(uint8 versionSeed, uint8 actorSeed, uint8 action) external {
        uint256 v = uint256(versionSeed) % versions.length;
        address actor = actors[uint256(actorSeed) % 3];
        uint256 choice = uint256(action) % 5;
        bytes memory data;
        if (choice == 0) data = abi.encodeCall(AssetReceiver.pause, ());
        else if (choice == 1) data = abi.encodeCall(AssetReceiver.unpause, ());
        else if (choice == 2) data = abi.encodeCall(AssetReceiver.transferOwnership, (actor));
        else if (choice == 3) data = abi.encodeCall(AssetReceiver.acceptOwnership, ());
        else data = abi.encodeCall(AssetReceiver.upgradeTo, (address(versions[v])));
        _invoke(v, actor, data, 0, AssetReceiver.Unauthorized.selector);
    }

    function upgrade() external {
        if (versions.length >= 5) return;
        uint256 v = versions.length - 1;
        if (!isPaused[v]) {
            _invoke(v, admin[v], abi.encodeCall(AssetReceiver.pause, ()), 0, bytes4(0));
            isPaused[v] = true;
        }
        AssetReceiver next = new AssetReceiver(admin[v], address(versions[v]));
        _invoke(v, admin[v], abi.encodeCall(AssetReceiver.upgradeTo, (address(next))), 0, bytes4(0));
        versions.push(next);
        admin[v + 1] = admin[v];
        accepted[v + 1] = accepted[v];
    }

    /// @dev Called after each random sequence, including while paused or retired.
    function drainAll() external {
        for (uint256 v; v < versions.length; ++v) {
            for (uint256 t; t < 4; ++t) {
                uint256 amount = held(v, t);
                if (amount == 0) continue;
                _invoke(v, beneficiary, abi.encodeCall(AssetReceiver.withdrawAll, (assets[t])), 0, bytes4(0));
                paid[v][t] += amount;
                assertEq(balance(t, address(versions[v])), 0, "full withdrawal left assets");
            }
        }
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract AssetReceiverAdversarialInvariantTest is ReceiverTestBase {
    AdversarialReceiverHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new AdversarialReceiverHandler(receiver);
        // Seed actual custody and all three actors; no empty-state-only campaigns.
        for (uint8 t; t < 4; ++t) {
            handler.deposit(1, t % 3, t, 100, 4);
        }
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.donateToken.selector;
        selectors[3] = handler.togglePause.selector;
        selectors[4] = handler.handover.selector;
        selectors[5] = handler.unauthorizedAdmin.selector;
        selectors[6] = handler.upgrade.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariantCustodyMatchesIndependentLedgerAndOnlyBeneficiaryGetsPaid() public view {
        for (uint256 t; t < 4; ++t) {
            uint256 allPaid;
            uint256 allHeld;
            uint256 actorFunds;
            for (uint256 v; v < handler.count(); ++v) {
                uint256 actual = handler.balance(t, address(handler.versions(v)));
                assertEq(actual, handler.held(v, t), "receiver custody differs from ledger");
                allHeld += actual;
                allPaid += handler.paid(v, t);
            }
            assertEq(handler.balance(t, BENEFICIARY), allPaid, "wrong beneficiary payout");
            for (uint256 a; a < 3; ++a) {
                actorFunds += handler.balance(t, handler.actors(a));
            }
            assertEq(actorFunds + allPaid + allHeld, handler.initialPerActor(t) * 3, "asset conservation");
        }
    }

    function invariantCapAndAdministrationMatchModelAcrossEveryGeneration() public view {
        uint256 historicalValue;
        for (uint256 v; v < handler.count(); ++v) {
            AssetReceiver target = handler.versions(v);
            historicalValue += handler.deposited(v, 0) * 2600 + (handler.deposited(v, 1) + handler.deposited(v, 2))
            * 1e12 + handler.deposited(v, 3) * 9;
            assertEq(target.totalAcceptedUsd(), historicalValue, "carried deposits changed");
            assertEq(target.totalAcceptedUsd(), handler.accepted(v));
            assertLe(historicalValue, CAP);
            assertEq(target.remainingCapacityUsd(), CAP - historicalValue);
            assertEq(target.owner(), handler.admin(v));
            assertEq(target.pendingOwner(), handler.pendingAdmin(v));
            assertEq(target.paused(), handler.isPaused(v));
            assertEq(target.WITHDRAWER(), BENEFICIARY);
            assertEq(target.predecessor(), v == 0 ? address(0) : address(handler.versions(v - 1)));
            assertEq(target.successor(), v + 1 == handler.count() ? address(0) : address(handler.versions(v + 1)));
        }
        assertGe(handler.successfulDeposits(), 4);
    }

    function afterInvariant() public {
        handler.drainAll();
        invariantCustodyMatchesIndependentLedgerAndOnlyBeneficiaryGetsPaid();
        invariantCapAndAdministrationMatchModelAcrossEveryGeneration();
    }
}
