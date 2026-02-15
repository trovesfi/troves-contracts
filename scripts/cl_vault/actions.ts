import dotenv from 'dotenv';
dotenv.config();
import { ContractAddr, DualActionAmount, EkuboCLVault, EkuboCLVaultStrategies, getMainnetConfig, Global, HyperLSTStrategies, Pricer, PricerFromApi, PricerRedis, SenseiStrategies, SenseiVault, SIMPLE_SANITIZER_V2, StandardMerkleTree, UniversalLstMultiplierStrategy, UniversalStrategies, UniversalStrategy, VesuPools, Web3Number } from "@strkfarm/sdk";
import { getAccount, getRpcProvider } from "../lib/utils";
import { STRK, xSTRK } from "../lib/constants";
import { hash, num, shortString, TransactionExecutionStatus } from "starknet";
import { toBigInt } from 'ethers';

async function main() {
    const provider = getRpcProvider(process.env.RPC_URL!);
    const config = getMainnetConfig(process.env.RPC_URL!);
    // const pricer = new PricerRedis(config, await Global.getTokens());
    // await pricer.initRedis(process.env.REDIS_URL!);
    const pricer = new PricerFromApi(config, await Global.getTokens());
    console.log('Pricer ready');

    const mod = new EkuboCLVault(config, pricer, EkuboCLVaultStrategies.find(s => s.name.includes('Ekubo WBTC/USDC') && !s.name.includes('Ekubo WBTC/USDC.e'))!);
    // const mod = new UniversalLstMultiplierStrategy(config, pricer, HyperLSTStrategies[0]);
    // console.log(`Using vault: ${mod.metadata.name} at ${mod.address.address}`);
    // const mod = new SenseiVault(config, pricer, SenseiStrategies[0]);
    // const mod = new UniversalStrategy(config, pricer, UniversalStrategies.find(u => u.name.includes('USDT')));

    // const acc = getAccount('strkfarmadmin');
    // const user = ContractAddr.from(acc.address);
    // const userTVL = await mod.getUserTVL(user);
    // console.log(`User TVL: ${JSON.stringify(userTVL)}`);

    const tvl = await mod.getTVL(6492257);
    console.log(`TVL: ${JSON.stringify(tvl)}`);

    // const aum = await mod.getAUM();
    // console.log(`AUM: `, aum);

    // const hfs = await mod.getVesuHealthFactors();
    // console.log(`HFs: `, hfs);

    // const rewards = await mod.getPendingRewards();
    // console.log(`Rewards: `, rewards);

    // const maxDepositables = await mod.maxDepositables();
    // console.log(`Max depositables: `, maxDepositables);

    // const maxWithdrawables = await mod.maxWithdrawables();
    // console.log(`Max withdrawables: `, maxWithdrawables);

    // const positions = await mod.getVaultPositions();
    // console.log(`Positions: ${JSON.stringify(positions)}`);

    // const currentPrice = await mod.getCurrentPrice();
    // console.log(`Current price: ${JSON.stringify(currentPrice)}`);

    // const apy = await mod.netAPY();
    // console.log(`APY: `, apy);
    // console.log(`Nets: ${positions[0].amount.minus(positions[3].amount).toString()} USDC, ${positions[2].amount.minus(positions[1].amount).toString()} ETH`)

    // 2886881
    // for (let block = 2891673; block <= 2891675; block += 1) {
    //     const positions = await mod.getVesuPositions(block);
    //     const hfs = await mod.getVesuHealthFactors(block);
    //     console.log(`Positions: ${JSON.stringify(positions)}`);
    //     console.log(`Block: ${block}`);
    //     console.log(`Nets: ${positions[0].amount.minus(positions[3].amount).toString()} USDC, ${positions[2].amount.minus(positions[1].amount).toString()} ETH`)
    //     console.log(`HFs: ${JSON.stringify(hfs)}`);
    // }

    // const events = await provider.getEvents({
    //     from_block: {
    //         block_number: 2886581
    //     },
    //     to_block: {
    //         block_number: 2886681
    //     },
    //     address: '0x000d8d6dfec4d33bfb6895de9f3852143a17c6f92fd2a21da3d6924d34870160',
    //     keys: [
    //         [
    //             '0x03731bef77d4371d61d696ce475c60d128c4e2c7bba44336635a540d6b180e88',
    //             // '0x4dc4f0ca6ea4961e4c8373265bfd5317678f4fe374d76f3fd7135f57763bf28', // Genesis pool id
    //             // '0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7', // collateral
    //             // '0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8', // debt
    //             // '0x228cca1005d3f2b55cbaba27cb291dacf1b9a92d1d6b1638195fbd3d0c1e3ba', // vault allocator
    //         ]
    //     ],
    //     chunk_size: 500
    // })
    // const poolId: ContractAddr = ContractAddr.from('0x4dc4f0ca6ea4961e4c8373265bfd5317678f4fe374d76f3fd7135f57763bf28');
    // const collateral: ContractAddr = ContractAddr.from('0x49d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7');
    // const debt: ContractAddr = ContractAddr.from('0x53c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8');
    // const vaultAllocator: ContractAddr = ContractAddr.from('0xf29d2f82e896c0ed74c9eff220af34ac148e8b99846d1ace9fbb02c9191d01');
    // // const poolIdBytes = poolId.toBytes();
    // // const collateralBytes = collateral.toBytes();
    // // const debtBytes = debt.toBytes();
    // // const vaultAllocatorBytes = vaultAllocator.toBytes();
    // console.log(`Events: ${JSON.stringify(events.events.length)}, contract: ${events.continuation_token}`);
    // console.log(`Events: ${JSON.stringify(events.events[0])}`);
    // const filteredEvents = events.events.filter(e => {
    //     // const isPoolId = poolId.eqString(e.keys[1]);
    //     // const isCollateral = collateral.eqString(e.keys[2]);
    //     // const isDebt = debt.eqString(e.keys[3]);
    //     const isVaultAllocator = vaultAllocator.eqString(e.keys[4]);
    //     return isVaultAllocator;
    // })
    // console.log(`Filtered events: ${JSON.stringify(filteredEvents.length)}`);
    // console.log(`Filtered events: ${JSON.stringify(filteredEvents[0])}`);
    // const total_supply = await mod.contract.call("total_supply", [], { blockIdentifier: "2882000" });
    // const total_assets = await mod.contract.call("total_assets", [], { blockIdentifier: "2882000" });
    // console.log(`Total supply: ${total_supply}, Total assets: ${total_assets}`);

    // const maxBorrowables = await mod.getMaxBorrowableAmount();
    // console.log(`Max borrowables: ${JSON.stringify(maxBorrowables)}`);

    // const depositInputs = await mod.matchInputAmounts({
    //     token0: {
    //         tokenInfo: mod.metadata.depositTokens[0],
    //         amount: new Web3Number(1, 18) // 1 STRK
    //     },
    //     token1: {
    //         tokenInfo: mod.metadata.depositTokens[1],
    //         amount: new Web3Number(0, 6) // 1 USDC
    //     }
    // })
    // console.log(`Deposit inputs: token0: ${depositInputs.token0.amount}, token1: ${depositInputs.token1.amount}`);
    // 21.05884839475128
    // const depositAmounts = await mod.getDepositAmounts(depositInputs);
    // console.log(`Deposit amounts: token0: ${depositAmounts.token0.amount}, token1: ${depositAmounts.token1.amount}`);
    
    // const caller = ContractAddr.from(acc.address);

    // const depositCalls = await mod.depositCall(depositInputs, caller);
    // const tx = await acc.execute(depositCalls);
    // console.log(`Deposit tx: ${tx.transaction_hash}`);
    // await provider.waitForTransaction(tx.transaction_hash, {
    //     successStates: ['SUCCEEDED']
    // });
    // console.log('Deposit done');

    // const myShares = await mod.balanceOf(caller);
    // console.log(`My shares: ${myShares}`);

    // const userTVL2 = await mod.getUserTVL(caller);
    // console.log(`User TVL: ${JSON.stringify(userTVL2)}`);
    // const withdrawAmounts: DualActionAmount = {
    //     token0: {
    //         tokenInfo: userTVL2.token0.tokenInfo,
    //         amount: userTVL2.token0.amount.dividedBy(1)
    //     },
    //     token1: {
    //         tokenInfo: userTVL2.token1.tokenInfo,
    //         amount: userTVL2.token1.amount.dividedBy(1)
    //     }
    // }
    // const withdrawCalls = await mod.withdrawCall(withdrawAmounts, caller, caller);
    // const tx = await acc.execute(withdrawCalls);
    // console.log(`Withdraw tx: ${tx.transaction_hash}`);
    // await provider.waitForTransaction(tx.transaction_hash, {
    //     successStates: ['SUCCEEDED']
    // });
    // console.log('Withdraw done');
}

async function harvest() {
    const provider = getRpcProvider();
    const config = getMainnetConfig();
    const pricer = new PricerFromApi(config, await Global.getTokens());
    console.log('Pricer ready');

    const mod = new EkuboCLVault(config, pricer, EkuboCLVaultStrategies[0]);
    const riskAcc = getAccount('risk-manager', 'accounts-risk.json', process.env.ACCOUNT_SECURE_PASSWORD_RISK);
    const calls = await mod.harvest(riskAcc);
    if (calls.length) {
        // console.log('harvest ready');
        const tx = await riskAcc.execute(calls);
        console.log(`Harvest tx: ${tx.transaction_hash}`);
        await provider.waitForTransaction(tx.transaction_hash, {
            successStates: ['SUCCEEDED']
        });
        console.log('Harvest done');
    } else {
        console.log('No harvest calls');
    }

    await provider.waitForTransaction(myHash, {
        successStates: [TransactionExecutionStatus.SUCCEEDED],
        errorStates: [TransactionExecutionStatus.REJECTED, TransactionExecutionStatus.REVERTED]
    });
    
}

async function getCustomMerkleTree() {
    
    // modify delegation to migration contract
    const MIGRATION_CONTRACT = ContractAddr.from('0x2716dc8bf87005e2916241ac1167fb400cf69a708540c2c0c1672a654dbc5a9');
    const POOL_ID = VesuPools.Re7STRK;
    const packedArguments: bigint[] = [
        toBigInt(MIGRATION_CONTRACT.toString()), // v2
    ];
    const leaf1 = {
        id: BigInt(num.getDecimalString(shortString.encodeShortString("mod-del-on"))),
        readableId: "mod-del-on",
        data: [
            SIMPLE_SANITIZER_V2.toBigInt(), // sanitizer address
            POOL_ID.toBigInt(), // contract
            toBigInt(hash.getSelectorFromName("modify_delegation")), // method name
            BigInt(packedArguments.length),
            ...packedArguments
        ]
    };

    // transfer
    const TRANSFER_SANI = ContractAddr.from('0x2c77655d0d3f87d395947def9862865f1c6a6e732c3e837ff884fcbd1fa412');
    const xSTRK = Global.getDefaultTokens().find(t => t.symbol === 'xSTRK')!;
    const xSTRK_SENSEI = ContractAddr.from('0x7023a5cadc8a5db80e4f0fde6b330cbd3c17bbbf9cb145cbabd7bd5e6fb7b0b');
    const packedArguments2: bigint[] = [
        toBigInt(xSTRK_SENSEI.toString()), // to address
    ];
    const leaf2 = {
        id: BigInt(num.getDecimalString(shortString.encodeShortString("transfer"))),
        readableId: "transfer",
        data: [
            TRANSFER_SANI.toBigInt(), // sanitizer address
            xSTRK.address.toBigInt(), // contract
            toBigInt(hash.getSelectorFromName("transfer")), // method name
            BigInt(packedArguments2.length),
            ...packedArguments2
        ]
    };

    const packedArguments3: bigint[] = [
        toBigInt(xSTRK_SENSEI.toString()), // v2
    ];
    const leaf3 = {
        id: BigInt(num.getDecimalString(shortString.encodeShortString("mod-del-on2"))),
        readableId: "mod-del-on2",
        data: [
            SIMPLE_SANITIZER_V2.toBigInt(), // sanitizer address
            POOL_ID.toBigInt(), // contract
            toBigInt(hash.getSelectorFromName("modify_delegation")), // method name
            BigInt(packedArguments3.length),
            ...packedArguments3
        ]
    };

    const leaves = [leaf1, leaf2, leaf3];

    const standardTree = StandardMerkleTree.of(leaves.map(l => l));

    const root = standardTree.root;
    console.log(`Root: ${root}`);

    for (const [i, v] of standardTree.entries()) {
        console.log(`Index: ${i}, Value: ${v.readableId}`);
        console.log(`Value: ${JSON.stringify(standardTree.getProof(i))}`);
    }

}

if (require.main === module) {
    // main();
    // harvest();
    getCustomMerkleTree();
}