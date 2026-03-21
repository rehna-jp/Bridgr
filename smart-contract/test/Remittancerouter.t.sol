// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/RemittanceRouter.sol";

// -- Mocks ---------------------------------------------------------------------

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
    // rates per corridor: corridorId => rate (local per 1e18 cUSD)
    mapping(uint256 => uint256) public rates;

    // token registry: tokenOut address => MockERC20
    mapping(address => MockERC20) public tokens;

    function setRate(address tokenOut, uint256 rate) external {
        rates[uint256(uint160(tokenOut))] = rate;
    }

    function registerToken(address tokenOut) external {
        tokens[tokenOut] = MockERC20(tokenOut);
    }

    function getAmountOut(
        address,        // exchangeProvider (unused in mock)
        bytes32,        // exchangeId (unused in mock)
        address,        // tokenIn
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256) {
        uint256 rate = rates[uint256(uint160(tokenOut))];
        if (rate == 0) rate = 1540e18; // default 1540:1
        return (amountIn * rate) / 1e18;
    }

    function swapIn(
        address,
        bytes32,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin
    ) external returns (uint256 amountOut) {
        // Pull tokenIn from caller
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        uint256 rate = rates[uint256(uint160(tokenOut))];
        if (rate == 0) rate = 1540e18;
        amountOut = (amountIn * rate) / 1e18;

        require(amountOut >= amountOutMin, "slippage");

        // Mint tokenOut to caller
        MockERC20(tokenOut).mint(msg.sender, amountOut);
    }
}

// -- Tests ---------------------------------------------------------------------

contract RemittanceRouterTest is Test {

    RemittanceRouter router;
    MockMentoBroker  broker;

    // Tokens
    MockERC20 cusd;
    MockERC20 cNGN;
    MockERC20 cKES;
    MockERC20 cGHS;

    // Actors
    address owner     = address(this);
    address agent     = makeAddr("agent");
    address sender    = makeAddr("sender");
    address recipient = makeAddr("recipient");

    // Corridor IDs
    uint256 constant NGN = 0;
    uint256 constant KES = 1;
    uint256 constant GHS = 2;

    uint256 constant ONE_USD = 1e18;

    // Exchange provider (mock address - unused by mock broker)
    address constant EXCHANGE_PROVIDER = address(0xBEEF);

    function setUp() public {
        // Deploy mock tokens
        cusd = new MockERC20("cUSD");
        cNGN = new MockERC20("cNGN");
        cKES = new MockERC20("cKES");
        cGHS = new MockERC20("cGHS");

        // Deploy mock broker
        broker = new MockMentoBroker();

        // Set rates: NGN=1540, KES=130, GHS=12
        broker.setRate(address(cNGN), 1540e18);
        broker.setRate(address(cKES), 130e18);
        broker.setRate(address(cGHS), 12e18);

        // Deploy router with new 3-param constructor
        router = new RemittanceRouter(
            address(cusd),
            address(broker),
            agent
        );

        // Register 3 corridors
        router.addCorridor(address(cNGN), EXCHANGE_PROVIDER, bytes32(0), "USD -> NGN", "NGN");
        router.addCorridor(address(cKES), EXCHANGE_PROVIDER, bytes32(0), "USD -> KES", "KES");
        router.addCorridor(address(cGHS), EXCHANGE_PROVIDER, bytes32(0), "USD -> GHS", "GHS");

        // Fund sender with 1000 cUSD
        cusd.mint(sender, 1000 * ONE_USD);
    }

    // -- Constructor Tests -----------------------------------------------------

    function test_constructor_setsState() public view {
        assertEq(router.owner(), owner);
        assertEq(router.agent(), agent);
        assertEq(router.CUSD(), address(cusd));
        assertEq(router.MENTO_BROKER(), address(broker));
        assertEq(router.feeBps(), 50);
        assertEq(router.corridorCount(), 3);
    }

    function test_constructor_revertsZeroAddress() public {
        vm.expectRevert(RemittanceRouter.ZeroAddress.selector);
        new RemittanceRouter(address(0), address(broker), agent);

        vm.expectRevert(RemittanceRouter.ZeroAddress.selector);
        new RemittanceRouter(address(cusd), address(0), agent);

        vm.expectRevert(RemittanceRouter.ZeroAddress.selector);
        new RemittanceRouter(address(cusd), address(broker), address(0));
    }

    // -- Corridor Tests --------------------------------------------------------

    function test_addCorridor_success() public view {
        (address tokenOut, string memory label, string memory currency, bool active) =
            router.getCorridor(NGN);

        assertEq(tokenOut, address(cNGN));
        assertEq(label, "USD -> NGN");
        assertEq(currency, "NGN");
        assertTrue(active);
    }

    function test_addCorridor_allThreeRegistered() public view {
        assertEq(router.corridorCount(), 3);
        (address ngnToken,,,) = router.getCorridor(NGN);
        (address kesToken,,,) = router.getCorridor(KES);
        (address ghsToken,,,) = router.getCorridor(GHS);
        assertEq(ngnToken, address(cNGN));
        assertEq(kesToken, address(cKES));
        assertEq(ghsToken, address(cGHS));
    }

    function test_toggleCorridor_pausesAndUnpauses() public {
        router.toggleCorridor(NGN, false);
        (,,, bool active) = router.getCorridor(NGN);
        assertFalse(active);

        router.toggleCorridor(NGN, true);
        (,,, active) = router.getCorridor(NGN);
        assertTrue(active);
    }

    function test_toggleCorridor_invalidId() public {
        vm.expectRevert(abi.encodeWithSelector(RemittanceRouter.InvalidCorridor.selector, 99));
        router.toggleCorridor(99, false);
    }

    function test_sendRemittance_revertsWhenCorridorInactive() public {
        router.toggleCorridor(NGN, false);

        vm.prank(sender);
        cusd.approve(address(router), 30 * ONE_USD);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(RemittanceRouter.CorridorInactive.selector, NGN));
        router.sendRemittance(sender, recipient, NGN, 30 * ONE_USD, 0, "test");
    }

    // -- Quote Tests -----------------------------------------------------------

    function test_getQuote_NGN() public view {
        (uint256 local, uint256 fee, uint256 rate) = router.getQuote(NGN, 30 * ONE_USD);
        uint256 expectedFee = (30 * ONE_USD * 50) / 10_000;
        assertEq(fee, expectedFee);
        assertGt(local, 0);
        assertGt(rate, 0);
    }

    function test_getQuote_KES() public view {
        (uint256 local, uint256 fee,) = router.getQuote(KES, 30 * ONE_USD);
        assertGt(local, 0);
        assertGt(fee, 0);
    }

    function test_getQuote_GHS() public view {
        (uint256 local, uint256 fee,) = router.getQuote(GHS, 30 * ONE_USD);
        assertGt(local, 0);
        assertGt(fee, 0);
    }

    function test_getQuote_revertsZeroAmount() public {
        vm.expectRevert(RemittanceRouter.ZeroAmount.selector);
        router.getQuote(NGN, 0);
    }

    function test_getQuote_revertsInvalidCorridor() public {
        vm.expectRevert(abi.encodeWithSelector(RemittanceRouter.InvalidCorridor.selector, 99));
        router.getQuote(99, 30 * ONE_USD);
    }

    // -- sendRemittance Tests --------------------------------------------------

    function test_sendRemittance_NGN_success() public {
        uint256 usdAmount = 30 * ONE_USD;
        (uint256 expectedLocal,,) = router.getQuote(NGN, usdAmount);
        uint256 minLocal = (expectedLocal * 99) / 100;

        vm.prank(sender);
        cusd.approve(address(router), usdAmount);

        vm.prank(agent);
        uint256 received = router.sendRemittance(
            sender, recipient, NGN, usdAmount, minLocal, "Send $30 to sister in Lagos"
        );

        assertGe(received, minLocal);
        assertGt(cNGN.balanceOf(recipient), 0);
        assertGt(router.accruedFees(), 0);
    }

    function test_sendRemittance_KES_success() public {
        uint256 usdAmount = 50 * ONE_USD;
        (uint256 expectedLocal,,) = router.getQuote(KES, usdAmount);

        vm.prank(sender);
        cusd.approve(address(router), usdAmount);

        vm.prank(agent);
        uint256 received = router.sendRemittance(
            sender, recipient, KES, usdAmount, (expectedLocal * 99) / 100, "Send to Nairobi"
        );

        assertGt(received, 0);
        assertGt(cKES.balanceOf(recipient), 0);
    }

    function test_sendRemittance_GHS_success() public {
        uint256 usdAmount = 20 * ONE_USD;
        (uint256 expectedLocal,,) = router.getQuote(GHS, usdAmount);

        vm.prank(sender);
        cusd.approve(address(router), usdAmount);

        vm.prank(agent);
        uint256 received = router.sendRemittance(
            sender, recipient, GHS, usdAmount, (expectedLocal * 99) / 100, "Send to Accra"
        );

        assertGt(received, 0);
        assertGt(cGHS.balanceOf(recipient), 0);
    }

    function test_sendRemittance_onlyAgent() public {
        vm.prank(sender);
        cusd.approve(address(router), 30 * ONE_USD);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(RemittanceRouter.NotAgent.selector);
        router.sendRemittance(sender, recipient, NGN, 30 * ONE_USD, 0, "hack");
    }

    function test_sendRemittance_zeroAmount() public {
        vm.prank(agent);
        vm.expectRevert(RemittanceRouter.ZeroAmount.selector);
        router.sendRemittance(sender, recipient, NGN, 0, 0, "nothing");
    }

    function test_sendRemittance_zeroRecipient() public {
        vm.prank(sender);
        cusd.approve(address(router), 30 * ONE_USD);

        vm.prank(agent);
        vm.expectRevert(RemittanceRouter.ZeroAddress.selector);
        router.sendRemittance(sender, address(0), NGN, 30 * ONE_USD, 0, "to nobody");
    }

    function test_sendRemittance_invalidCorridor() public {
        vm.prank(sender);
        cusd.approve(address(router), 30 * ONE_USD);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(RemittanceRouter.InvalidCorridor.selector, 99));
        router.sendRemittance(sender, recipient, 99, 30 * ONE_USD, 0, "bad corridor");
    }

    function test_sendRemittance_emitsEvent() public {
        uint256 usdAmount = 10 * ONE_USD;
        vm.prank(sender);
        cusd.approve(address(router), usdAmount);

        vm.expectEmit(true, true, true, false);
        emit RemittanceRouter.RemittanceSent(sender, recipient, NGN, usdAmount, 0, 0, "test");

        vm.prank(agent);
        router.sendRemittance(sender, recipient, NGN, usdAmount, 0, "test");
    }

    function test_sendRemittance_feeAccrues() public {
        uint256 usdAmount = 100 * ONE_USD;
        uint256 expectedFee = (usdAmount * 50) / 10_000; // 0.5%

        vm.prank(sender);
        cusd.approve(address(router), usdAmount);

        vm.prank(agent);
        router.sendRemittance(sender, recipient, NGN, usdAmount, 0, "fee test");

        assertEq(router.accruedFees(), expectedFee);
    }

    // -- sendDirect Tests ------------------------------------------------------

    function test_sendDirect_success() public {
        uint256 usdAmount = 50 * ONE_USD;
        (uint256 expectedLocal,,) = router.getQuote(NGN, usdAmount);

        vm.startPrank(sender);
        cusd.approve(address(router), usdAmount);
        uint256 received = router.sendDirect(
            recipient, NGN, usdAmount, (expectedLocal * 99) / 100, "direct send"
        );
        vm.stopPrank();

        assertGt(received, 0);
        assertGt(cNGN.balanceOf(recipient), 0);
    }

    // -- Admin Tests -----------------------------------------------------------

    function test_setFee_success() public {
        router.setFee(100);
        assertEq(router.feeBps(), 100);
    }

    function test_setFee_tooHigh() public {
        vm.expectRevert(RemittanceRouter.FeeTooHigh.selector);
        router.setFee(201);
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

    function test_setAgent_zeroAddress() public {
        vm.expectRevert(RemittanceRouter.ZeroAddress.selector);
        router.setAgent(address(0));
    }

    function test_withdrawFees() public {
        uint256 usdAmount = 100 * ONE_USD;
        vm.prank(sender);
        cusd.approve(address(router), usdAmount);
        vm.prank(agent);
        router.sendRemittance(sender, recipient, NGN, usdAmount, 0, "accrue fees");

        uint256 fees = router.accruedFees();
        assertGt(fees, 0);

        address treasury = makeAddr("treasury");
        router.withdrawFees(treasury);

        assertEq(router.accruedFees(), 0);
        assertEq(cusd.balanceOf(treasury), fees);
    }

    function test_withdrawFees_onlyOwner() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(RemittanceRouter.NotOwner.selector);
        router.withdrawFees(makeAddr("treasury"));
    }

    // -- Fuzz Tests ------------------------------------------------------------

    function testFuzz_sendRemittance_anyAmount(uint256 amount) public {
        amount = bound(amount, 1 * ONE_USD, 500 * ONE_USD);
        cusd.mint(sender, amount);

        vm.prank(sender);
        cusd.approve(address(router), amount);

        vm.prank(agent);
        uint256 received = router.sendRemittance(sender, recipient, NGN, amount, 0, "fuzz");
        assertGt(received, 0);
    }

    function testFuzz_sendRemittance_allCorridors(uint256 corridorId, uint256 amount) public {
        corridorId = bound(corridorId, 0, 2); // valid corridors only
        amount = bound(amount, 1 * ONE_USD, 100 * ONE_USD);
        cusd.mint(sender, amount);

        vm.prank(sender);
        cusd.approve(address(router), amount);

        vm.prank(agent);
        uint256 received = router.sendRemittance(sender, recipient, corridorId, amount, 0, "fuzz all");
        assertGt(received, 0);
    }
}