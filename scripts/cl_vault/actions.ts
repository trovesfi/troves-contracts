import { ContractAddr, DualActionAmount, EkuboCLVault, EkuboCLVaultStrategies, getMainnetConfig, Global, Pricer, PricerFromApi, PricerRedis, Web3Number } from "@strkfarm/sdk";
import { getAccount, getRpcProvider } from "../lib/utils";
import { STRK, xSTRK } from "../lib/constants";

async function main() {
    const provider = getRpcProvider();
    const config = getMainnetConfig();
    // const pricer = new PricerRedis(config, await Global.getTokens());
    // await pricer.initRedis(process.env.REDIS_URL!);
    const pricer = new PricerFromApi(config, await Global.getTokens());
    console.log('Pricer ready');

    const mod = new EkuboCLVault(config, pricer, EkuboCLVaultStrategies[0]);

    // const acc = getAccount('strkfarmadmin');
    // const user = ContractAddr.from(acc.address);
    // const userTVL = await mod.getUserTVL(user);
    // console.log(`User TVL: ${JSON.stringify(userTVL)}`);

    // const tvl = await mod.getTVL();
    // console.log(`TVL: ${JSON.stringify(tvl)}`);

    const apy = await mod.netAPY();
    console.log(`Net APY: ${JSON.stringify(apy)}`);

    // const currentPrice = await mod.getCurrentPrice();
    // console.log(`Current price: ${JSON.stringify(currentPrice)}`);

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
}

if (require.main === module) {
    main();
    // harvest();
}