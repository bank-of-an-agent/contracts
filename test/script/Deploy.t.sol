// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {AgentAttestationRegistry} from "../../src/AgentAttestationRegistry.sol";
import {AgentClaimsVerifier} from "../../src/AgentClaimsVerifier.sol";
import {AgentEscrow} from "../../src/AgentEscrow.sol";
import {AgentPolicyHook} from "../../src/AgentPolicyHook.sol";
import {PaymentStreams} from "../../src/PaymentStreams.sol";
import {SweepExecutor} from "../../src/SweepExecutor.sol";
import {TimeLockVaults} from "../../src/TimeLockVaults.sol";
import {TopUpExecutor} from "../../src/TopUpExecutor.sol";
import {MockTreasuryFund} from "../../src/mocks/MockTreasuryFund.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {AgentClaimsGroth16Verifier} from "../../src/verifiers/AgentClaimsGroth16Verifier.sol";

contract DeployScriptTest is Test {
    /// @dev Runtime code of the canonical deterministic-deployment proxy (Arachnid), present on Anvil and Base.
    bytes internal constant CREATE2_FACTORY_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";
    address internal constant BASE_SEPOLIA_VALIDATION_REGISTRY = 0x8004Cb1BF31DAf7788923b405b754f57acEB4272;
    address internal constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    Deploy internal script;

    function setUp() public {
        if (CREATE2_FACTORY.code.length == 0) vm.etch(CREATE2_FACTORY, CREATE2_FACTORY_CODE);
        script = new Deploy();
    }

    function test_run_onAnvil_deploysEverythingIncludingMocks() public {
        vm.chainId(31_337);
        Deploy.Deployment memory d = script.run();
        address[13] memory all = [
            d.usdc,
            d.validationRegistry,
            d.treasuryFund,
            d.agentEscrow,
            d.paymentStreams,
            d.agentPolicyHook,
            d.timeLockVaults,
            d.sweepExecutor,
            d.topUpExecutor,
            d.agentClaimsGroth16Verifier,
            d.agentAttestationRegistry,
            d.agentClaimsVerifier,
            CREATE2_FACTORY
        ];
        for (uint256 i; i < all.length; ++i) {
            assertGt(all[i].code.length, 0);
        }
        assertEq(address(AgentEscrow(d.agentEscrow).VALIDATION_REGISTRY()), d.validationRegistry);
        assertEq(address(MockTreasuryFund(d.treasuryFund).asset()), d.usdc);
        assertEq(MockUSDC(d.usdc).decimals(), 6);
        assertEq(d.pauseGuardian, address(0));
        assertEq(AgentEscrow(d.agentEscrow).pauseGuardian(), address(0));
    }

    function test_run_isIdempotent() public {
        vm.chainId(31_337);
        Deploy.Deployment memory first = script.run();
        Deploy.Deployment memory second = script.run();
        assertEq(abi.encode(first), abi.encode(second));
    }

    function test_run_onBaseSepolia_usesRealUsdcAndRegistry_noMocks() public {
        vm.chainId(84_532);
        vm.etch(BASE_SEPOLIA_VALIDATION_REGISTRY, hex"00"); // stands in for the deployed registry proxy
        Deploy.Deployment memory d = script.run();
        assertEq(d.usdc, BASE_SEPOLIA_USDC);
        assertEq(d.validationRegistry, BASE_SEPOLIA_VALIDATION_REGISTRY);
        assertEq(d.treasuryFund, address(0));
        assertEq(address(AgentEscrow(d.agentEscrow).VALIDATION_REGISTRY()), BASE_SEPOLIA_VALIDATION_REGISTRY);
    }

    /// @notice The private-proofs contracts are wired together; owner and attester default to the script sender.
    function test_run_deploysPrivateProofs() public {
        vm.chainId(84_532);
        vm.etch(BASE_SEPOLIA_VALIDATION_REGISTRY, hex"00");
        Deploy.Deployment memory d = script.run();
        AgentAttestationRegistry registry = AgentAttestationRegistry(d.agentAttestationRegistry);
        AgentClaimsVerifier verifier = AgentClaimsVerifier(d.agentClaimsVerifier);
        assertEq(d.proofsRegistryOwner, address(this), "default owner: script sender");
        assertEq(d.proofsAttester, address(this), "default attester: script sender");
        assertEq(registry.owner(), d.proofsRegistryOwner);
        assertEq(registry.attester(), d.proofsAttester);
        assertEq(registry.latestEpoch(), 0);
        assertEq(verifier.registry(), d.agentAttestationRegistry);
        assertEq(verifier.groth16Verifier(), d.agentClaimsGroth16Verifier);
        assertGt(d.agentClaimsGroth16Verifier.code.length, 0);
    }

    function test_run_refusesBaseMainnet() public {
        vm.chainId(8453);
        vm.expectRevert(bytes("MAINNET_LOCKED"));
        script.run();
    }

    function test_run_refusesOtherChains() public {
        uint256[4] memory chains = [uint256(1), 10, 11_155_111, 42_161];
        for (uint256 i; i < chains.length; ++i) {
            vm.chainId(chains[i]);
            vm.expectRevert(bytes("UNSUPPORTED_CHAIN"));
            script.run();
        }
    }

    function test_run_requiresCreate2Factory() public {
        vm.chainId(31_337);
        vm.etch(CREATE2_FACTORY, "");
        vm.expectRevert(bytes("CREATE2_FACTORY_MISSING"));
        script.run();
    }

    function test_addresses_areDeterministic() public {
        vm.chainId(31_337);
        Deploy.Deployment memory d = script.run();
        string memory ns = "agentbank.contracts.v1";
        assertEq(d.agentPolicyHook, script.predict(ns, "AgentPolicyHook", type(AgentPolicyHook).creationCode));
        assertEq(d.sweepExecutor, script.predict(ns, "SweepExecutor", type(SweepExecutor).creationCode));
        assertEq(d.topUpExecutor, script.predict(ns, "TopUpExecutor", type(TopUpExecutor).creationCode));
        assertEq(
            d.paymentStreams,
            script.predict(
                ns, "PaymentStreams", abi.encodePacked(type(PaymentStreams).creationCode, abi.encode(address(0)))
            )
        );
        assertEq(
            d.timeLockVaults,
            script.predict(
                ns, "TimeLockVaults", abi.encodePacked(type(TimeLockVaults).creationCode, abi.encode(address(0)))
            )
        );
        assertEq(
            d.agentEscrow,
            script.predict(
                ns,
                "AgentEscrow",
                abi.encodePacked(type(AgentEscrow).creationCode, abi.encode(address(0), d.validationRegistry))
            )
        );
        assertEq(
            d.agentClaimsGroth16Verifier,
            script.predict(ns, "AgentClaimsGroth16Verifier", type(AgentClaimsGroth16Verifier).creationCode)
        );
        assertEq(
            d.agentAttestationRegistry,
            script.predict(
                ns,
                "AgentAttestationRegistry",
                abi.encodePacked(type(AgentAttestationRegistry).creationCode, abi.encode(address(this), address(this)))
            )
        );
        assertEq(
            d.agentClaimsVerifier,
            script.predict(
                ns,
                "AgentClaimsVerifier",
                abi.encodePacked(
                    type(AgentClaimsVerifier).creationCode,
                    abi.encode(d.agentAttestationRegistry, d.agentClaimsGroth16Verifier)
                )
            )
        );
        assertEq(script.saltFor(ns, "AgentClaimsVerifier"), keccak256("agentbank.contracts.v1/AgentClaimsVerifier"));
    }

    /// @notice Modules without constructor args land at the same address on Anvil and Base Sepolia.
    function test_moduleAddresses_areChainIndependent() public {
        vm.chainId(31_337);
        Deploy.Deployment memory anvil = script.run();
        vm.chainId(84_532);
        vm.etch(BASE_SEPOLIA_VALIDATION_REGISTRY, hex"00");
        Deploy.Deployment memory sepolia = script.run();
        assertEq(anvil.agentPolicyHook, sepolia.agentPolicyHook);
        assertEq(anvil.sweepExecutor, sepolia.sweepExecutor);
        assertEq(anvil.topUpExecutor, sepolia.topUpExecutor);
        assertEq(anvil.paymentStreams, sepolia.paymentStreams);
        assertEq(anvil.timeLockVaults, sepolia.timeLockVaults);
        assertEq(anvil.agentClaimsGroth16Verifier, sepolia.agentClaimsGroth16Verifier);
        assertEq(anvil.agentAttestationRegistry, sepolia.agentAttestationRegistry, "same owner and attester");
        assertEq(anvil.agentClaimsVerifier, sepolia.agentClaimsVerifier);
        assertTrue(anvil.agentEscrow != sepolia.agentEscrow, "escrow depends on the chain's registry");
    }
}
