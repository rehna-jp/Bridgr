// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/RemittanceRouter.sol";

// ─── Mocks ────────────────────────────────────────────────────────────────────

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    string public name;

    constructor(string memory _name) { name = _name; }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockMentoBroker {
    MockERC20 public cNGN;
    uint256 public rate = 1540e18; // 1 cUSD = 1540 cNGN

    constructor(address _cngn) {
        cNGN = MockERC20(_cngn);
    }

    function setRate(uint256 _rate) external { rate = _rate; }

    function getAmountOut(
        address, bytes32, address, address, uint256 amountIn
    ) external view returns (uint256) {
        return (amountIn * rate) / 1e18;
    }

    function swapIn(
        address, bytes32, address tokenIn, address, uint256 amountIn, uint256 amountOutMin
    ) external returns (uint256 amountOut) {
        // Pull tokenIn (simulates broker pulling cUSD)
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        amountOut = (amountIn * rate) / 1e18;
        require(amountOut >= amountOutMin, "slippage");
        cNGN.mint(msg.sender, amountOut);
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

contract RemittanceRouterTest is Test {

    RemittanceRouter router;
    MockERC20        cusd;
    MockERC20        cngn;
    MockMentoBroker  broker;

    address owner     = address(this);
    address agent     = makeAddr("agent");
    address sender    = makeAddr("sender");
    address recipient = makeAddr("recipient");

    uint256 constant ONE_USD = 1e18;

    function setUp() public {
        cusd   = new MockERC20("cUSD");
        cngn   = new MockERC20("cNGN");
        broker = new MockMentoBroker(address(cngn));

        // Deploy router — we patch token addresses via vm.etch trick
        // For unit tests we deploy a testable version with configurable tokens
        router = new RemittanceRouter(
            address(broker),
            address(0x1), // exchange provider (unused in mock)
            bytes32(0),   // exchange id (unused in mock)
            agent
        );

        // Patch hardcoded token addresses in contract bytecode
        vm.etch(router.CUSD(), address(cusd).code);
        vm.etch(router.CNGN(), address(cngn).code);

        // Fund sender with 1000 cUSD
        cusd.mint(sender, 1000 * ONE_USD);
    }

    // ── Quote Tests ───────────────────────────────────────────────────────────

    function test_getQuote_basicAmount() public {
        uint256 usdAmount = 30 * ONE_USD;
        (uint256 ngnAmount, uint256 fee, uint256 rate) = router.getQuote(usdAmount);

        uint256 expectedFee = (usdAmount * 50) / 10_000; // 0.5%
        assertEq(fee, expectedFee, "fee mismatch");
        assertGt(ngnAmount, 0, "ngn should be > 0");
        assertGt(rate, 0, "rate should be > 0");
    }

    function test_getQuote_revertsOnZero() public {
        vm.expectRevert(RemittanceRouter.ZeroAmount.selector);
        router.getQuote(0);
    }

    // ── sendRemittance Tests ──────────────────────────────────────────────────

    function test_sendRemittance_success() public {
        uint256 usdAmount = 30 * ONE_USD;
        (uint256 expectedNgn, , ) = router.getQuote(usdAmount);
        uint256 minNgn = (expectedNgn * 99) / 100; // 1% slippage tolerance

        // Sender approves router
        vm.prank(sender);
        MockERC20(router.CUSD()).approve(address(router), usdAmount);

        // Agent triggers transfer
        vm.prank(agent);
        uint256 ngnReceived = router.sendRemittance(
            sender, recipient, usdAmount, minNgn, "Send $30 to sister in Lagos"
        );

        assertGe(ngnReceived, minNgn, "received less than min");
        assertGt(MockERC20(router.CNGN()).balanceOf(recipient), 0, "recipient got nothing");
        assertGt(router.accruedFees(), 0, "no fees accrued");
    }

    function test_sendRemittance_onlyAgent() public {
        vm.prank(sender);
        MockERC20(router.CUSD()).approve(address(router), 30 * ONE_USD);

        vm.prank(makeAddr("random")); // not the agent
        vm.expectRevert(RemittanceRouter.NotAgent.selector);
        router.sendRemittance(sender, recipient, 30 * ONE_USD, 0, "hack attempt");
    }

    function test_sendRemittance_zeroAmount() public {
        vm.prank(agent);
        vm.expectRevert(RemittanceRouter.ZeroAmount.selector);
        router.sendRemittance(sender, recipient, 0, 0, "nothing");
    }

    function test_sendRemittance_zeroRecipient() public {
        vm.prank(sender);
        MockERC20(router.CUSD()).approve(address(router), 30 * ONE_USD);

        vm.prank(agent);
        vm.expectRevert(RemittanceRouter.ZeroAddress.selector);
        router.sendRemittance(sender, address(0), 30 * ONE_USD, 0, "to nobody");
    }

    function test_sendRemittance_emitsEvent() public {
        uint256 usdAmount = 10 * ONE_USD;
        vm.prank(sender);
        MockERC20(router.CUSD()).approve(address(router), usdAmount);

        vm.expectEmit(true, true, false, false);
        emit RemittanceRouter.RemittanceSent(sender, recipient, usdAmount, 0, 0, "test memo");

        vm.prank(agent);
        router.sendRemittance(sender, recipient, usdAmount, 0, "test memo");
    }

    // ── sendDirect Tests ──────────────────────────────────────────────────────

    function test_sendDirect_success() public {
        uint256 usdAmount = 50 * ONE_USD;
        (uint256 expectedNgn, , ) = router.getQuote(usdAmount);

        vm.startPrank(sender);
        MockERC20(router.CUSD()).approve(address(router), usdAmount);
        uint256 received = router.sendDirect(recipient, usdAmount, (expectedNgn * 99) / 100, "direct send");
        vm.stopPrank();

        assertGt(received, 0);
        assertGt(MockERC20(router.CNGN()).balanceOf(recipient), 0);
    }

    // ── Admin Tests ───────────────────────────────────────────────────────────

    function test_setFee_success() public {
        router.setFee(100); // 1%
        assertEq(router.feeBps(), 100);
    }

    function test_setFee_tooHigh() public {
        vm.expectRevert(RemittanceRouter.FeeTooHigh.selector);
        router.setFee(201); // over 2% cap
    }

    function test_setFee_onlyOwner() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(RemittanceRouter.NotOwner.selector);
        router.setFee(10);
    }

    function test_setAgent_success() public {
        address newAgent = makeAddr("newAgent");
        router.setAgent(newAgent);
        assertEq(router.agent(), newAgent);
    }

    function test_withdrawFees() public {
        // First accrue some fees
        uint256 usdAmount = 100 * ONE_USD;
        vm.prank(sender);
        MockERC20(router.CUSD()).approve(address(router), usdAmount);
        vm.prank(agent);
        router.sendRemittance(sender, recipient, usdAmount, 0, "big send");

        uint256 fees = router.accruedFees();
        assertGt(fees, 0);

        address treasury = makeAddr("treasury");
        router.withdrawFees(treasury);

        assertEq(router.accruedFees(), 0);
        assertEq(MockERC20(router.CUSD()).balanceOf(treasury), fees);
    }

    // ── Fuzz Tests ────────────────────────────────────────────────────────────

    function testFuzz_sendRemittance_anyAmount(uint256 amount) public {
        amount = bound(amount, 1 * ONE_USD, 500 * ONE_USD);

        cusd.mint(sender, amount);
        vm.prank(sender);
        MockERC20(router.CUSD()).approve(address(router), amount);

        vm.prank(agent);
        uint256 received = router.sendRemittance(sender, recipient, amount, 0, "fuzz test");
        assertGt(received, 0);
    }
}