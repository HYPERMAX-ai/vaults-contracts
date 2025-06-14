const hre = require("hardhat");


SETTINGS = {};


async function main() {
    const deployer = (await hre.ethers.getSigners())[0];
    console.log(`Deployer: ${deployer.address}\nHYPE: ${await hre.ethers.provider.getBalance(deployer.address)}`);

    const l1Vault = await hre.ethers.deployContract(
        "L1Vault",
        [
            // "0xd9cbec81df392a88aeff575e962d149d57f4d6bc",
            // "HlpVault",
            // "maxHlpVault",
            deployer.address,

            // TODO: vault
            // "0xa15099a30bbf2e68942d6f4c43d70d04faeab0a0", // HLP
            "0x3ea541c902e9da1679b1f0422d30594a81fbc398", // Test Vault

            hre.ethers.parseUnits("5", 8), // decimals
        ],
        SETTINGS
    );
    await l1Vault.waitForDeployment();
    console.log(`- l1Vault: ${await l1Vault.getAddress()}`);
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});


// - l1Vault: 0xfbeA629825ebe5548F5DEA20ecdD9721fb1cc762
