// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/RemittanceRouter.sol";

/**
 * @title DeployRemittanceRouter
 * @notice Deploy RemittanceRouter + register NGN, KES, GHS corridors
 *
 * PRE-FLIGHT CHECKLIST:
 *   1. Run GetExchangeIds.s.sol first to verify exchange IDs on your target network
 *   2. Fill in your .env (see .env.example)
 *   3. Ensure deployer wallet has CELO for gas
 *
 * Deploy to testnet:
 *   forge script script/Deploy.s.sol \
 *     --rpc-url $CELO_SEPOLIA_RPC \
 *     --broadcast --verify -vvvv
 *
 * Deploy to mainnet:
 *   forge script script/Deploy.s.sol \
 *     --rpc-url $CELO_MAINNET_RPC \
 *     --broadcast --verify -vvvv
 */
contract DeployRemittanceRouter is Script {

    // ── Exchange IDs ─────────────────────────────────────────────────────────
    // Formula: keccak256(abi.encodePacked(symbol0, symbol1, pricingModuleName))
    // All Oya Send corridors use ConstantSum pricing (stablecoin pairs)
    // Verified via: forge script script/GetExchangeIds.s.sol --rpc-url $RPC -vvvv

    bytes32 constant NGN_EXCHANGE_ID = keccak256(abi.encodePacked("cUSD", "cNGN", "ConstantSum"));
    bytes32 constant KES_EXCHANGE_ID = keccak256(abi.encodePacked("cUSD", "cKES", "ConstantSum"));
    bytes32 constant GHS_EXCHANGE_ID = keccak256(abi.encodePacked("cUSD", "cGHS", "ConstantSum"));

    function run() external {
        uint256 deployerKey  = vm.envUint("PRIVATE_KEY");
        address agentAddress = vm.envAddress("AGENT_ADDRESS");

        // Token + protocol addresses from .env
        // Swap TESTNET <-> MAINNET vars depending on target network
        address cusd          = vm.envAddress("CUSD_TESTNET");
        address mentoBroker   = vm.envAddress("MENTO_BROKER");
        address biPoolManager = vm.envAddress("MENTO_BIPOOLMANAGER");
        address cNGN          = vm.envAddress("CNGN_TESTNET");
        address cKES          = vm.envAddress("CKES_TESTNET");
        address cGHS          = vm.envAddress("CGHS_TESTNET");

        vm.startBroadcast(deployerKey);

        // 1. Deploy the router
        RemittanceRouter router = new RemittanceRouter(
            cusd,
            mentoBroker,
            agentAddress
        );

        // 2. Register corridors — ORDER MATTERS
        //    Agent uses these IDs: 0=NGN, 1=KES, 2=GHS
        router.addCorridor(cNGN, biPoolManager, NGN_EXCHANGE_ID, "USD -> NGN", "NGN");
        router.addCorridor(cKES, biPoolManager, KES_EXCHANGE_ID, "USD -> KES", "KES");
        router.addCorridor(cGHS, biPoolManager, GHS_EXCHANGE_ID, "USD -> GHS", "GHS");

        vm.stopBroadcast();

        // 3. Print deployment summary
        console.log("=================================================");
        console.log("  OYA SEND — Deployment Complete");
        console.log("=================================================");
        console.log("Contract:  ", address(router));
        console.log("Owner:     ", router.owner());
        console.log("Agent:     ", router.agent());
        console.log("Fee (bps): ", router.feeBps());
        console.log("-------------------------------------------------");
        console.log("Corridors: ", router.corridorCount());
        console.log("  [0] USD -> NGN | cNGN:", cNGN);
        console.log("  [1] USD -> KES | cKES:", cKES);
        console.log("  [2] USD -> GHS | cGHS:", cGHS);
        console.log("-------------------------------------------------");
        console.log("Exchange IDs:");
        console.log("  NGN:"); console.logBytes32(NGN_EXCHANGE_ID);
        console.log("  KES:"); console.logBytes32(KES_EXCHANGE_ID);
        console.log("  GHS:"); console.logBytes32(GHS_EXCHANGE_ID);
        console.log("=================================================");
        console.log("\nNext steps:");
        console.log("1. Add to agent .env:  ROUTER_ADDRESS=", address(router));
        console.log("2. Fund agent wallet with CELO for gas");
        console.log("3. Test a quote:       cast call <router> getQuote(uint256,uint256) 0 30000000000000000000");
    }
}