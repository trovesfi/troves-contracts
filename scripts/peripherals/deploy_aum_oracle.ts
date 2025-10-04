import { ACCOUNT_NAME, deployContract, getAccount, getRpcProvider, getSwapInfo, myDeclare } from "../lib/utils";
import { EKUBO_POSITIONS, EKUBO_CORE, EKUBO_POSITIONS_NFT, ORACLE_OURS, wstETH, ETH, ACCESS_CONTROL, xSTRK, STRK, accountKeyMap, SUPER_ADMIN, USDC, USDT} from "../lib/constants";
import { byteArray, Contract, TransactionExecutionStatus, uint256 } from "starknet";
import { EkuboCLVaultStrategies } from "@strkfarm/sdk";
import { executeBatch, scheduleBatch } from "../timelock/actions";

async function declareAndDeploy(
    admin_address: string,
    relayer: string,
    vault: string,
    uniqueIdentifier: string,
) {
    const { class_hash } = await myDeclare("AumOracle");
    // const class_hash = '0x30cdf64bacc2779e2f207b3992de1c2e5036b9e87c22eb60319ae25f1a73077'

    await deployContract("AumOracle", class_hash, {
        admin_address,
        default_relayer_address: relayer,
        vault_contract_address: vault,
    }, uniqueIdentifier);
}

async function upgrade() {
    const { class_hash } = await myDeclare("AumOracle");
    // ! Ensure correct strategy
    const addr = '0x23d69e4391fa72d10e625e7575d8bddbb4aff96f04503f83fdde23123bf41d0'
    if (!addr) {
        throw new Error('No strategy found');
    }
    const cls = await getRpcProvider().getClassAt(addr);
    const contract = new Contract({abi: cls.abi, address: addr, providerOrAccount: getRpcProvider()});
    // const acc = getAccount(accountKeyMap[SUPER_ADMIN]);
    const acc = getAccount('strkfarmadmin');

    const call = await contract.populate("upgrade", [class_hash]);
    const tx = await acc.execute([call]);
    // const scheduleCall = await scheduleBatch([call], "0", "0x0", true);
    // const executeCall = await executeBatch([call], "0", "0x0", true);
    // const tx = await acc.execute([...scheduleCall, ...executeCall]);
    console.log(`Upgrade scheduled. tx: ${tx.transaction_hash}`);
    await getRpcProvider().waitForTransaction(tx.transaction_hash, {
        successStates: [TransactionExecutionStatus.SUCCEEDED]
    });
    console.log(`Upgrade done`);
}

// 0x104d7db720522a6
// 0x104d7db720522a6
if (require.main === module) {
    let OWNER = '0x055d39827894c40F04fe3a314Ad013Bf9Bc5220F7eB6CD8863212DCba6C0e16E';
    const RELAYER = '0x02D6cf6182259ee62A001EfC67e62C1fbc0dF109D2AA4163EB70D6d1074F0173';
    // declareAndDeploy(
    //     OWNER,
    //     RELAYER,
    //     "0x46c7a54c82b1fe374353859f554a40b8bd31d3e30f742901579e7b57b1b5960",
    //     'hyper_xstrk'
    // )
    upgrade();
}