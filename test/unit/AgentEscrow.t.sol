// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {AgentEscrow} from "../../src/AgentEscrow.sol";
import {IAgentEscrow} from "../../src/interfaces/IAgentEscrow.sol";
import {MockValidationRegistry} from "../../src/mocks/MockValidationRegistry.sol";
import {GuardianPausable} from "../../src/utils/GuardianPausable.sol";
import {TokenTransfer} from "../../src/utils/TokenTransfer.sol";
import {
    CallbackToken,
    FalseReturnToken,
    FeeOnTransferToken,
    ReverseTransferToken,
    TestToken
} from "../mocks/TestTokens.sol";
import {BaseTest} from "../utils/BaseTest.sol";

contract AgentEscrowTest is BaseTest {
    AgentEscrow internal escrow;
    MockValidationRegistry internal registry;

    uint256 internal constant AMOUNT = 250 * USDC_UNIT;
    bytes32 internal constant TERMS = keccak256("terms: summarise 40 PDFs");
    bytes32 internal constant REQUEST = keccak256("erc8004 request: summary quality");
    uint64 internal expiry;

    function setUp() public override {
        super.setUp();
        registry = new MockValidationRegistry();
        escrow = new AgentEscrow(guardian, address(registry));
        expiry = uint64(block.timestamp + 7 days);
        _fundAndApprove(payer, address(escrow), 1_000_000 * USDC_UNIT);
    }

    // ------------------------------------------------------------------ helpers

    function _lock(address arbiter_) internal returns (uint256) {
        vm.prank(payer);
        return escrow.lock(address(usdc), payee, AMOUNT, expiry, arbiter_, address(0), bytes32(0), 0, TERMS);
    }

    function _lockWithValidator(uint8 threshold) internal returns (uint256) {
        vm.prank(payer);
        return escrow.lock(address(usdc), payee, AMOUNT, expiry, arbiter, validator, REQUEST, threshold, TERMS);
    }

    function _requestAndRespond(bytes32 requestHash, address validator_, uint8 response) internal {
        registry.validationRequest(validator_, 42, "ipfs://request", requestHash);
        vm.prank(validator_);
        registry.validationResponse(requestHash, response, "ipfs://response", keccak256("response"), "quality");
    }

    function _status(uint256 id) internal view returns (IAgentEscrow.Status) {
        return escrow.getEscrow(id).status;
    }

    // ------------------------------------------------------------------ construction

    function test_constructor_setsImmutablesAndGuardian() public view {
        assertEq(address(escrow.VALIDATION_REGISTRY()), address(registry));
        assertEq(escrow.pauseGuardian(), guardian);
        assertFalse(escrow.paused());
        assertEq(escrow.DISPUTE_TIMEOUT(), 30 days);
        assertEq(escrow.MAX_ESCROW_DURATION(), 365 days);
        assertEq(escrow.escrowCount(), 0);
    }

    function test_constructor_allowsNoRegistryAndNoGuardian() public {
        AgentEscrow bare = new AgentEscrow(address(0), address(0));
        assertEq(address(bare.VALIDATION_REGISTRY()), address(0));
        assertEq(bare.pauseGuardian(), address(0));
    }

    function test_constructor_rejectsRegistryWithoutCode() public {
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidValidationRegistry.selector, stranger));
        new AgentEscrow(guardian, stranger);
    }

    // ------------------------------------------------------------------ lock

    function test_lock_storesEscrowPullsFundsAndEmits() public {
        uint256 payerBefore = usdc.balanceOf(payer);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrow.Locked(1, payer, payee, address(usdc), AMOUNT, expiry, arbiter, TERMS);
        uint256 id = _lock(arbiter);

        assertEq(id, 1);
        assertEq(escrow.escrowCount(), 1);
        IAgentEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(e.payer, payer);
        assertEq(e.payee, payee);
        assertEq(e.token, address(usdc));
        assertEq(e.amount, AMOUNT);
        assertEq(e.expiresAt, expiry);
        assertEq(e.createdAt, block.timestamp);
        assertEq(e.arbiter, arbiter);
        assertEq(e.validator, address(0));
        assertEq(e.validationRequestHash, bytes32(0));
        assertEq(e.validationThreshold, 0);
        assertEq(e.termsHash, TERMS);
        assertEq(uint8(e.status), uint8(IAgentEscrow.Status.Active));
        assertEq(usdc.balanceOf(address(escrow)), AMOUNT);
        assertEq(usdc.balanceOf(payer), payerBefore - AMOUNT);
        assertEq(escrow.totalLocked(address(usdc)), AMOUNT);
        assertEq(escrow.refundableAt(id), expiry);
    }

    function test_lock_withValidator_storesAndEmitsValidationConfig() public {
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrow.ValidationConfigured(1, validator, REQUEST, 80);
        uint256 id = _lockWithValidator(80);
        IAgentEscrow.Escrow memory e = escrow.getEscrow(id);
        assertEq(e.validator, validator);
        assertEq(e.validationRequestHash, REQUEST);
        assertEq(e.validationThreshold, 80);
    }

    function test_lock_idsIncrementAndTotalsPerToken() public {
        TestToken other = new TestToken("Other", "OTH");
        other.mint(payer, 10 ether);
        vm.prank(payer);
        other.approve(address(escrow), type(uint256).max);

        _lock(address(0));
        vm.prank(payer);
        uint256 id2 =
            escrow.lock(address(other), payee, 3 ether, expiry, address(0), address(0), bytes32(0), 0, bytes32(0));
        _lock(address(0));

        assertEq(id2, 2);
        assertEq(escrow.escrowCount(), 3);
        assertEq(escrow.totalLocked(address(usdc)), 2 * AMOUNT);
        assertEq(escrow.totalLocked(address(other)), 3 ether);
    }

    function test_lock_revertsOnInvalidParams() public {
        vm.startPrank(payer);
        vm.expectRevert(IAgentEscrow.ZeroAddress.selector);
        escrow.lock(address(0), payee, AMOUNT, expiry, address(0), address(0), 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidPayee.selector, address(0)));
        escrow.lock(address(usdc), address(0), AMOUNT, expiry, address(0), address(0), 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidPayee.selector, payer));
        escrow.lock(address(usdc), payer, AMOUNT, expiry, address(0), address(0), 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidPayee.selector, address(escrow)));
        escrow.lock(address(usdc), address(escrow), AMOUNT, expiry, address(0), address(0), 0, 0, 0);

        vm.expectRevert(IAgentEscrow.InvalidAmount.selector);
        escrow.lock(address(usdc), payee, 0, expiry, address(0), address(0), 0, 0, 0);

        uint64 nowTs = uint64(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidExpiry.selector, nowTs));
        escrow.lock(address(usdc), payee, AMOUNT, nowTs, address(0), address(0), 0, 0, 0);
        uint64 tooFar = nowTs + 365 days + 1;
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidExpiry.selector, tooFar));
        escrow.lock(address(usdc), payee, AMOUNT, tooFar, address(0), address(0), 0, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidArbiter.selector, payer));
        escrow.lock(address(usdc), payee, AMOUNT, expiry, payer, address(0), 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidArbiter.selector, payee));
        escrow.lock(address(usdc), payee, AMOUNT, expiry, payee, address(0), 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidArbiter.selector, address(escrow)));
        escrow.lock(address(usdc), payee, AMOUNT, expiry, address(escrow), address(0), 0, 0, 0);
        vm.stopPrank();
    }

    function test_lock_acceptsMaxDurationBoundary() public {
        vm.prank(payer);
        uint256 id = escrow.lock(
            address(usdc), payee, AMOUNT, uint64(block.timestamp + 365 days), address(0), address(0), 0, 0, 0
        );
        assertEq(escrow.getEscrow(id).expiresAt, block.timestamp + 365 days);
    }

    function test_lock_revertsOnInvalidValidationConfig() public {
        vm.startPrank(payer);
        // no validator but leftover fields
        vm.expectRevert(IAgentEscrow.InvalidValidationConfig.selector);
        escrow.lock(address(usdc), payee, AMOUNT, expiry, address(0), address(0), REQUEST, 0, 0);
        vm.expectRevert(IAgentEscrow.InvalidValidationConfig.selector);
        escrow.lock(address(usdc), payee, AMOUNT, expiry, address(0), address(0), 0, 50, 0);
        // validator set but missing hash / bad thresholds
        vm.expectRevert(IAgentEscrow.InvalidValidationConfig.selector);
        escrow.lock(address(usdc), payee, AMOUNT, expiry, address(0), validator, 0, 50, 0);
        vm.expectRevert(IAgentEscrow.InvalidValidationConfig.selector);
        escrow.lock(address(usdc), payee, AMOUNT, expiry, address(0), validator, REQUEST, 0, 0);
        vm.expectRevert(IAgentEscrow.InvalidValidationConfig.selector);
        escrow.lock(address(usdc), payee, AMOUNT, expiry, address(0), validator, REQUEST, 101, 0);
        // self-validation by the payee
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidValidator.selector, payee));
        escrow.lock(address(usdc), payee, AMOUNT, expiry, address(0), payee, REQUEST, 50, 0);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidValidator.selector, address(escrow)));
        escrow.lock(address(usdc), payee, AMOUNT, expiry, address(0), address(escrow), REQUEST, 50, 0);
        vm.stopPrank();
    }

    function test_lock_validatorRequiresRegistry() public {
        AgentEscrow bare = new AgentEscrow(address(0), address(0));
        _fundAndApprove(payer, address(bare), AMOUNT);
        vm.prank(payer);
        vm.expectRevert(IAgentEscrow.ValidationUnsupported.selector);
        bare.lock(address(usdc), payee, AMOUNT, expiry, address(0), validator, REQUEST, 50, 0);
    }

    function test_lock_rejectsFeeOnTransferToken() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        fot.mint(payer, 1000);
        vm.startPrank(payer);
        fot.approve(address(escrow), 1000);
        vm.expectRevert(abi.encodeWithSelector(TokenTransfer.TransferAmountMismatch.selector, address(fot), 1000, 990));
        escrow.lock(address(fot), payee, 1000, expiry, address(0), address(0), 0, 0, 0);
        vm.stopPrank();
    }

    function test_lock_rejectsTokenWhoseTransferShrinksReceiver() public {
        ReverseTransferToken rev = new ReverseTransferToken();
        rev.mint(address(escrow), 1000); // e.g. an earlier donation
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(TokenTransfer.TransferAmountMismatch.selector, address(rev), 1000, 0));
        escrow.lock(address(rev), payee, 1000, expiry, address(0), address(0), 0, 0, 0);
    }

    function test_lock_rejectsFalseReturningToken() public {
        FalseReturnToken bad = new FalseReturnToken();
        bad.mint(payer, 1000);
        bad.setFailTransfers(true);
        vm.startPrank(payer);
        bad.approve(address(escrow), 1000);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        escrow.lock(address(bad), payee, 1000, expiry, address(0), address(0), 0, 0, 0);
        vm.stopPrank();
    }

    function test_lock_revertsWithoutAllowanceOrBalance() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(escrow), 0, AMOUNT)
        );
        escrow.lock(address(usdc), payee, AMOUNT, expiry, address(0), address(0), 0, 0, 0);
    }

    // ------------------------------------------------------------------ pause guardian

    function test_pause_blocksOnlyNewLocks_neverExits() public {
        uint256 releasable = _lock(arbiter);
        uint256 refundable = _lock(arbiter);
        uint256 disputed = _lock(arbiter);
        vm.prank(payee);
        escrow.dispute(disputed);

        vm.prank(guardian);
        escrow.pause();

        vm.prank(payer);
        vm.expectRevert(GuardianPausable.NewDepositsPaused.selector);
        escrow.lock(address(usdc), payee, AMOUNT, expiry, address(0), address(0), 0, 0, 0);

        // every exit still works while paused
        vm.prank(payer);
        escrow.release(releasable);
        vm.prank(payee);
        escrow.refund(refundable);
        vm.prank(arbiter);
        escrow.resolve(disputed, AMOUNT / 2);
        assertEq(escrow.totalLocked(address(usdc)), 0);

        vm.prank(guardian);
        escrow.unpause();
        _lock(address(0));
    }

    function test_pause_onlyGuardian() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GuardianPausable.NotPauseGuardian.selector, stranger));
        escrow.pause();
    }

    // ------------------------------------------------------------------ release

    function test_release_byPayer() public {
        uint256 id = _lock(arbiter);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrow.Released(id, payee, payer, address(usdc), AMOUNT, IAgentEscrow.ReleaseReason.PayerApproval);
        vm.prank(payer);
        escrow.release(id);
        assertEq(usdc.balanceOf(payee), AMOUNT);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(escrow.totalLocked(address(usdc)), 0);
        assertEq(uint8(_status(id)), uint8(IAgentEscrow.Status.Released));
        assertEq(escrow.refundableAt(id), 0);
    }

    function test_release_byArbiter_evenAfterExpiry() public {
        uint256 id = _lock(arbiter);
        vm.warp(expiry + 10 days);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrow.Released(
            id, payee, arbiter, address(usdc), AMOUNT, IAgentEscrow.ReleaseReason.ArbiterDecision
        );
        vm.prank(arbiter);
        escrow.release(id);
        assertEq(usdc.balanceOf(payee), AMOUNT);
    }

    function test_release_whileDisputed_byPayerOrArbiter() public {
        uint256 a = _lock(arbiter);
        uint256 b = _lock(arbiter);
        vm.prank(payee);
        escrow.dispute(a);
        vm.prank(payer);
        escrow.dispute(b);
        vm.prank(payer);
        escrow.release(a);
        vm.prank(arbiter);
        escrow.release(b);
        assertEq(usdc.balanceOf(payee), 2 * AMOUNT);
    }

    function test_release_revertsForOthers() public {
        uint256 id = _lock(arbiter);
        address[3] memory callers = [payee, stranger, validator];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.Unauthorized.selector, callers[i]));
            escrow.release(id);
        }
    }

    function test_release_withoutArbiter_onlyPayer() public {
        uint256 id = _lock(address(0));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.Unauthorized.selector, stranger));
        escrow.release(id);
        vm.prank(payer);
        escrow.release(id);
    }

    function test_release_revertsOnTerminalOrUnknown() public {
        uint256 id = _lock(arbiter);
        vm.prank(payer);
        escrow.release(id);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidStatus.selector, id, IAgentEscrow.Status.Released));
        escrow.release(id);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidStatus.selector, 99, IAgentEscrow.Status.None));
        escrow.release(99);
    }

    // ------------------------------------------------------------------ releaseByValidation

    function test_releaseByValidation_happyPath_anyoneCanTrigger() public {
        uint256 id = _lockWithValidator(80);
        vm.warp(block.timestamp + 1 hours);
        _requestAndRespond(REQUEST, validator, 95);

        (bool ok, bytes memory reason) = escrow.checkValidation(id);
        assertTrue(ok);
        assertEq(reason.length, 0);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrow.Released(id, payee, keeper, address(usdc), AMOUNT, IAgentEscrow.ReleaseReason.Validation);
        vm.prank(keeper);
        escrow.releaseByValidation(id);
        assertEq(usdc.balanceOf(payee), AMOUNT);
    }

    function test_releaseByValidation_exactThresholdPasses() public {
        uint256 id = _lockWithValidator(80);
        _requestAndRespond(REQUEST, validator, 80);
        escrow.releaseByValidation(id);
        assertEq(uint8(_status(id)), uint8(IAgentEscrow.Status.Released));
    }

    function test_releaseByValidation_belowThreshold() public {
        uint256 id = _lockWithValidator(80);
        _requestAndRespond(REQUEST, validator, 79);
        bytes memory expected =
            abi.encodeWithSelector(IAgentEscrow.ValidationBelowThreshold.selector, id, uint8(79), uint8(80));
        (bool ok, bytes memory reason) = escrow.checkValidation(id);
        assertFalse(ok);
        assertEq(reason, expected);
        vm.expectRevert(expected);
        escrow.releaseByValidation(id);
    }

    function test_releaseByValidation_unansweredRequestNeverPasses() public {
        uint256 id = _lockWithValidator(1);
        registry.validationRequest(validator, 42, "ipfs://request", REQUEST); // response stays 0
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.ValidationBelowThreshold.selector, id, uint8(0), uint8(1)));
        escrow.releaseByValidation(id);
    }

    function test_releaseByValidation_validatorDowngradeBlocksRelease() public {
        uint256 id = _lockWithValidator(80);
        _requestAndRespond(REQUEST, validator, 100);
        vm.prank(validator);
        registry.validationResponse(REQUEST, 10, "ipfs://revised", bytes32(0), "revised");
        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrow.ValidationBelowThreshold.selector, id, uint8(10), uint8(80))
        );
        escrow.releaseByValidation(id);
    }

    function test_releaseByValidation_unknownRequest() public {
        uint256 id = _lockWithValidator(80);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.ValidationNotFound.selector, id, REQUEST));
        escrow.releaseByValidation(id);
    }

    function test_releaseByValidation_wrongValidator() public {
        uint256 id = _lockWithValidator(80);
        // the payee front-runs and opens the request naming a validator it controls
        _requestAndRespond(REQUEST, stranger, 100);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.ValidatorMismatch.selector, id, validator, stranger));
        escrow.releaseByValidation(id);
    }

    function test_releaseByValidation_staleResponseFromBeforeLock() public {
        _requestAndRespond(REQUEST, validator, 100); // validated before the escrow existed
        uint256 respondedAt = block.timestamp;
        vm.warp(block.timestamp + 1);
        uint256 id = _lockWithValidator(80);
        vm.expectRevert(
            abi.encodeWithSelector(IAgentEscrow.ValidationStale.selector, id, respondedAt, uint64(block.timestamp))
        );
        escrow.releaseByValidation(id);
        // a fresh response after the lock makes it valid
        vm.prank(validator);
        registry.validationResponse(REQUEST, 100, "ipfs://again", bytes32(0), "");
        escrow.releaseByValidation(id);
        assertEq(usdc.balanceOf(payee), AMOUNT);
    }

    function test_releaseByValidation_onlyBeforeExpiry() public {
        uint256 id = _lockWithValidator(80);
        _requestAndRespond(REQUEST, validator, 100);
        vm.warp(expiry);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.EscrowExpired.selector, id, expiry));
        escrow.releaseByValidation(id);
        // the refund path takes over at expiry
        escrow.refund(id);
        assertEq(uint8(_status(id)), uint8(IAgentEscrow.Status.Refunded));
    }

    function test_releaseByValidation_suspendedByDispute() public {
        uint256 id = _lockWithValidator(80);
        _requestAndRespond(REQUEST, validator, 100);
        vm.prank(payer);
        escrow.dispute(id);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidStatus.selector, id, IAgentEscrow.Status.Disputed));
        escrow.releaseByValidation(id);
    }

    function test_releaseByValidation_noValidatorConfigured() public {
        uint256 id = _lock(arbiter);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.NoValidator.selector, id));
        escrow.releaseByValidation(id);
    }

    // ------------------------------------------------------------------ refund

    function test_refund_payeeVoluntarily_anytime() public {
        uint256 id = _lock(arbiter);
        uint256 before = usdc.balanceOf(payer);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrow.Refunded(id, payer, payee, address(usdc), AMOUNT, IAgentEscrow.RefundReason.PayeeVoluntary);
        vm.prank(payee);
        escrow.refund(id);
        assertEq(usdc.balanceOf(payer), before + AMOUNT);
        assertEq(escrow.totalLocked(address(usdc)), 0);
    }

    function test_refund_payeeVoluntarily_whileDisputed() public {
        uint256 id = _lock(arbiter);
        vm.prank(payer);
        escrow.dispute(id);
        vm.prank(payee);
        escrow.refund(id);
        assertEq(uint8(_status(id)), uint8(IAgentEscrow.Status.Refunded));
    }

    function test_refund_anyoneAtExpiry_notBefore() public {
        uint256 id = _lock(arbiter);
        vm.warp(expiry - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.RefundNotYetAvailable.selector, id, uint256(expiry)));
        escrow.refund(id);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.RefundNotYetAvailable.selector, id, uint256(expiry)));
        escrow.refund(id);

        vm.warp(expiry);
        uint256 before = usdc.balanceOf(payer);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrow.Refunded(id, payer, stranger, address(usdc), AMOUNT, IAgentEscrow.RefundReason.Expired);
        vm.prank(stranger);
        escrow.refund(id);
        assertEq(usdc.balanceOf(payer), before + AMOUNT);
        assertEq(usdc.balanceOf(stranger), 0);
    }

    function test_refund_disputed_livenessAfterTimeout() public {
        uint256 id = _lock(arbiter);
        vm.prank(payee);
        escrow.dispute(id);
        uint256 availableAt = uint256(expiry) + 30 days;
        assertEq(escrow.refundableAt(id), availableAt);

        vm.warp(availableAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.RefundNotYetAvailable.selector, id, availableAt));
        escrow.refund(id);

        vm.warp(availableAt);
        vm.expectEmit(true, true, true, true, address(escrow));
        emit IAgentEscrow.Refunded(id, payer, stranger, address(usdc), AMOUNT, IAgentEscrow.RefundReason.DisputeTimeout);
        vm.prank(stranger);
        escrow.refund(id);
        assertEq(escrow.totalLocked(address(usdc)), 0);
    }

    function test_refund_revertsOnTerminal() public {
        uint256 id = _lock(arbiter);
        vm.prank(payee);
        escrow.refund(id);
        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidStatus.selector, id, IAgentEscrow.Status.Refunded));
        escrow.refund(id);
    }

    // ------------------------------------------------------------------ dispute / resolve

    function test_dispute_byPayerOrPayee() public {
        uint256 a = _lock(arbiter);
        uint256 b = _lock(arbiter);
        vm.expectEmit(true, true, false, true, address(escrow));
        emit IAgentEscrow.Disputed(a, payer, uint256(expiry) + 30 days);
        vm.prank(payer);
        escrow.dispute(a);
        vm.prank(payee);
        escrow.dispute(b);
        assertEq(uint8(_status(a)), uint8(IAgentEscrow.Status.Disputed));
        assertEq(uint8(_status(b)), uint8(IAgentEscrow.Status.Disputed));
    }

    function test_dispute_reverts() public {
        uint256 id = _lock(arbiter);
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.Unauthorized.selector, arbiter));
        escrow.dispute(id);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.Unauthorized.selector, stranger));
        escrow.dispute(id);

        uint256 noArbiter = _lock(address(0));
        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.NoArbiter.selector, noArbiter));
        escrow.dispute(noArbiter);

        vm.warp(expiry);
        vm.prank(payee);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.EscrowExpired.selector, id, expiry));
        escrow.dispute(id);
    }

    function test_dispute_twiceReverts() public {
        uint256 id = _lock(arbiter);
        vm.prank(payee);
        escrow.dispute(id);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidStatus.selector, id, IAgentEscrow.Status.Disputed));
        escrow.dispute(id);
    }

    function test_resolve_splitsBetweenPayeeAndPayer() public {
        uint256 id = _lock(arbiter);
        vm.prank(payer);
        escrow.dispute(id);
        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 payeeShare = 100 * USDC_UNIT;

        vm.expectEmit(true, true, false, true, address(escrow));
        emit IAgentEscrow.Resolved(id, arbiter, address(usdc), payeeShare, AMOUNT - payeeShare);
        vm.prank(arbiter);
        escrow.resolve(id, payeeShare);

        assertEq(usdc.balanceOf(payee), payeeShare);
        assertEq(usdc.balanceOf(payer), payerBefore + AMOUNT - payeeShare);
        assertEq(usdc.balanceOf(arbiter), 0);
        assertEq(uint8(_status(id)), uint8(IAgentEscrow.Status.Resolved));
        assertEq(escrow.totalLocked(address(usdc)), 0);
    }

    function test_resolve_extremes() public {
        uint256 a = _lock(arbiter);
        uint256 b = _lock(arbiter);
        vm.startPrank(payee);
        escrow.dispute(a);
        escrow.dispute(b);
        vm.stopPrank();
        vm.startPrank(arbiter);
        escrow.resolve(a, 0);
        escrow.resolve(b, AMOUNT);
        vm.stopPrank();
        assertEq(usdc.balanceOf(payee), AMOUNT);
    }

    function test_resolve_afterTimeout_stillAllowedUntilSomeoneRefunds() public {
        uint256 id = _lock(arbiter);
        vm.prank(payee);
        escrow.dispute(id);
        vm.warp(uint256(expiry) + 90 days);
        vm.prank(arbiter);
        escrow.resolve(id, AMOUNT);
        assertEq(usdc.balanceOf(payee), AMOUNT);
    }

    function test_resolve_reverts() public {
        uint256 id = _lock(arbiter);
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidStatus.selector, id, IAgentEscrow.Status.Active));
        escrow.resolve(id, 1);

        vm.prank(payer);
        escrow.dispute(id);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.Unauthorized.selector, payer));
        escrow.resolve(id, 1);
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidResolution.selector, id, AMOUNT + 1, AMOUNT));
        escrow.resolve(id, AMOUNT + 1);
    }

    // ------------------------------------------------------------------ views

    function test_refundableAt_zeroForTerminalAndUnknown() public {
        assertEq(escrow.refundableAt(123), 0);
        uint256 id = _lock(arbiter);
        vm.prank(payer);
        escrow.release(id);
        assertEq(escrow.refundableAt(id), 0);
    }

    function test_checkValidation_reportsStatusAndExpiry() public {
        uint256 id = _lockWithValidator(50);
        _requestAndRespond(REQUEST, validator, 100);
        vm.warp(expiry);
        (bool ok, bytes memory reason) = escrow.checkValidation(id);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(IAgentEscrow.EscrowExpired.selector, id, expiry));
        (ok, reason) = escrow.checkValidation(777);
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(IAgentEscrow.InvalidStatus.selector, 777, IAgentEscrow.Status.None));
    }

    // ------------------------------------------------------------------ token freeze liveness (USDC blacklist)

    function test_blacklistedPayee_payerStillGetsRefundAfterExpiry() public {
        uint256 id = _lock(arbiter);
        usdc.blacklist(payee);
        vm.prank(payer);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        escrow.release(id);

        vm.warp(expiry);
        escrow.refund(id);
        assertEq(uint8(_status(id)), uint8(IAgentEscrow.Status.Refunded));
    }

    function test_blacklistedPayee_arbiterCanStillResolveToPayer() public {
        uint256 id = _lock(arbiter);
        vm.prank(payer);
        escrow.dispute(id);
        usdc.blacklist(payee);
        vm.prank(arbiter);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        escrow.resolve(id, 1);
        vm.prank(arbiter);
        escrow.resolve(id, 0);
        assertEq(uint8(_status(id)), uint8(IAgentEscrow.Status.Resolved));
    }

    // ------------------------------------------------------------------ reentrancy

    function test_reentrancy_tokenCallbackCannotReenter() public {
        CallbackToken cbk = new CallbackToken();
        cbk.mint(payer, 1000);
        vm.prank(payer);
        cbk.approve(address(escrow), 1000);

        // during the lock's transferFrom the token tries to refund escrow #1 (which it is creating)
        cbk.setCallback(address(escrow), abi.encodeCall(AgentEscrow.refund, (1)));
        vm.prank(payer);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        escrow.lock(address(cbk), payee, 1000, expiry, address(0), address(0), 0, 0, 0);

        // and during a release it tries to release again
        cbk.setCallback(address(0), "");
        vm.prank(payer);
        uint256 id = escrow.lock(address(cbk), payee, 1000, expiry, address(0), address(0), 0, 0, 0);
        cbk.setCallback(address(escrow), abi.encodeCall(AgentEscrow.release, (id)));
        vm.prank(payer);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        escrow.release(id);
    }

    // ------------------------------------------------------------------ fuzz

    /// @notice Funds only ever go to the payer or the payee, and are paid out exactly once.
    function testFuzz_lifecycle_fundsOnlyToPayerOrPayee(
        uint256 amount,
        uint32 duration,
        uint8 path,
        uint256 split,
        uint32 waitAfter
    ) public {
        amount = bound(amount, 1, 1_000_000 * USDC_UNIT);
        duration = uint32(bound(duration, 1, 365 days));
        uint64 expiresAt = uint64(block.timestamp + duration);
        uint256 payerBefore = usdc.balanceOf(payer);

        vm.prank(payer);
        uint256 id = escrow.lock(address(usdc), payee, amount, expiresAt, arbiter, address(0), 0, 0, TERMS);

        path = uint8(bound(path, 0, 5));
        if (path == 0) {
            vm.prank(payer);
            escrow.release(id);
        } else if (path == 1) {
            vm.prank(arbiter);
            escrow.release(id);
        } else if (path == 2) {
            vm.prank(payee);
            escrow.refund(id);
        } else if (path == 3) {
            vm.warp(uint256(expiresAt) + bound(waitAfter, 0, 400 days));
            vm.prank(stranger);
            escrow.refund(id);
        } else if (path == 4) {
            vm.prank(payee);
            escrow.dispute(id);
            split = bound(split, 0, amount);
            vm.prank(arbiter);
            escrow.resolve(id, split);
        } else {
            vm.prank(payer);
            escrow.dispute(id);
            vm.warp(uint256(expiresAt) + 30 days + bound(waitAfter, 0, 400 days));
            vm.prank(stranger);
            escrow.refund(id);
        }

        uint256 toPayee = usdc.balanceOf(payee);
        uint256 toPayer = usdc.balanceOf(payer) - (payerBefore - amount);
        assertEq(toPayee + toPayer, amount, "conservation");
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(stranger) + usdc.balanceOf(arbiter) + usdc.balanceOf(keeper), 0, "no leakage");
        assertEq(escrow.totalLocked(address(usdc)), 0);
        if (path <= 1) assertEq(toPayee, amount);
        if (path == 2 || path == 3 || path == 5) assertEq(toPayer, amount);
    }

    function testFuzz_lock_expiryBounds(uint64 expiresAt) public {
        vm.prank(payer);
        if (expiresAt <= block.timestamp || expiresAt > block.timestamp + 365 days) {
            vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.InvalidExpiry.selector, expiresAt));
            escrow.lock(address(usdc), payee, AMOUNT, expiresAt, address(0), address(0), 0, 0, 0);
        } else {
            uint256 id = escrow.lock(address(usdc), payee, AMOUNT, expiresAt, address(0), address(0), 0, 0, 0);
            assertEq(escrow.refundableAt(id), expiresAt);
        }
    }

    function testFuzz_refund_thirdPartyOnlyAfterExpiry(uint32 elapsed) public {
        uint256 id = _lock(arbiter);
        vm.warp(block.timestamp + elapsed);
        vm.prank(stranger);
        if (block.timestamp < expiry) {
            vm.expectRevert(abi.encodeWithSelector(IAgentEscrow.RefundNotYetAvailable.selector, id, uint256(expiry)));
            escrow.refund(id);
        } else {
            escrow.refund(id);
            assertEq(uint8(_status(id)), uint8(IAgentEscrow.Status.Refunded));
        }
    }

    function testFuzz_releaseByValidation_threshold(uint8 threshold, uint8 response) public {
        threshold = uint8(bound(threshold, 1, 100));
        response = uint8(bound(response, 0, 100));
        uint256 id = _lockWithValidator(threshold);
        _requestAndRespond(REQUEST, validator, response);
        if (response >= threshold) {
            escrow.releaseByValidation(id);
            assertEq(usdc.balanceOf(payee), AMOUNT);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(IAgentEscrow.ValidationBelowThreshold.selector, id, response, threshold)
            );
            escrow.releaseByValidation(id);
        }
    }
}
