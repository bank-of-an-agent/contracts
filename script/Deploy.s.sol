// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, VmSafe, console2} from "forge-std/Script.sol";

import {AgentAttestationRegistry} from "../src/AgentAttestationRegistry.sol";
import {AgentClaimsVerifier} from "../src/AgentClaimsVerifier.sol";
import {AgentEscrow} from "../src/AgentEscrow.sol";
import {AgentPolicyHook} from "../src/AgentPolicyHook.sol";
import {PaymentStreams} from "../src/PaymentStreams.sol";
import {SweepExecutor} from "../src/SweepExecutor.sol";
import {TimeLockVaults} from "../src/TimeLockVaults.sol";
import {TopUpExecutor} from "../src/TopUpExecutor.sol";
import {MockTreasuryFund} from "../src/mocks/MockTreasuryFund.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockValidationRegistry} from "../src/mocks/MockValidationRegistry.sol";
import {AgentClaimsGroth16Verifier} from "../src/verifiers/AgentClaimsGroth16Verifier.sol";

/// @title Deploy
/// @notice Deterministic CREATE2 deployment of the Agent Bank contracts through the canonical deterministic-deployment
///         proxy (0x4e59b44847b379578588920cA78FbF26c0B4956C). Base mainnet is refused; only Base Sepolia (84532) and
///         local Anvil (31337) are supported. Mocks (MockUSDC, MockValidationRegistry, MockTreasuryFund) are deployed
///         only on Anvil. Re-running is idempotent: contracts already at their predicted address are skipped.
///
///         Usage (simulation only; broadcasting is a human decision):
///           anvil &  forge script script/Deploy.s.sol --rpc-url anvil
///           forge script script/Deploy.s.sol --rpc-url base_sepolia
///         A broadcast writes `deployments/<chainId>.json`; a simulation writes `deployments/<chainId>.dry-run.json`.
///
///         Environment (all optional):
///           PAUSE_GUARDIAN         inflow-only pause guardian for escrow/streams/vaults (default: none)
///           VALIDATION_REGISTRY    ERC-8004 Validation Registry for the escrow (Base Sepolia default below;
///                                  address(0) disables the validator path)
///           DEPLOY_SALT_NAMESPACE  CREATE2 salt namespace (default "agentbank.contracts.v1")
///           MOCK_ADMIN             Anvil only: MockUSDC blacklister / MockTreasuryFund admin (default: script sender)
///           PROOFS_REGISTRY_OWNER  AgentAttestationRegistry owner, a governance multisig (default: script sender)
///           PROOFS_ATTESTER        Agent Bank's root-publishing attester key (default: script sender)
/// @dev Addresses are a pure function of (factory, salt, init code). Init code = creation bytecode (pinned compiler and
///      settings in foundry.toml, no CBOR metadata) + constructor args. AgentPolicyHook, SweepExecutor,
///      TopUpExecutor and AgentClaimsGroth16Verifier have no constructor args, so their addresses are identical on
///      every chain; AgentEscrow, PaymentStreams and TimeLockVaults also depend on PAUSE_GUARDIAN, AgentEscrow on the
///      validation registry, and AgentAttestationRegistry (hence AgentClaimsVerifier) on PROOFS_REGISTRY_OWNER and
///      PROOFS_ATTESTER.
contract Deploy is Script {
    uint256 internal constant BASE_MAINNET = 8453;
    uint256 internal constant BASE_SEPOLIA = 84_532;
    uint256 internal constant ANVIL = 31_337;

    /// @dev Circle USDC (FiatToken v2.2) on Base Sepolia.
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    /// @dev ERC-8004 Validation Registry v2.0.0 (UUPS proxy) on Base Sepolia.
    address internal constant BASE_SEPOLIA_VALIDATION_REGISTRY = 0x8004Cb1BF31DAf7788923b405b754f57acEB4272;
    string internal constant DEFAULT_SALT_NAMESPACE = "agentbank.contracts.v1";

    struct Deployment {
        uint256 chainId;
        address pauseGuardian;
        address usdc;
        address validationRegistry;
        address treasuryFund; // Anvil mock only (owners pick real funds themselves)
        address agentEscrow;
        address paymentStreams;
        address agentPolicyHook;
        address timeLockVaults;
        address sweepExecutor;
        address topUpExecutor;
        address proofsRegistryOwner;
        address proofsAttester;
        address agentClaimsGroth16Verifier;
        address agentAttestationRegistry;
        address agentClaimsVerifier;
    }

    /// @notice Deploys (or finds) every contract and records the addresses.
    /// @return d The deployment.
    function run() external returns (Deployment memory d) {
        _guardChain();
        d.chainId = block.chainid;
        d.pauseGuardian = vm.envOr("PAUSE_GUARDIAN", address(0));
        string memory namespace = vm.envOr("DEPLOY_SALT_NAMESPACE", DEFAULT_SALT_NAMESPACE);
        require(CREATE2_FACTORY.code.length != 0, "CREATE2_FACTORY_MISSING");

        vm.startBroadcast();
        if (block.chainid == ANVIL) {
            address mockAdmin = vm.envOr("MOCK_ADMIN", msg.sender);
            d.usdc =
                _deploy(namespace, "MockUSDC", abi.encodePacked(type(MockUSDC).creationCode, abi.encode(mockAdmin)));
            d.validationRegistry =
                _deploy(namespace, "MockValidationRegistry", type(MockValidationRegistry).creationCode);
            d.treasuryFund = _deploy(
                namespace,
                "MockTreasuryFund",
                abi.encodePacked(type(MockTreasuryFund).creationCode, abi.encode(IERC20(d.usdc), mockAdmin))
            );
        } else {
            d.usdc = BASE_SEPOLIA_USDC;
            d.validationRegistry = vm.envOr("VALIDATION_REGISTRY", BASE_SEPOLIA_VALIDATION_REGISTRY);
        }
        d.agentEscrow = _deploy(namespace, "AgentEscrow", _escrowInitCode(d.pauseGuardian, d.validationRegistry));
        d.paymentStreams = _deploy(
            namespace,
            "PaymentStreams",
            abi.encodePacked(type(PaymentStreams).creationCode, abi.encode(d.pauseGuardian))
        );
        d.timeLockVaults = _deploy(
            namespace,
            "TimeLockVaults",
            abi.encodePacked(type(TimeLockVaults).creationCode, abi.encode(d.pauseGuardian))
        );
        d.agentPolicyHook = _deploy(namespace, "AgentPolicyHook", type(AgentPolicyHook).creationCode);
        d.sweepExecutor = _deploy(namespace, "SweepExecutor", type(SweepExecutor).creationCode);
        d.topUpExecutor = _deploy(namespace, "TopUpExecutor", type(TopUpExecutor).creationCode);
        _deployProofs(d, namespace);
        vm.stopBroadcast();

        _record(d, namespace);
    }

    /// @notice CREATE2 salt for `name` under `namespace`.
    /// @param namespace Salt namespace.
    /// @param name Contract name.
    function saltFor(string memory namespace, string memory name) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(namespace, "/", name));
    }

    /// @notice Address `initCode` deploys to under `namespace`/`name` through the CREATE2 factory.
    /// @param namespace Salt namespace.
    /// @param name Contract name.
    /// @param initCode Creation bytecode plus ABI-encoded constructor arguments.
    function predict(string memory namespace, string memory name, bytes memory initCode) public pure returns (address) {
        return vm.computeCreate2Address(saltFor(namespace, name), keccak256(initCode), CREATE2_FACTORY);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------------------------

    function _guardChain() internal view {
        require(block.chainid != BASE_MAINNET, "MAINNET_LOCKED");
        require(block.chainid == BASE_SEPOLIA || block.chainid == ANVIL, "UNSUPPORTED_CHAIN");
    }

    /// @dev Private proofs: the generated Groth16 verifier, the root registry and the claims verifier wrapping both.
    function _deployProofs(Deployment memory d, string memory namespace) internal {
        d.proofsRegistryOwner = vm.envOr("PROOFS_REGISTRY_OWNER", msg.sender);
        d.proofsAttester = vm.envOr("PROOFS_ATTESTER", msg.sender);
        d.agentClaimsGroth16Verifier =
            _deploy(namespace, "AgentClaimsGroth16Verifier", type(AgentClaimsGroth16Verifier).creationCode);
        d.agentAttestationRegistry = _deploy(
            namespace,
            "AgentAttestationRegistry",
            abi.encodePacked(
                type(AgentAttestationRegistry).creationCode, abi.encode(d.proofsRegistryOwner, d.proofsAttester)
            )
        );
        d.agentClaimsVerifier = _deploy(
            namespace,
            "AgentClaimsVerifier",
            abi.encodePacked(
                type(AgentClaimsVerifier).creationCode,
                abi.encode(d.agentAttestationRegistry, d.agentClaimsGroth16Verifier)
            )
        );
    }

    function _escrowInitCode(address pauseGuardian, address registry) internal pure returns (bytes memory) {
        return abi.encodePacked(type(AgentEscrow).creationCode, abi.encode(pauseGuardian, registry));
    }

    function _deploy(string memory namespace, string memory name, bytes memory initCode)
        internal
        returns (address deployed)
    {
        bytes32 salt = saltFor(namespace, name);
        deployed = vm.computeCreate2Address(salt, keccak256(initCode), CREATE2_FACTORY);
        if (deployed.code.length != 0) {
            console2.log(string.concat("[found]  ", name), deployed);
            return deployed;
        }
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, initCode));
        require(ok && deployed.code.length != 0, string.concat("CREATE2_DEPLOY_FAILED: ", name));
        console2.log(string.concat("[deploy] ", name), deployed);
    }

    /// @dev Broadcast → deployments/<chainId>.json; simulation → deployments/<chainId>.dry-run.json; tests → nothing.
    function _record(Deployment memory d, string memory namespace) internal {
        bool broadcast =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (!broadcast && !vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) return;

        string memory contracts = "contracts";
        vm.serializeAddress(contracts, "AgentEscrow", d.agentEscrow);
        vm.serializeAddress(contracts, "PaymentStreams", d.paymentStreams);
        vm.serializeAddress(contracts, "AgentPolicyHook", d.agentPolicyHook);
        vm.serializeAddress(contracts, "TimeLockVaults", d.timeLockVaults);
        vm.serializeAddress(contracts, "SweepExecutor", d.sweepExecutor);
        vm.serializeAddress(contracts, "TopUpExecutor", d.topUpExecutor);
        vm.serializeAddress(contracts, "AgentClaimsGroth16Verifier", d.agentClaimsGroth16Verifier);
        vm.serializeAddress(contracts, "AgentAttestationRegistry", d.agentAttestationRegistry);
        string memory contractsJson = vm.serializeAddress(contracts, "AgentClaimsVerifier", d.agentClaimsVerifier);

        string memory deps = "dependencies";
        vm.serializeAddress(deps, "USDC", d.usdc);
        if (d.treasuryFund != address(0)) vm.serializeAddress(deps, "MockTreasuryFund", d.treasuryFund);
        string memory depsJson = vm.serializeAddress(deps, "ERC8004ValidationRegistry", d.validationRegistry);

        string memory root = "deployment";
        vm.serializeUint(root, "chainId", d.chainId);
        vm.serializeString(root, "mode", broadcast ? "broadcast" : "dry-run");
        vm.serializeAddress(root, "create2Factory", CREATE2_FACTORY);
        vm.serializeString(root, "saltNamespace", namespace);
        vm.serializeAddress(root, "pauseGuardian", d.pauseGuardian);
        vm.serializeAddress(root, "proofsRegistryOwner", d.proofsRegistryOwner);
        vm.serializeAddress(root, "proofsAttester", d.proofsAttester);
        vm.serializeString(root, "dependencies", depsJson);
        string memory json = vm.serializeString(root, "contracts", contractsJson);

        string memory path = string.concat(
            vm.projectRoot(), "/deployments/", vm.toString(block.chainid), broadcast ? ".json" : ".dry-run.json"
        );
        vm.writeJson(json, path);
        console2.log("recorded", path);
    }
}
