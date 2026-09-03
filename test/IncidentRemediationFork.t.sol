// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";

import {IOrderBook} from "../contracts/interfaces/IOrderBook.sol";
import {KuruAMMVaultErrors, MarginAccountErrors} from "../contracts/libraries/Errors.sol";
import {KuruAMMVault} from "../contracts/KuruAMMVault.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {OrderBook} from "../contracts/OrderBook.sol";
import {Router} from "../contracts/Router.sol";

/// @notice Replays the production XAUt0 exploit and its incident-path remediation on a Monad fork.
/// @dev Run with:
///      MONAD_RPC_URL=https://rpc.prod.kuru.io forge test \
///        --match-contract IncidentRemediationForkTest -vvv
/// @dev The test restores the global pause at the end. A production resume additionally requires upgrading
///      every Router-registered OrderBook proxy, not only the three contracts exercised by this incident path.
contract IncidentRemediationForkTest is Test {
    uint256 internal constant PRE_EXPLOIT_BLOCK = 101_476_507;

    address internal constant ROUTER = 0xd651346d7c789536ebf06dc72aE3C8502cd695CC;
    address internal constant MARGIN_ACCOUNT = 0x2A68ba1833cDf93fa9Da1EEbd7F46242aD8E90c5;
    address internal constant XAUT = 0x01bFF41798a0BcF287b996046Ca68b395DbC1071;
    address internal constant MALICIOUS_BASE_TWO = 0x39E6a23F84e032d3537b533291f992DA8d785466;
    address internal constant XAUT_USDC_MARKET = 0x851145eaeFdc37956B08dA829fa31722199F3f07;

    address internal constant MALICIOUS_MARKET_ONE = 0xA56e558B9866897024ad43792E9E23D521F948b6;
    address internal constant MALICIOUS_MARKET_TWO = 0xA637e569A1f949BBd8EdFE7793d5655978d01982;

    address internal constant EXPLOIT_ACCOUNT_ONE = 0x14eC75607A11F3B1C60248Bf3AF6C204d611f0f5;
    address internal constant EXPLOIT_ACCOUNT_TWO = 0xc70Ec7AC0b523Ad7B0230191A8B301AE23167FA8;
    address internal constant OPERATOR_ONE = 0x71c9f3b7b664b080ecf0634087634a29f70eea41;
    address internal constant WORKER_ONE = 0x3F37ED7b285C83BD7d55F689d081A51731e2E74C;
    address internal constant OPERATOR_TWO = 0x3f14a9e37D93274edb3a62250075aE2592DA349B;
    address internal constant WORKER_TWO = 0xfFe4266c366D921BC3be8c0ea737C77E5A39bBDE;

    address internal constant DEPLOYED_ROUTER_IMPLEMENTATION = 0x0F2A2a5c0A78c406c26Adb2F1681D3e47322A9CD;
    address internal constant DEPLOYED_MARGIN_IMPLEMENTATION = 0x57cF97FE1FAC7D78B07e7e0761410cb2e91F0ca7;
    address internal constant DEPLOYED_ORDERBOOK_IMPLEMENTATION = 0x4C0bA1BA8404076E2B09c7a5d014EC999c3a27e2;

    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // This is the deployed exploit entrypoint used in production transaction
    // 0xf45cc7022e594e4424f4bc9bf07d15bed27afd91121764a40747ac51d5f3cd3d.
    // The parameters are minimized from (367, 3) to the smallest reproducing cycle, (2, 1).
    bytes internal constant DEPLOYED_EXPLOIT_CALLDATA =
        hex"18f3a58500000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000001";

    Router internal router = Router(payable(ROUTER));
    MarginAccount internal marginAccount = MarginAccount(payable(MARGIN_ACCOUNT));

    function testFork_ProductionExploitThenFullRemediation() public {
        string memory rpcUrl = vm.envOr("MONAD_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpcUrl, PRE_EXPLOIT_BLOCK);

        address protocolOwner = router.owner();
        assertEq(protocolOwner, marginAccount.owner(), "router and margin owners differ");
        _assertStartingImplementations();
        assertEq(
            uint8(OrderBook(MALICIOUS_MARKET_ONE).marketState()),
            uint8(IOrderBook.MarketState.ACTIVE),
            "first malicious market is not active at fork block"
        );
        assertEq(
            uint8(OrderBook(MALICIOUS_MARKET_TWO).marketState()),
            uint8(IOrderBook.MarketState.ACTIVE),
            "second malicious market is not active at fork block"
        );

        // First replay the deployed production exploit entrypoint against the deployed implementations.
        uint256 cleanFork = vm.snapshot();
        _assertDeployedExploitCreatesUnbackedXaut();
        assertTrue(vm.revertTo(cleanFork), "failed to restore clean pre-remediation fork");

        (
            address newRouterImplementation,
            address newMarginImplementation,
            address newOrderBookImplementation,
            address newVaultImplementation
        ) = _applyRemediation(protocolOwner);

        _assertRemediationState(
            newRouterImplementation,
            newMarginImplementation,
            newOrderBookImplementation,
            newVaultImplementation,
            protocolOwner
        );
        _assertPermissionlessMarketCreationIsDisabled();

        // Exercise the controls with the rest of the protocol notionally resumed, then restore the
        // globally-paused remediation snapshot at the end of the test.
        uint256 remediatedState = vm.snapshot();
        vm.prank(protocolOwner);
        marginAccount.toggleProtocolState(false);
        assertFalse(_protocolPaused(), "protocol did not resume inside verification snapshot");

        // The identical production call is blocked by the blacklist after a global resume.
        uint256 attackerXautBefore = marginAccount.getBalance(EXPLOIT_ACCOUNT_TWO, XAUT);
        uint256 physicalXautBefore = IERC20(XAUT).balanceOf(MARGIN_ACCOUNT);
        vm.prank(OPERATOR_TWO, OPERATOR_TWO);
        vm.expectRevert(MarginAccountErrors.AddressBlacklisted.selector);
        marginAccount.deposit(EXPLOIT_ACCOUNT_TWO, MALICIOUS_BASE_TWO, 0);

        (bool success,) = _callDeployedExploit();
        assertFalse(success, "exploit call unexpectedly succeeded after remediation");
        assertEq(
            marginAccount.getBalance(EXPLOIT_ACCOUNT_TWO, XAUT), attackerXautBefore, "blocked call changed XAUt0 margin"
        );
        assertEq(IERC20(XAUT).balanceOf(MARGIN_ACCOUNT), physicalXautBefore, "blocked call changed physical XAUt0");

        // Isolate the accounting fix from the pause and blacklist. The fixed OrderBook rounds
        // the formerly-zero XAUt0 debit up to one, so this unfunded cycle reverts.
        _setMaliciousMarketsState(protocolOwner, IOrderBook.MarketState.ACTIVE);
        vm.prank(protocolOwner);
        marginAccount.blacklistAddress(EXPLOIT_ACCOUNT_TWO, false);

        attackerXautBefore = marginAccount.getBalance(EXPLOIT_ACCOUNT_TWO, XAUT);
        physicalXautBefore = IERC20(XAUT).balanceOf(MARGIN_ACCOUNT);
        uint256 attackerBaseMarginBefore = marginAccount.getBalance(EXPLOIT_ACCOUNT_TWO, MALICIOUS_BASE_TWO);
        uint256 attackerBaseWalletBefore = IERC20(MALICIOUS_BASE_TWO).balanceOf(EXPLOIT_ACCOUNT_TWO);
        vm.expectCall(
            MARGIN_ACCOUNT,
            abi.encodeWithSelector(MarginAccount.debitUser.selector, EXPLOIT_ACCOUNT_TWO, XAUT, uint256(1))
        );
        (success,) = _callDeployedExploit();
        assertFalse(success, "rounding fix did not reject unfunded exploit cycle");
        assertEq(marginAccount.getBalance(EXPLOIT_ACCOUNT_TWO, XAUT), attackerXautBefore, "fixed cycle changed XAUt0");
        assertEq(IERC20(XAUT).balanceOf(MARGIN_ACCOUNT), physicalXautBefore, "fixed cycle changed physical XAUt0");
        assertEq(
            marginAccount.getBalance(EXPLOIT_ACCOUNT_TWO, MALICIOUS_BASE_TWO),
            attackerBaseMarginBefore,
            "fixed cycle changed base margin"
        );
        assertEq(
            IERC20(MALICIOUS_BASE_TWO).balanceOf(EXPLOIT_ACCOUNT_TWO),
            attackerBaseWalletBefore,
            "fixed cycle changed base wallet"
        );

        assertTrue(vm.revertTo(remediatedState), "failed to restore final remediation state");
        assertTrue(_protocolPaused(), "global pause was not restored");
        _assertMarketsHardPaused();
        assertTrue(marginAccount.blacklistedAddresses(EXPLOIT_ACCOUNT_ONE), "first exploiter not blacklisted");
        assertTrue(marginAccount.blacklistedAddresses(EXPLOIT_ACCOUNT_TWO), "second exploiter not blacklisted");
    }

    function _assertDeployedExploitCreatesUnbackedXaut() internal {
        uint256 attackerXautBefore = marginAccount.getBalance(EXPLOIT_ACCOUNT_TWO, XAUT);
        uint256 physicalXautBefore = IERC20(XAUT).balanceOf(MARGIN_ACCOUNT);
        uint256 attackerBaseMarginBefore = marginAccount.getBalance(EXPLOIT_ACCOUNT_TWO, MALICIOUS_BASE_TWO);
        uint256 attackerBaseWalletBefore = IERC20(MALICIOUS_BASE_TWO).balanceOf(EXPLOIT_ACCOUNT_TWO);

        (bool success,) = _callDeployedExploit();
        assertTrue(success, "deployed exploit replay failed");

        assertEq(
            marginAccount.getBalance(EXPLOIT_ACCOUNT_TWO, XAUT),
            attackerXautBefore + 1,
            "deployed OrderBook did not reproduce phantom XAUt0"
        );
        assertEq(
            IERC20(XAUT).balanceOf(MARGIN_ACCOUNT), physicalXautBefore, "exploit replay transferred physical XAUt0 in"
        );
        assertEq(
            marginAccount.getBalance(EXPLOIT_ACCOUNT_TWO, MALICIOUS_BASE_TWO),
            attackerBaseMarginBefore,
            "exploit replay spent internal base"
        );
        assertEq(
            IERC20(MALICIOUS_BASE_TWO).balanceOf(EXPLOIT_ACCOUNT_TWO),
            attackerBaseWalletBefore,
            "exploit replay spent physical base"
        );
    }

    function _callDeployedExploit() internal returns (bool success, bytes memory returnData) {
        vm.prank(OPERATOR_TWO, OPERATOR_TWO);
        (success, returnData) = EXPLOIT_ACCOUNT_TWO.call{gas: 100_000_000}(DEPLOYED_EXPLOIT_CALLDATA);
    }

    function _applyRemediation(address protocolOwner)
        internal
        returns (
            address newRouterImplementation,
            address newMarginImplementation,
            address newOrderBookImplementation,
            address newVaultImplementation
        )
    {
        // Match the intended operational order: contain first, then upgrade, then blacklist.
        vm.prank(protocolOwner);
        marginAccount.toggleProtocolState(true);
        _setMaliciousMarketsState(protocolOwner, IOrderBook.MarketState.HARD_PAUSED);

        newRouterImplementation = address(new Router());
        vm.prank(protocolOwner);
        router.upgradeToAndCall(newRouterImplementation, "");

        newMarginImplementation = address(new MarginAccount());
        vm.prank(protocolOwner);
        marginAccount.upgradeToAndCall(newMarginImplementation, "");

        newOrderBookImplementation = address(new OrderBook());
        vm.startPrank(protocolOwner);
        router.upgradeOrderBookImplementation(newOrderBookImplementation);

        address[] memory markets = new address[](3);
        markets[0] = MALICIOUS_MARKET_ONE;
        markets[1] = MALICIOUS_MARKET_TWO;
        markets[2] = XAUT_USDC_MARKET;
        bytes[] memory upgradeData = new bytes[](markets.length);
        router.upgradeMultipleOrderBookProxies(markets, upgradeData);

        newVaultImplementation = address(new KuruAMMVault());
        router.upgradeVaultImplementation(newVaultImplementation);
        address[] memory vaults = new address[](markets.length);
        for (uint256 i; i < markets.length; ++i) {
            vaults[i] = _vaultOf(markets[i]);
        }
        router.upgradeMultipleVaultProxies(vaults, upgradeData);

        address[6] memory exploiterAddresses =
            [EXPLOIT_ACCOUNT_ONE, EXPLOIT_ACCOUNT_TWO, OPERATOR_ONE, WORKER_ONE, OPERATOR_TWO, WORKER_TWO];
        for (uint256 i; i < exploiterAddresses.length; ++i) {
            marginAccount.blacklistAddress(exploiterAddresses[i], true);
        }
        vm.stopPrank();
    }

    function _assertRemediationState(
        address newRouterImplementation,
        address newMarginImplementation,
        address newOrderBookImplementation,
        address newVaultImplementation,
        address protocolOwner
    ) internal {
        assertEq(_implementationOf(ROUTER), newRouterImplementation, "router implementation not upgraded");
        assertEq(_implementationOf(MARGIN_ACCOUNT), newMarginImplementation, "margin implementation not upgraded");
        assertEq(router.owner(), protocolOwner, "router owner changed during upgrade");
        assertEq(marginAccount.owner(), protocolOwner, "margin owner changed during upgrade");
        assertEq(router.orderBookImplementation(), newOrderBookImplementation, "router OrderBook pointer not updated");
        assertEq(_implementationOf(MALICIOUS_MARKET_ONE), newOrderBookImplementation, "first market not upgraded");
        assertEq(_implementationOf(MALICIOUS_MARKET_TWO), newOrderBookImplementation, "second market not upgraded");
        assertEq(_implementationOf(XAUT_USDC_MARKET), newOrderBookImplementation, "XAUt0/USDC market not upgraded");
        assertEq(router.kuruAmmVaultImplementation(), newVaultImplementation, "Router vault pointer not updated");
        assertEq(
            _implementationOf(_vaultOf(MALICIOUS_MARKET_ONE)), newVaultImplementation, "first vault not upgraded"
        );
        assertEq(
            _implementationOf(_vaultOf(MALICIOUS_MARKET_TWO)), newVaultImplementation, "second vault not upgraded"
        );
        assertEq(_implementationOf(_vaultOf(XAUT_USDC_MARKET)), newVaultImplementation, "XAUt0/USDC vault not upgraded");
        vm.expectRevert(KuruAMMVaultErrors.VaultDisabled.selector);
        KuruAMMVault(payable(_vaultOf(XAUT_USDC_MARKET))).deposit(0, 0, 0, address(this));
        assertTrue(_protocolPaused(), "global protocol pause was not preserved");
        _assertMarketsHardPaused();

        address[6] memory exploiterAddresses =
            [EXPLOIT_ACCOUNT_ONE, EXPLOIT_ACCOUNT_TWO, OPERATOR_ONE, WORKER_ONE, OPERATOR_TWO, WORKER_TWO];
        for (uint256 i; i < exploiterAddresses.length; ++i) {
            assertTrue(marginAccount.blacklistedAddresses(exploiterAddresses[i]), "cluster address not blacklisted");
        }
    }

    function _assertStartingImplementations() internal {
        assertEq(_implementationOf(ROUTER), DEPLOYED_ROUTER_IMPLEMENTATION, "unexpected deployed Router");
        assertEq(_implementationOf(MARGIN_ACCOUNT), DEPLOYED_MARGIN_IMPLEMENTATION, "unexpected deployed MarginAccount");
        assertEq(
            _implementationOf(MALICIOUS_MARKET_ONE), DEPLOYED_ORDERBOOK_IMPLEMENTATION, "unexpected deployed OrderBook"
        );
        assertEq(router.orderBookImplementation(), DEPLOYED_ORDERBOOK_IMPLEMENTATION, "unexpected Router OB pointer");
    }

    function _assertPermissionlessMarketCreationIsDisabled() internal {
        vm.prank(OPERATOR_ONE, OPERATOR_ONE);
        vm.expectRevert(Ownable.Unauthorized.selector);
        router.deployProxy(
            IOrderBook.OrderBookType.NO_NATIVE,
            XAUT,
            0x754704Bc059F8C67012fEd69BC8A327a5aafb603,
            1e6,
            1e4,
            100,
            2_000,
            1e8,
            0,
            0,
            100
        );
    }

    function _setMaliciousMarketsState(address protocolOwner, IOrderBook.MarketState state) internal {
        address[] memory markets = new address[](2);
        markets[0] = MALICIOUS_MARKET_ONE;
        markets[1] = MALICIOUS_MARKET_TWO;
        vm.prank(protocolOwner);
        router.toggleMarkets(markets, state);
    }

    function _assertMarketsHardPaused() internal {
        assertEq(
            uint8(OrderBook(MALICIOUS_MARKET_ONE).marketState()),
            uint8(IOrderBook.MarketState.HARD_PAUSED),
            "first malicious market not hard-paused"
        );
        assertEq(
            uint8(OrderBook(MALICIOUS_MARKET_TWO).marketState()),
            uint8(IOrderBook.MarketState.HARD_PAUSED),
            "second malicious market not hard-paused"
        );
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _vaultOf(address market) internal view returns (address vault) {
        (vault,,,,,,,) = OrderBook(market).getVaultParams();
    }

    function _protocolPaused() internal view returns (bool) {
        // MarginAccount slot zero packs trustedForwarder in bits [0, 159] and protocolPaused in bit 160.
        return ((uint256(vm.load(MARGIN_ACCOUNT, bytes32(0))) >> 160) & 1) == 1;
    }
}
