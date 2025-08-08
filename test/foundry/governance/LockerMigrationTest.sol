// SPDX-License-Identifier: GPL-3.0

// ███╗   ███╗ █████╗ ██╗  ██╗ █████╗
// ████╗ ████║██╔══██╗██║  ██║██╔══██╗
// ██╔████╔██║███████║███████║███████║
// ██║╚██╔╝██║██╔══██║██╔══██║██╔══██║
// ██║ ╚═╝ ██║██║  ██║██║  ██║██║  ██║
// ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝

// Website: https://maha.xyz
// Discord: https://discord.gg/mahadao
// Twitter: https://twitter.com/mahaxyz_

pragma solidity 0.8.21;

import "forge-std/Test.sol";
import {LockerToken} from "../../../contracts/governance/locker/LockerToken.sol";
import {OmnichainStakingToken} from "../../../contracts/governance/locker/staking/OmnichainStakingToken.sol";
import {ILocker} from "../../../contracts/interfaces/governance/ILocker.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {MockERC20} from "../../../contracts/mocks/MockERC20.sol";
import {IMAHAProxy} from "../../../contracts/governance/MAHAProxy.sol";
import {console} from "forge-std/console.sol";
import { ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

// ProxyAdmin interface 
interface IProxyAdmin {
    function upgradeAndCall(ITransparentUpgradeableProxy proxy, address implementation, bytes memory data) external payable;
    function owner() external view returns (address);
}

/**
 * @title LockerMigrationTest
 * @notice Foundry fork test for the locker migration script on Base mainnet
 * @dev Tests migration from old LockerToken to new BaseLocker implementation
 * 
 * To run this test:
 * 1. Set BASE_RPC_URL in your environment variables or .env file
 * 2. Run: forge test --match-contract LockerMigrationTest --fork-url $BASE_RPC_URL -vvv
 * 3. For specific tests: forge test --match-test testFullMigrationProcess --fork-url $BASE_RPC_URL -vvv
 */
contract LockerMigrationTest is Test {
    // Base mainnet fork
    uint256 baseFork;
    
    // Deployed contract addresses on Base mainnet
    address constant OLD_LOCKER_ADDRESS = 0xDAe7CD5AA310C66c555543886DFcD454896Ae2C0;
    address constant STAKING_ADDRESS = 0xfD487AC8de6520263D57bb41253682874Dc0276E;
    address constant MAHA_TOKEN = 0x554bba833518793056CF105E66aBEA330672c0dE;
    address constant MAHA_OWNER = 0x7202136d70026DA33628dD3f3eFccb43F62a2469;
    // ProxyAdmin contract that is the actual admin of the staking proxy on Base
    address constant PROXY_ADMIN = 0xF5dfbB44ED2bfe32953c8237eC03B5AE20a089c4;
    address constant STAKING_OWNER = 0x7202136d70026DA33628dD3f3eFccb43F62a2469;
    
    // Contract instances
    LockerToken oldLocker;
    OmnichainStakingToken staking;
    LockerToken newLocker;
    MockERC20 underlyingToken;
    
    // Test actors
    address deployer;
    
    // Migration data structures
    struct MigrationData {
        uint256[] values;
        uint256[] durations;
        address[] owners;
        bool[] stakeNFTs;
    }
    
    function setUp() public {
        // Create Base mainnet fork
        baseFork = vm.createFork("https://mainnet.base.org", 25296075);
        vm.selectFork(baseFork);

        // Set up test actors
        deployer = makeAddr("deployer");
        
        // Connect to deployed contracts
        oldLocker = LockerToken(OLD_LOCKER_ADDRESS);
        staking = OmnichainStakingToken(STAKING_ADDRESS);

        // Deploy mock MAHA token for testing
        underlyingToken = new MockERC20("MAHA", "MAHA", 18);

        // Deploy new BaseLocker implementation for testing
        vm.prank(deployer);
        newLocker = new LockerToken();

        // Deploy new staking implementation
        OmnichainStakingToken newStakingImpl = new OmnichainStakingToken();

        IProxyAdmin proxyAdmin = IProxyAdmin(PROXY_ADMIN);

        address proxyAdminOwner = proxyAdmin.owner();

        // The staking contract uses MAHAProxy, so we need to call upgradeToAndCall from the proxy admin
        vm.prank(proxyAdminOwner);
        proxyAdmin.upgradeAndCall(
            ITransparentUpgradeableProxy(STAKING_ADDRESS),
            address(newStakingImpl),
            ""
        );

        // Initialize new locker
        vm.prank(deployer);
        newLocker.initialize(
            address(underlyingToken),
            STAKING_ADDRESS
        );

        address stakingOwner = staking.owner();
        vm.prank(stakingOwner);
        staking.setLocker(ILocker(address(newLocker)));
        
        // Label contracts for better debugging
        vm.label(OLD_LOCKER_ADDRESS, "OldLocker");
        vm.label(STAKING_ADDRESS, "Staking");
        vm.label(address(newLocker), "NewLocker");
        vm.label(MAHA_TOKEN, "MAHA");
        vm.label(MAHA_OWNER, "MAHA Owner");
        vm.label(PROXY_ADMIN, "ProxyAdmin");
        vm.label(STAKING_OWNER, "Staking Owner");
        vm.label(deployer, "Deployer"); 
    }

    /**
     * @notice Test the complete migration process with real Base mainnet data
     */
    function testFullMigrationProcess() public {
        // Prepare migration data by scanning the old locker
        MigrationData memory migrationData = _prepareMigrationData();

        // Approve once for the total migration to avoid per-iteration allowance overwrites
        vm.startPrank(deployer);
        underlyingToken.approve(address(newLocker), type(uint256).max);

        // Execute migration
        newLocker.migrateLocks(migrationData.values, migrationData.durations, migrationData.owners, migrationData.stakeNFTs);
        vm.stopPrank();

        // Verify migration results
        _verifyMigrationResults(migrationData);
    }
    
    // ============ Helper Functions ============

    /**
     * @notice Prepare migration data by scanning the old locker (simplified version)
     */
    function _prepareMigrationData() internal returns (MigrationData memory) {
        uint256 validTokenCount = 10;
        
        uint256[] memory values = new uint256[](validTokenCount);
        uint256[] memory durations = new uint256[](validTokenCount);
        address[] memory owners = new address[](validTokenCount);
        bool[] memory stakeNFTs = new bool[](validTokenCount);

        for (uint256 tokenIdLoop = 1; tokenIdLoop <= validTokenCount; tokenIdLoop++) {

            ILocker.LockedBalance memory lockedBalance = oldLocker.locked(tokenIdLoop);
            address actualOwner = oldLocker.ownerOf(tokenIdLoop);
            bool shouldStake = false;

            if (actualOwner == STAKING_ADDRESS) {
                actualOwner = staking.lockedByToken(tokenIdLoop);
                shouldStake = true;
            }

            values[tokenIdLoop-1] = lockedBalance.amount;
            
            uint256 remaining = lockedBalance.end - block.timestamp;
          
            require(remaining > 0, "lock expired");
            durations[tokenIdLoop-1] = remaining;

            owners[tokenIdLoop-1] = actualOwner;
            stakeNFTs[tokenIdLoop-1] = shouldStake;

            //mint MAHA to the owner
            vm.prank(MAHA_OWNER);
            underlyingToken.mint(deployer, lockedBalance.amount);
            
        }   
        
        return MigrationData(values, durations, owners, stakeNFTs);
    }
    
    
    /**
     * @notice Verify migration results
     */
    function _verifyMigrationResults(MigrationData memory data) internal view {
        
        for (uint256 i = 0; i < data.values.length; i++) {
            uint256 newTokenId = i + 1;
            ILocker.LockedBalance memory newLock = newLocker.locked(newTokenId);
            
            assertEq(newLock.amount, data.values[i], "Amount should match");
            assertApproxEqAbs(newLock.end - newLock.start, data.durations[i], 1 weeks, "Duration should roughly match");
        }
    }
} 