// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "./util/TestUtil.sol";
import "../../src/rollup/RollupCreator.sol";
import "../../src/rollup/RollupAdminLogic.sol";
import "../../src/rollup/RollupUserLogic.sol";
import "../../src/rollup/ValidatorUtils.sol";
import "../../src/rollup/ValidatorWalletCreator.sol";
import "../../src/challenge/ChallengeManager.sol";
import "../../src/osp/OneStepProver0.sol";
import "../../src/osp/OneStepProverMemory.sol";
import "../../src/osp/OneStepProverMath.sol";
import "../../src/osp/OneStepProverHostIo.sol";
import "../../src/osp/OneStepProofEntry.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

contract RollupCreatorTest is Test {
    RollupCreator public rollupCreator;
    address public rollupOwner = makeAddr("rollupOwner");
    address public deployer = makeAddr("deployer");
    IRollupAdmin public rollupAdmin;
    IRollupUser public rollupUser;

    /* solhint-disable func-name-mixedcase */

    function setUp() public {
        //// deploy rollup creator and set templates
        vm.startPrank(deployer);
        rollupCreator = new RollupCreator();

        // deploy BridgeCreators
        BridgeCreator ethBridgeCreator = new BridgeCreator();
        ERC20BridgeCreator erc20BridgeCreator = new ERC20BridgeCreator();

        UpgradeExecutor upgradeExecutorLogic = new UpgradeExecutor();

        (
            IOneStepProofEntry ospEntry,
            IChallengeManager challengeManager,
            IRollupAdmin _rollupAdmin,
            IRollupUser _rollupUser
        ) = _prepareRollupDeployment();

        rollupAdmin = _rollupAdmin;
        rollupUser = _rollupUser;

        //// deploy creator and set logic
        rollupCreator.setTemplates(
            ethBridgeCreator,
            erc20BridgeCreator,
            ospEntry,
            challengeManager,
            _rollupAdmin,
            _rollupUser,
            upgradeExecutorLogic,
            address(new ValidatorUtils()),
            address(new ValidatorWalletCreator())
        );

        vm.stopPrank();
    }

    function test_createEthRollup() public {
        vm.startPrank(deployer);

        // deployment params
        ISequencerInbox.MaxTimeVariation memory timeVars =
            ISequencerInbox.MaxTimeVariation(((60 * 60 * 24) / 15), 12, 60 * 60 * 24, 60 * 60);
        Config memory config = Config({
            confirmPeriodBlocks: 20,
            extraChallengeTimeBlocks: 200,
            stakeToken: address(0),
            baseStake: 1000,
            wasmModuleRoot: keccak256("wasm"),
            owner: rollupOwner,
            loserStakeEscrow: address(200),
            chainId: 1337,
            chainConfig: "abc",
            genesisBlockNum: 15_000_000,
            sequencerInboxMaxTimeVariation: timeVars
        });

        /// deploy rollup
        address batchPoster = makeAddr("batch poster");
        address[] memory validators = new address[](2);
        validators[0] = makeAddr("validator1");
        validators[1] = makeAddr("validator2");
        address rollupAddress =
            rollupCreator.createRollup(config, batchPoster, validators, address(0));

        vm.stopPrank();

        /// common checks

        /// rollup creator
        assertEq(IOwnable(address(rollupCreator)).owner(), deployer, "Invalid rollupCreator owner");

        /// rollup proxy
        assertEq(_getPrimary(rollupAddress), address(rollupAdmin), "Invalid proxy primary impl");
        assertEq(_getSecondary(rollupAddress), address(rollupUser), "Invalid proxy secondary impl");

        /// rollup check
        RollupCore rollup = RollupCore(rollupAddress);
        assertTrue(address(rollup.sequencerInbox()) != address(0), "Invalid seqInbox");
        assertTrue(address(rollup.bridge()) != address(0), "Invalid bridge");
        assertTrue(address(rollup.inbox()) != address(0), "Invalid inbox");
        assertTrue(address(rollup.outbox()) != address(0), "Invalid outbox");
        assertTrue(address(rollup.rollupEventInbox()) != address(0), "Invalid rollupEventInbox");
        assertTrue(address(rollup.challengeManager()) != address(0), "Invalid challengeManager");
        assertTrue(rollup.isValidator(validators[0]), "Invalid validator set");
        assertTrue(rollup.isValidator(validators[1]), "Invalid validator set");
        assertTrue(
            ISequencerInbox(address(rollup.sequencerInbox())).isBatchPoster(batchPoster),
            "Invalid batch poster"
        );

        // check proxy admin for non-rollup contracts
        address proxyAdminExpectedAddress = computeCreateAddress(address(rollupCreator), 1);

        assertEq(
            _getProxyAdmin(address(rollup.sequencerInbox())),
            proxyAdminExpectedAddress,
            "Invalid seqInbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.bridge())),
            proxyAdminExpectedAddress,
            "Invalid bridge's proxyAdmin owner"
        );
        assertEq(
            rollup.inbox().getProxyAdmin(),
            proxyAdminExpectedAddress,
            "Invalid inbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.outbox())),
            proxyAdminExpectedAddress,
            "Invalid outbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.rollupEventInbox())),
            proxyAdminExpectedAddress,
            "Invalid rollupEventInbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.challengeManager())),
            proxyAdminExpectedAddress,
            "Invalid challengeManager's proxyAdmin owner"
        );

        // check upgrade executor owns proxyAdmin
        address upgradeExecutorExpectedAddress = computeCreateAddress(address(rollupCreator), 2);
        assertEq(
            ProxyAdmin(_getProxyAdmin(address(rollup.sequencerInbox()))).owner(),
            upgradeExecutorExpectedAddress,
            "Invalid proxyAdmin's owner"
        );

        // upgrade executor owns rollup
        assertEq(
            IOwnable(rollupAddress).owner(), upgradeExecutorExpectedAddress, "Invalid rollup owner"
        );
        assertEq(
            _getProxyAdmin(rollupAddress),
            upgradeExecutorExpectedAddress,
            "Invalid rollup's proxyAdmin owner"
        );

        // check rollupOwner has executor role
        UpgradeExecutor executor = UpgradeExecutor(upgradeExecutorExpectedAddress);
        assertTrue(
            executor.hasRole(keccak256("EXECUTOR_ROLE"), rollupOwner), "Invalid executor role"
        );
    }

    function test_createErc20Rollup() public {
        vm.startPrank(deployer);
        address nativeToken =
            address(new ERC20PresetFixedSupply("Appchain Token", "App", 1_000_000, address(this)));

        // deployment params
        ISequencerInbox.MaxTimeVariation memory timeVars =
            ISequencerInbox.MaxTimeVariation(((60 * 60 * 24) / 15), 12, 60 * 60 * 24, 60 * 60);
        Config memory config = Config({
            confirmPeriodBlocks: 20,
            extraChallengeTimeBlocks: 200,
            stakeToken: address(0),
            baseStake: 1000,
            wasmModuleRoot: keccak256("wasm"),
            owner: rollupOwner,
            loserStakeEscrow: address(200),
            chainId: 1337,
            chainConfig: "abc",
            genesisBlockNum: 15_000_000,
            sequencerInboxMaxTimeVariation: timeVars
        });

        /// deploy rollup
        address batchPoster = makeAddr("batch poster");
        address[] memory validators = new address[](2);
        validators[0] = makeAddr("validator1");
        validators[1] = makeAddr("validator2");
        address rollupAddress =
            rollupCreator.createRollup(config, batchPoster, validators, nativeToken);

        vm.stopPrank();

        /// common checks

        /// rollup creator
        assertEq(IOwnable(address(rollupCreator)).owner(), deployer, "Invalid rollupCreator owner");

        /// rollup proxy
        assertEq(_getPrimary(rollupAddress), address(rollupAdmin), "Invalid proxy primary impl");
        assertEq(_getSecondary(rollupAddress), address(rollupUser), "Invalid proxy secondary impl");

        /// rollup check
        RollupCore rollup = RollupCore(rollupAddress);
        assertTrue(address(rollup.sequencerInbox()) != address(0), "Invalid seqInbox");
        assertTrue(address(rollup.bridge()) != address(0), "Invalid bridge");
        assertTrue(address(rollup.inbox()) != address(0), "Invalid inbox");
        assertTrue(address(rollup.outbox()) != address(0), "Invalid outbox");
        assertTrue(address(rollup.rollupEventInbox()) != address(0), "Invalid rollupEventInbox");
        assertTrue(address(rollup.challengeManager()) != address(0), "Invalid challengeManager");
        assertTrue(rollup.isValidator(validators[0]), "Invalid validator set");
        assertTrue(rollup.isValidator(validators[1]), "Invalid validator set");
        assertTrue(
            ISequencerInbox(address(rollup.sequencerInbox())).isBatchPoster(batchPoster),
            "Invalid batch poster"
        );
        // native token check
        IBridge bridge = RollupCore(address(rollupAddress)).bridge();
        assertEq(
            IERC20Bridge(address(bridge)).nativeToken(), nativeToken, "Invalid native token ref"
        );

        // check proxy admin for non-rollup contracts
        address proxyAdminExpectedAddress = computeCreateAddress(address(rollupCreator), 1);

        assertEq(
            _getProxyAdmin(address(rollup.sequencerInbox())),
            proxyAdminExpectedAddress,
            "Invalid seqInbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.bridge())),
            proxyAdminExpectedAddress,
            "Invalid bridge's proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.inbox())),
            proxyAdminExpectedAddress,
            "Invalid inbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.outbox())),
            proxyAdminExpectedAddress,
            "Invalid outbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.rollupEventInbox())),
            proxyAdminExpectedAddress,
            "Invalid rollupEventInbox' proxyAdmin owner"
        );
        assertEq(
            _getProxyAdmin(address(rollup.challengeManager())),
            proxyAdminExpectedAddress,
            "Invalid challengeManager's proxyAdmin owner"
        );

        // check upgrade executor owns proxyAdmin
        address upgradeExecutorExpectedAddress = computeCreateAddress(address(rollupCreator), 2);
        assertEq(
            ProxyAdmin(_getProxyAdmin(address(rollup.sequencerInbox()))).owner(),
            upgradeExecutorExpectedAddress,
            "Invalid proxyAdmin's owner"
        );

        // upgrade executor owns rollup
        assertEq(
            IOwnable(rollupAddress).owner(), upgradeExecutorExpectedAddress, "Invalid rollup owner"
        );
        assertEq(
            _getProxyAdmin(rollupAddress),
            upgradeExecutorExpectedAddress,
            "Invalid rollup's proxyAdmin owner"
        );

        // check rollupOwner has executor role
        UpgradeExecutor executor = UpgradeExecutor(upgradeExecutorExpectedAddress);
        assertTrue(
            executor.hasRole(keccak256("EXECUTOR_ROLE"), rollupOwner), "Invalid executor role"
        );
    }

    function test_upgrade() public {
        vm.startPrank(deployer);

        // deployment params
        ISequencerInbox.MaxTimeVariation memory timeVars =
            ISequencerInbox.MaxTimeVariation(((60 * 60 * 24) / 15), 12, 60 * 60 * 24, 60 * 60);
        Config memory config = Config({
            confirmPeriodBlocks: 20,
            extraChallengeTimeBlocks: 200,
            stakeToken: address(0),
            baseStake: 1000,
            wasmModuleRoot: keccak256("wasm"),
            owner: rollupOwner,
            loserStakeEscrow: address(200),
            chainId: 1337,
            chainConfig: "abc",
            genesisBlockNum: 15_000_000,
            sequencerInboxMaxTimeVariation: timeVars
        });

        /// deploy rollup
        address batchPoster = makeAddr("batch poster");
        address[] memory validators = new address[](2);
        validators[0] = makeAddr("validator1");
        validators[1] = makeAddr("validator2");
        address rollupAddress =
            rollupCreator.createRollup(config, batchPoster, validators, address(0));

        vm.stopPrank();

        //// upgrade inbox
        RollupCore rollup = RollupCore(rollupAddress);
        address inbox = address(rollup.inbox());
        address proxyAdmin = computeCreateAddress(address(rollupCreator), 1);
        UpgradeExecutor upgradeExecutor =
            UpgradeExecutor(computeCreateAddress(address(rollupCreator), 2));

        Dummy newLogicImpl = new Dummy();
        bytes memory data = abi.encodeWithSelector(
            ProxyUpgradeAction.perform.selector, address(proxyAdmin), inbox, address(newLogicImpl)
        );

        address upgradeAction = address(new ProxyUpgradeAction());
        vm.prank(rollupOwner);
        upgradeExecutor.execute(upgradeAction, data);

        // check upgrade was successful
        assertEq(_getImpl(inbox), address(newLogicImpl));
    }

    function _prepareRollupDeployment()
        internal
        returns (
            IOneStepProofEntry ospEntry,
            IChallengeManager challengeManager,
            IRollupAdmin rollupAdminLogic,
            IRollupUser rollupUserLogic
        )
    {
        //// deploy challenge stuff
        ospEntry = new OneStepProofEntry(
            new OneStepProver0(),
            new OneStepProverMemory(),
            new OneStepProverMath(),
            new OneStepProverHostIo()
        );
        challengeManager = new ChallengeManager();

        //// deploy rollup logic
        rollupAdminLogic = IRollupAdmin(new RollupAdminLogic());
        rollupUserLogic = IRollupUser(new RollupUserLogic());

        return (ospEntry, challengeManager, rollupAdminLogic, rollupUserLogic);
    }

    function _getProxyAdmin(address proxy) internal view returns (address) {
        bytes32 adminSlot = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
        return address(uint160(uint256(vm.load(proxy, adminSlot))));
    }

    function _getImpl(address proxy) internal view returns (address) {
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        return address(uint160(uint256(vm.load(proxy, implSlot))));
    }

    function _getPrimary(address proxy) internal view returns (address) {
        bytes32 primarySlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        return address(uint160(uint256(vm.load(proxy, primarySlot))));
    }

    function _getSecondary(address proxy) internal view returns (address) {
        bytes32 secondarySlot =
            bytes32(uint256(keccak256("eip1967.proxy.implementation.secondary")) - 1);
        return address(uint160(uint256(vm.load(proxy, secondarySlot))));
    }
}

contract ProxyUpgradeAction {
    function perform(address admin, address payable target, address newLogic) public payable {
        ProxyAdmin(admin).upgrade(TransparentUpgradeableProxy(target), newLogic);
    }
}

contract Dummy {
    function dummy() public {}
}
