// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// ERC-8004 Identity Registry interface
interface IIdentityRegistry {
    function registerIdentity(
        address subject,
        string calldata name,
        string calldata description,
        string calldata url,
        string calldata imageUrl,
        bytes32[] calldata tags
    ) external returns (uint256 identityId);

    function getIdentity(address subject)
        external
        view
        returns (
            uint256 identityId,
            string memory name,
            string memory description,
            string memory url,
            string memory imageUrl,
            bytes32[] memory tags,
            uint256 createdAt
        );

    function isRegistered(address subject) external view returns (bool);
}

// ERC-8004 Reputation Registry interface
interface IReputationRegistry {
    function getReputation(address subject)
        external
        view
        returns (
            uint256 score,
            uint256 totalTransactions,
            uint256 totalVolume,
            uint256 lastUpdated
        );
}

contract RegisterIdentity is Script {
    // ERC-8004 Contract Addresses (Celo Mainnet)
    address constant IDENTITY_REGISTRY_MAINNET =
        0x8004A818BFB912233c491871b3d84c89A494BD9e;
    address constant REPUTATION_REGISTRY_MAINNET =
        0x8004B663056A597Dffe9eCcC1965A193B7388713;

    // For Celo Sepolia testnet - use same addresses if deployed there
    // otherwise deploy mock or skip reputation check on testnet
    address constant IDENTITY_REGISTRY_TESTNET =
        0x8004A818BFB912233c491871b3d84c89A494BD9e;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address agentAddress = vm.envAddress("AGENT_ADDRESS");
        address routerAddress = vm.envAddress("ROUTER_ADDRESS");
        bool isMainnet = vm.envOr("IS_MAINNET", false);

        address identityRegistry = isMainnet
            ? IDENTITY_REGISTRY_MAINNET
            : IDENTITY_REGISTRY_TESTNET;

        console.log("=== Bridgr ERC-8004 Identity Registration ===");
        console.log("Agent address:   ", agentAddress);
        console.log("Router address:  ", routerAddress);
        console.log("Network:         ", isMainnet ? "Mainnet" : "Testnet");
        console.log("Identity Registry:", identityRegistry);

        IIdentityRegistry registry = IIdentityRegistry(identityRegistry);

        // Check if already registered
        bool alreadyRegistered = registry.isRegistered(agentAddress);
        if (alreadyRegistered) {
            console.log("Agent already registered. Fetching identity...");
            _logIdentity(registry, agentAddress);
            return;
        }

        // Build tags
        bytes32[] memory tags = new bytes32[](4);
        tags[0] = bytes32("remittance");
        tags[1] = bytes32("ai-agent");
        tags[2] = bytes32("celo");
        tags[3] = bytes32("bridgr");

        vm.startBroadcast(deployerKey);

        // Register agent identity
        uint256 identityId = registry.registerIdentity(
            agentAddress,
            "Bridgr Agent",
            "AI-powered remittance agent. Sends USD to NGN, KES, and GHS via Celo stablecoins in seconds.",
            "https://github.com/rehna-jp/Bridgr",
            "",
            tags
        );

        vm.stopBroadcast();

        console.log("=== Registration Successful ===");
        console.log("Identity ID:     ", identityId);
        console.log("Agent:           ", agentAddress);
        console.log("Name:             Bridgr Agent");
        console.log("Tags:             remittance, ai-agent, celo, bridgr");

        _logIdentity(registry, agentAddress);
    }

    function _logIdentity(
        IIdentityRegistry registry,
        address subject
    ) internal view {
        (
            uint256 identityId,
            string memory name,
            string memory description,
            string memory url,
            ,
            ,
            uint256 createdAt
        ) = registry.getIdentity(subject);

        console.log("=== Identity Details ===");
        console.log("ID:          ", identityId);
        console.log("Name:        ", name);
        console.log("Description: ", description);
        console.log("URL:         ", url);
        console.log("Created at:  ", createdAt);
    }
}
