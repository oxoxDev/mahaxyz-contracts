import hre from "hardhat";
import { deployProxy, upgradeProxy, waitForTx } from "../utils";
import { MaxUint256 } from "ethers";

async function main() {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();

  const oldLockerAddress = "0xDAe7CD5AA310C66c555543886DFcD454896Ae2C0";
  const stakingAddress = "0xfD487AC8de6520263D57bb41253682874Dc0276E";
  const mahatokenAddress = "0x554bba833518793056CF105E66aBEA330672c0dE";
  const proxyAdminAddress = "0xF5dfbB44ED2bfe32953c8237eC03B5AE20a089c4";
  const totalTokens = 1109;

  const staking = await hre.ethers.getContractAt(
    "OmnichainStakingToken",
    stakingAddress
  );

  // Connect to the old locker contract
  const oldLocker = await hre.ethers.getContractAt(
    "LockerToken",
    oldLockerAddress
  );

  // deploy new locker
  const newLockerD = await deployProxy(
    hre,
    "LockerToken",
    [mahatokenAddress, stakingAddress],
    proxyAdminAddress,
    "LockerToken",
    deployer,
    true
  );

  // const newLockerD = await deployContract(
  //   hre,
  //   "TransparentUpgradeableProxy",
  //   [lockerTokenImpl.address, proxyAdminD.address, "0x"],
  //   "LockerToken"
  // );

  const newLocker = await hre.ethers.getContractAt(
    "LockerToken",
    newLockerD.address
  );

  //upgrade omnichain staking
  await upgradeProxy(
    hre,
    stakingAddress,
    "OmnichainStakingToken",
    proxyAdminAddress,
    deployer,
    true
  );

  // const proxyAdmin = await hre.ethers.getContractAt(
  //   "ProxyAdmin",
  //   proxyAdminAddress
  // );

  // await waitForTx(
  //   await proxyAdmin.upgradeAndCall(
  //     stakingAddress,
  //     "OmnichainStakingToken",
  //     ""
  //   )
  // );

  // set new locker
  await staking.setLocker(newLocker.target as string);

  console.log("Starting migration process for 1109 tokens...");

  // Arrays to store migration data
  const values: bigint[] = [];
  const durations: bigint[] = [];
  const owners: string[] = [];
  const stakeNFTs: boolean[] = [];

  // Cache current timestamp to compute durations
  const latestBlock = await hre.ethers.provider.getBlock("latest");
  const now = BigInt(latestBlock!.timestamp);

  console.log("Gathering token data from old locker contract...");

  // Iterate through all token IDs (assuming they start from 1)
  for (let tokenId = 1; tokenId <= totalTokens; tokenId++) {
    try {
      if (tokenId % 50 === 0) console.log(`Processing token ${tokenId}/${totalTokens}`);

      // Get locked balance details from old locker
      const lockedBalance = await oldLocker.locked(tokenId);

      // Check if the token exists (has non-zero amount)
      if (lockedBalance.amount === 0n) {
        continue;
      }

      // Get the current owner of the NFT
      let actualOwner: string;
      let shouldStake = false;

      try {
        const nftOwner = await oldLocker.ownerOf(tokenId);

        // If owned by staking, fetch the mapped owner
        if (nftOwner.toLowerCase() === stakingAddress.toLowerCase()) {
          actualOwner = await staking.lockedByToken(tokenId);
          shouldStake = true;
        } else {
          // NFT is directly owned by user
          actualOwner = nftOwner;
          shouldStake = false;
        }
      } catch (error) {
        console.log(`Error getting for token ${tokenId}: ${error}`);
        continue;
      }

      // Ensure we have a valid owner
      if (!actualOwner || actualOwner === "0x0000000000000000000000000000000000000000") {
        console.log(`No owner found for token ${tokenId}`);
        continue;
      }

      const end = BigInt(lockedBalance.end);
      if (end <= now) {
        console.log(`Lock expired for token ${tokenId}`);
        continue;
      }

      const duration = end - now;

      // Add to migration arrays
      values.push(BigInt(lockedBalance.amount));
      durations.push(duration);
      owners.push(actualOwner);
      stakeNFTs.push(shouldStake);
    } catch (_error) {
      console.log(`Error processing token ${tokenId}: ${_error}`);
      continue;
    }
  }

  console.log(`\nPrepared ${values.length} tokens for migration`);

  if (values.length === 0) {
    console.log("No tokens to migrate!");
    return;
  }

  // Approve underlying MAHA to the locker for pulling funds during migration
  const underlyingAddress: string = await newLocker.underlying();
  const underlying = await hre.ethers.getContractAt(
    "MAHA",
    underlyingAddress
  );

  // approve underlying to new locker
  await waitForTx(await underlying.approve(newLocker.target as string, MaxUint256));

  // Execute migration in batches to avoid gas limit issues
  const batchSize = 100;
  for (let i = 0; i < values.length; i += batchSize) {
    const batchValues = values.slice(i, i + batchSize);
    const batchDurations = durations.slice(i, i + batchSize);
    const batchOwners = owners.slice(i, i + batchSize);
    const batchStakeNFTs = stakeNFTs.slice(i, i + batchSize);

    console.log(`\nProcessing batch ${i / batchSize + 1} of ${Math.ceil(values.length / batchSize)}`);

    // Execute migration for this batch
    const tx = await newLocker.migrateLocks(
      batchValues,
      batchDurations,
      batchOwners,
      batchStakeNFTs
    );

    await waitForTx(tx);
  }

  console.log("\n✅ Migration completed successfully!");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
