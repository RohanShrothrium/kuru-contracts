// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {MonadDeployer} from "../contracts/periphery/MonadDeployer.sol";

import {KuruAMMVault} from "../contracts/KuruAMMVault.sol";
import {Router} from "../contracts/Router.sol";
import {MarginAccount} from "../contracts/MarginAccount.sol";
import {OrderBook} from "../contracts/OrderBook.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IRouter} from "../contracts/interfaces/IRouter.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import "forge-std/Test.sol";

contract MonadDeployerTest is Test {
    MonadDeployer monadDeployer;
    MarginAccount marginAccount;
    OrderBook implementation;
    Router router;

    event MarketCreated(address market);

    function setUp() public {
        implementation = new OrderBook();
        Router routerImplementation = new Router();
        KuruAMMVault kuruAmmVaultImplementation = new KuruAMMVault();
        address routerProxy = Create2.deploy(
            0,
            bytes32(keccak256("")),
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(routerImplementation, bytes("")))
        );
        router = Router(payable(routerProxy));
        marginAccount = new MarginAccount();
        marginAccount = MarginAccount(payable(address(new ERC1967Proxy(address(marginAccount), ""))));
        marginAccount.initialize(address(this), address(router), address(router), address(0x123));
        monadDeployer =
            new MonadDeployer(IRouter(address(router)), address(this), address(marginAccount), address(0x123), 100, 10 * 10 ** 18);
        router.initialize(
            address(this),
            address(marginAccount),
            address(implementation),
            address(kuruAmmVaultImplementation),
            address(0x123)
        );
    }

    function testDeployMarket() public {
        MonadDeployer.TokenParams memory tokenParams = MonadDeployer.TokenParams(
            "CHOG", "CHOG", "https://chog.com/chog.json", 1000000 * 10 ** 18, address(this), 100
        );
        MonadDeployer.MarketParams memory marketParams = MonadDeployer.MarketParams({
            nativeTokenAmount: 100 * 10 ** 18, // 100 native tokens
            sizePrecision: 10 ** 10, // 10^10 for size precision
            pricePrecision: 10 ** 2, // 10^2 for price precision
            tickSize: 10, // 10 tick size
            minSize: 10 ** 2, // 10^2 minimum size
            maxSize: 10 ** 10, // 10^10 maximum size
            takerFeeBps: 10, // 10 basis points taker fee
            makerFeeBps: 5 // 5 basis points maker fee
        });
        address market = monadDeployer.deployTokenAndMarket{value: 110 ether}(tokenParams, marketParams, bytes(""));
        emit MarketCreated(market);
    }

    function testDeployMarketRevertInsufficientAssets() public {
        MonadDeployer.TokenParams memory tokenParams = MonadDeployer.TokenParams(
            "CHOG", "CHOG", "https://chog.com/chog.json", 1000000 * 10 ** 18, address(this), 100
        );
        MonadDeployer.MarketParams memory marketParams =
            MonadDeployer.MarketParams(100 * 10 ** 18, 10 ** 10, 10 ** 2, 10, 10 ** 2, 10 ** 10, 10, 5);
        vm.expectRevert();
        monadDeployer.deployTokenAndMarket{value: 10 ether}(tokenParams, marketParams, bytes(""));
    }

    function testSetKuruAmmSpread() public {
        monadDeployer.setKuruAmmSpread(100);
        assertEq(monadDeployer.kuruAmmSpread(), 100);
    }

    function testSetKuruCollective() public {
        monadDeployer.setKuruCollective(address(0x123));
        assertEq(monadDeployer.kuruCollective(), address(0x123));
    }

    function testRevertSetKuruAmmSpreadNotOwner() public {
        vm.prank(address(uint160(uint256(keccak256("UNAUTHORIZED")))));
        vm.expectRevert(Ownable.Unauthorized.selector);
        monadDeployer.setKuruAmmSpread(100);
    }

    function testRevertSetKuruCollectiveNotOwner() public {
        vm.prank(address(uint160(uint256(keccak256("UNAUTHORIZED")))));
        vm.expectRevert(Ownable.Unauthorized.selector);
        monadDeployer.setKuruCollective(address(0x123));
    }
}
