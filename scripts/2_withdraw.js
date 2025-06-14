const hre = require("hardhat");


SETTINGS = {};


async function main() {
    const deployer = (await hre.ethers.getSigners())[0];
    console.log(`Deployer: ${deployer.address}\nHYPE: ${await hre.ethers.provider.getBalance(deployer.address)}`);

    const token = await hre.ethers.getContractAt("IERC20", "0xd9cbec81df392a88aeff575e962d149d57f4d6bc");
    const vault = await hre.ethers.getContractAt(
        "L1Vault",
        "0xfbeA629825ebe5548F5DEA20ecdD9721fb1cc762"
    );

    {
        const tx = await vault.withdraw(
            hre.ethers.parseUnits("5.2", await vault.decimals()),
            deployer.address,
            deployer.address,
            { ...SETTINGS, }
        );
        const res = await tx.wait();
        console.log(`- withdraw: ${res.hash}`);
    }
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
