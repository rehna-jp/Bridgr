// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

/**
 * @title GetExchangeIds
 * @notice Computes and verifies Mento exchangeIds for all 3 Oya Send corridors
 *
 * How exchangeId works (from Mento docs):
 *   exchangeId = keccak256(abi.encodePacked(symbol0, symbol1, pricingModuleName))
 *
 *   e.g. keccak256(abi.encodePacked("cUSD", "cNGN", "ConstantSum"))
 *
 * Run this BEFORE deploying to get the correct values for Deploy.s.sol:
 *
 *   forge script script/GetExchangeIds.s.sol \
 *     --rpc-url $CELO_SEPOLIA_RPC \
 *     -vvvv
 *
 * No --broadcast needed - this is read-only.
 * Copy the output bytes32 values into Deploy.s.sol
 */

interface IBroker {
    function getExchangeProviders() external view returns (address[] memory);
}

interface IExchangeProvider {
    struct Exchange {
        bytes32 exchangeId;
        address[] assets;
    }
    function getExchanges() external view returns (Exchange[] memory);
}

interface IERC20Symbol {
    function symbol() external view returns (string memory);
}

contract GetExchangeIds is Script {

    // -- Addresses from .env ---------------------------------------------------
    // These match your .env TESTNET values - swap for mainnet when ready

    address constant BROKER   = 0x777A8255cA72412f0d706dc03C9D1987306B4CaD; // Mento Broker mainnet
    // For Sepolia testnet broker, update from: https://docs.mento.org/mento/build-on-mento/deployments/addresses

    // Token addresses (mainnet - swap for testnet vars if needed)
    address constant CUSD     = 0x765DE816845861e75A25fCA122bb6898B8B1282a;
    address constant CNGN     = 0x17700282592D6917F6A73D0bF8AcCf4D578c131e;
    address constant CKES     = 0x456a3D042C0DbD3db53D5489e98dFb038553B0d0;
    address constant CGHS     = 0xfAeA5F3404bbA20D3cc2f8C4B0A888F55a3c7313;

    function run() external view {
        console.log("=================================================");
        console.log("  RemittanceRouter - Mento Exchange ID Finder");
        console.log("=================================================");

        // -- Method 1: Compute deterministically ------------------------------
        // The formula from Mento docs (works offline, no RPC needed):
        //   keccak256(abi.encodePacked(symbol0, symbol1, pricingModuleName))
        //
        // All Oya Send corridors use "ConstantSum" pricing (stablecoin pairs)

        bytes32 NGN_ID_COMPUTED = keccak256(abi.encodePacked("cUSD", "cNGN", "ConstantSum"));
        bytes32 KES_ID_COMPUTED = keccak256(abi.encodePacked("cUSD", "cKES", "ConstantSum"));
        bytes32 GHS_ID_COMPUTED = keccak256(abi.encodePacked("cUSD", "cGHS", "ConstantSum"));

        console.log("\n[Method 1] Deterministic computation:");
        console.log("  NGN_EXCHANGE_ID (cUSD/cNGN ConstantSum):");
        console.logBytes32(NGN_ID_COMPUTED);
        console.log("  KES_EXCHANGE_ID (cUSD/cKES ConstantSum):");
        console.logBytes32(KES_ID_COMPUTED);
        console.log("  GHS_EXCHANGE_ID (cUSD/cGHS ConstantSum):");
        console.logBytes32(GHS_ID_COMPUTED);

        // -- Method 2: Live on-chain verification -----------------------------
        // Queries the live Mento Broker to confirm computed IDs match
        // (requires --rpc-url to be set)

        console.log("\n[Method 2] On-chain verification via Broker:");

        IBroker broker = IBroker(BROKER);
        address[] memory providers = broker.getExchangeProviders();
        console.log("  Exchange providers found:", providers.length);

        bool ngnFound = false;
        bool kesFound = false;
        bool ghsFound = false;

        for (uint256 i = 0; i < providers.length; i++) {
            IExchangeProvider provider = IExchangeProvider(providers[i]);
            IExchangeProvider.Exchange[] memory exchanges = provider.getExchanges();

            console.log("\n  Provider", i, ":", providers[i]);
            console.log("  Exchanges:", exchanges.length);

            for (uint256 j = 0; j < exchanges.length; j++) {
                address asset0 = exchanges[j].assets[0];
                address asset1 = exchanges[j].assets[1];

                // Check if this is one of our corridors (either direction)
                bool isCusdNgn = (asset0 == CUSD && asset1 == CNGN) || (asset0 == CNGN && asset1 == CUSD);
                bool isCusdKes = (asset0 == CUSD && asset1 == CKES) || (asset0 == CKES && asset1 == CUSD);
                bool isCusdGhs = (asset0 == CUSD && asset1 == CGHS) || (asset0 == CGHS && asset1 == CUSD);

                if (isCusdNgn) {
                    console.log("\n  [FOUND] cUSD/cNGN pool at provider", i);
                    console.log("  Provider address:", providers[i]);
                    console.log("  Exchange ID (on-chain):");
                    console.logBytes32(exchanges[j].exchangeId);
                    console.log("  Matches computed:", exchanges[j].exchangeId == NGN_ID_COMPUTED);
                    ngnFound = true;
                }

                if (isCusdKes) {
                    console.log("\n  [FOUND] cUSD/cKES pool at provider", i);
                    console.log("  Provider address:", providers[i]);
                    console.log("  Exchange ID (on-chain):");
                    console.logBytes32(exchanges[j].exchangeId);
                    console.log("  Matches computed:", exchanges[j].exchangeId == KES_ID_COMPUTED);
                    kesFound = true;
                }

                if (isCusdGhs) {
                    console.log("\n  [FOUND] cUSD/cGHS pool at provider", i);
                    console.log("  Provider address:", providers[i]);
                    console.log("  Exchange ID (on-chain):");
                    console.logBytes32(exchanges[j].exchangeId);
                    console.log("  Matches computed:", exchanges[j].exchangeId == GHS_ID_COMPUTED);
                    ghsFound = true;
                }
            }
        }

        // -- Summary -----------------------------------------------------------
        console.log("\n=================================================");
        console.log("  SUMMARY - Copy these into Deploy.s.sol");
        console.log("=================================================");
        console.log("\nbytes32 NGN_EXCHANGE_ID =");
        console.logBytes32(NGN_ID_COMPUTED);
        console.log("\nbytes32 KES_EXCHANGE_ID =");
        console.logBytes32(KES_ID_COMPUTED);
        console.log("\nbytes32 GHS_EXCHANGE_ID =");
        console.logBytes32(GHS_ID_COMPUTED);
        console.log("\n  cUSD/cNGN pool found on-chain:", ngnFound);
        console.log("  cUSD/cKES pool found on-chain:", kesFound);
        console.log("  cUSD/cGHS pool found on-chain:", ghsFound);

        if (!ngnFound || !kesFound || !ghsFound) {
            console.log("\n  WARNING: Some pools not found on this network.");
            console.log("  Check that you are using the correct RPC (mainnet vs testnet).");
            console.log("  Testnet may not have all pairs - mainnet should have all 3.");
        }

        console.log("=================================================");
    }
}