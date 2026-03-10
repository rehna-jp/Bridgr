// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title RemittanceRouter
 * @notice AI-powered multi-corridor remittance router on Celo
 * @dev Supports USD → NGN, USD → KES, USD → GHS via Mento swaps
 *      The OpenClaw/Claude agent calls sendRemittance() with the
 *      correct corridorId based on natural language intent parsing.
 *
 *  Corridor IDs (registered at deploy time via addCorridor):
 *    0 = USD → NGN (Nigeria)
 *    1 = USD → KES (Kenya)
 *    2 = USD → GHS (Ghana)
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IMentoBroker {
    function getAmountOut(
        address exchangeProvider,
        bytes32 exchangeId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut);

    function swapIn(
        address exchangeProvider,
        bytes32 exchangeId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin
    ) external returns (uint256 amountOut);
}

contract RemittanceRouter {

    // ─── Types ────────────────────────────────────────────────────────────────

    /// @notice A supported remittance corridor e.g. USD → NGN
    struct Corridor {
        address tokenOut;         // cNGN | cKES | cGHS
        address exchangeProvider; // Mento BiPoolManager for this pair
        bytes32 exchangeId;       // Mento pool ID for cUSD <> tokenOut
        string  label;            // e.g. "USD → NGN"
        string  currency;         // e.g. "NGN" — used by agent for display
        bool    active;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    address public owner;
    address public agent;               // OpenClaw agent wallet
    address public immutable CUSD;      // cUSD — always the input token
    address public immutable MENTO_BROKER;

    uint256 public feeBps = 50;         // 0.5% platform fee (50 bps)
    uint256 public constant MAX_FEE_BPS = 200; // 2% hard cap
    uint256 public accruedFees;

    /// corridorId => Corridor (0=NGN, 1=KES, 2=GHS)
    mapping(uint256 => Corridor) public corridors;
    uint256 public corridorCount;

    // ─── Events ───────────────────────────────────────────────────────────────

    event RemittanceSent(
        address indexed sender,
        address indexed recipient,
        uint256 indexed corridorId,
        uint256 usdAmount,
        uint256 localAmount,
        uint256 fee,
        string  memo
    );

    event CorridorAdded(uint256 indexed corridorId, string label, address tokenOut);
    event CorridorToggled(uint256 indexed corridorId, bool active);
    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event AgentUpdated(address oldAgent, address newAgent);
    event FeesWithdrawn(address to, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error NotOwner();
    error NotAgent();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidCorridor(uint256 corridorId);
    error CorridorInactive(uint256 corridorId);
    error SlippageExceeded(uint256 minOut, uint256 received);
    error FeeTooHigh();
    error TransferFailed();

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAgent() {
        if (msg.sender != agent && msg.sender != owner) revert NotAgent();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    /**
     * @param _cusd         cUSD token address (from .env: CUSD_TESTNET / CUSD_MAINNET)
     * @param _mentoBroker  Mento Broker address (from .env: MENTO_BROKER)
     * @param _agent        OpenClaw agent wallet (from .env: AGENT_ADDRESS)
     */
    constructor(address _cusd, address _mentoBroker, address _agent) {
        if (_cusd == address(0) || _mentoBroker == address(0) || _agent == address(0))
            revert ZeroAddress();
        owner        = msg.sender;
        agent        = _agent;
        CUSD         = _cusd;
        MENTO_BROKER = _mentoBroker;
    }

    // ─── Corridor Management ──────────────────────────────────────────────────

    /**
     * @notice Register a corridor — called 3x by the deploy script
     * @param tokenOut         cNGN | cKES | cGHS (from .env: CNGN_*, CKES_*, CGHS_*)
     * @param exchangeProvider Mento BiPoolManager (from .env: MENTO_BIPOOLMANAGER)
     * @param exchangeId       Pool ID — fetch from Mento SDK before deploying
     * @param label            Human-readable e.g. "USD → NGN"
     * @param currency         Currency code e.g. "NGN"
     */
    function addCorridor(
        address tokenOut,
        address exchangeProvider,
        bytes32 exchangeId,
        string calldata label,
        string calldata currency
    ) external onlyOwner returns (uint256 corridorId) {
        if (tokenOut == address(0) || exchangeProvider == address(0)) revert ZeroAddress();

        corridorId = corridorCount++;
        corridors[corridorId] = Corridor({
            tokenOut:         tokenOut,
            exchangeProvider: exchangeProvider,
            exchangeId:       exchangeId,
            label:            label,
            currency:         currency,
            active:           true
        });

        emit CorridorAdded(corridorId, label, tokenOut);
    }

    /// @notice Pause or unpause a corridor (e.g. if a Mento pool has issues)
    function toggleCorridor(uint256 corridorId, bool active) external onlyOwner {
        if (corridorId >= corridorCount) revert InvalidCorridor(corridorId);
        corridors[corridorId].active = active;
        emit CorridorToggled(corridorId, active);
    }

    // ─── Quote ────────────────────────────────────────────────────────────────

    /**
     * @notice Preview exchange before sending — agent calls this first
     * @param corridorId  0=NGN | 1=KES | 2=GHS
     * @param usdAmount   cUSD input (18 decimals)
     * @return localAmount   Local currency out after fee
     * @return fee           Platform fee in cUSD
     * @return exchangeRate  Local per 1 cUSD (scaled 1e18)
     */
    function getQuote(uint256 corridorId, uint256 usdAmount)
        external
        view
        returns (uint256 localAmount, uint256 fee, uint256 exchangeRate)
    {
        if (usdAmount == 0) revert ZeroAmount();
        if (corridorId >= corridorCount) revert InvalidCorridor(corridorId);

        Corridor memory c = corridors[corridorId];
        if (!c.active) revert CorridorInactive(corridorId);

        fee = (usdAmount * feeBps) / 10_000;
        uint256 swapAmount = usdAmount - fee;

        localAmount = IMentoBroker(MENTO_BROKER).getAmountOut(
            c.exchangeProvider,
            c.exchangeId,
            CUSD,
            c.tokenOut,
            swapAmount
        );

        // Rate scaled 1e18: how many local tokens per 1 cUSD
        exchangeRate = (localAmount * 1e18) / swapAmount;
    }

    // ─── Send (Agent-triggered) ───────────────────────────────────────────────

    /**
     * @notice Execute remittance — called by OpenClaw agent
     * @param sender      User wallet (must have pre-approved cUSD to this contract)
     * @param recipient   Recipient wallet on Celo
     * @param corridorId  0=NGN | 1=KES | 2=GHS
     * @param usdAmount   cUSD to send (18 decimals)
     * @param minLocalOut Slippage protection — revert if local received < this
     * @param memo        Original user message e.g. "Send $30 to my sister in Lagos"
     */
    function sendRemittance(
        address sender,
        address recipient,
        uint256 corridorId,
        uint256 usdAmount,
        uint256 minLocalOut,
        string calldata memo
    ) external onlyAgent returns (uint256 localReceived) {
        localReceived = _executeSwap(
            sender, recipient, corridorId, usdAmount, minLocalOut, memo
        );
    }

    /**
     * @notice Direct send — user calls themselves, no agent needed
     * @dev Useful for power users or direct dApp integration
     */
    function sendDirect(
        address recipient,
        uint256 corridorId,
        uint256 usdAmount,
        uint256 minLocalOut,
        string calldata memo
    ) external returns (uint256 localReceived) {
        localReceived = _executeSwap(
            msg.sender, recipient, corridorId, usdAmount, minLocalOut, memo
        );
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _executeSwap(
        address sender,
        address recipient,
        uint256 corridorId,
        uint256 usdAmount,
        uint256 minLocalOut,
        string calldata memo
    ) internal returns (uint256 localReceived) {
        if (usdAmount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        if (corridorId >= corridorCount) revert InvalidCorridor(corridorId);

        Corridor memory c = corridors[corridorId];
        if (!c.active) revert CorridorInactive(corridorId);

        // 1. Pull cUSD from sender
        bool ok = IERC20(CUSD).transferFrom(sender, address(this), usdAmount);
        if (!ok) revert TransferFailed();

        // 2. Deduct platform fee
        uint256 fee = (usdAmount * feeBps) / 10_000;
        uint256 swapAmount = usdAmount - fee;
        accruedFees += fee;

        // 3. Approve Mento and execute swap cUSD → local stablecoin
        IERC20(CUSD).approve(MENTO_BROKER, swapAmount);
        localReceived = IMentoBroker(MENTO_BROKER).swapIn(
            c.exchangeProvider,
            c.exchangeId,
            CUSD,
            c.tokenOut,
            swapAmount,
            minLocalOut
        );

        // 4. Slippage check
        if (localReceived < minLocalOut) revert SlippageExceeded(minLocalOut, localReceived);

        // 5. Deliver local stablecoin to recipient
        ok = IERC20(c.tokenOut).transfer(recipient, localReceived);
        if (!ok) revert TransferFailed();

        emit RemittanceSent(sender, recipient, corridorId, usdAmount, localReceived, fee, memo);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit FeeUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    function setAgent(address newAgent) external onlyOwner {
        if (newAgent == address(0)) revert ZeroAddress();
        emit AgentUpdated(agent, newAgent);
        agent = newAgent;
    }

    function withdrawFees(address to) external onlyOwner {
        uint256 amount = accruedFees;
        accruedFees = 0;
        bool ok = IERC20(CUSD).transfer(to, amount);
        if (!ok) revert TransferFailed();
        emit FeesWithdrawn(to, amount);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @notice Returns corridor info — agent calls this to build its routing table
    function getCorridor(uint256 corridorId)
        external
        view
        returns (
            address tokenOut,
            string memory label,
            string memory currency,
            bool active
        )
    {
        Corridor memory c = corridors[corridorId];
        return (c.tokenOut, c.label, c.currency, c.active);
    }
}