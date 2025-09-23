import { ACCOUNT_NAME, deployContract, getAccount, getRpcProvider, getSwapInfo, myDeclare } from "../lib/utils";
import { EKUBO_POSITIONS, EKUBO_CORE, EKUBO_POSITIONS_NFT, ORACLE_OURS, wstETH, ETH, ACCESS_CONTROL, xSTRK, STRK, accountKeyMap, SUPER_ADMIN, USDC, USDT, WBTC, xWBTC, tBTC, xtBTC, xsBTC, solvBTC} from "../lib/constants";
import { byteArray, Contract, num, num, TransactionExecutionStatus, uint256 } from "starknet";
import { ContractAddr, EkuboCLVaultStrategies } from "@strkfarm/sdk";
import { executeBatch, scheduleBatch } from "../timelock/actions";

// Added parameters for pool configuration
function createPoolKey(
    token0: string,
    token1: string,
    fee: string,
    tick_spacing: number,
    extension: number = 0
) {
    return {
        token0,
        token1,
        fee,
        tick_spacing, 
        extension 
    };
}

interface Tick {
    mag: number;
    sign: number;
}

function createBounds(
    lowerBound: Tick,
    upperBound: Tick,
) {
    return {
        lower: lowerBound,
        upper: upperBound
    };
}

function priceToTick(price: number, isRoundDown: boolean, tickSpacing: number, token0Decimals: number, token1Decimals: number) {
    const adjustedprice = price * (10 ** (token1Decimals)) / (10 ** (token0Decimals));
    const value = isRoundDown ? Math.floor(Math.log(adjustedprice) / Math.log(1.000001)) : Math.ceil(Math.log(adjustedprice) / Math.log(1.000001));
    const tick = Math.floor(value / tickSpacing) * tickSpacing;
    if (tick < 0) {
        return {
            mag: -tick,
            sign: 1
        };
    } else {
        return {
            mag: tick,
            sign: 0
        };
    }
}

function createFeeSettings(
    feeBps: number,
    collector: string
) {
    return {
        fee_bps: uint256.bnToUint256(feeBps.toString()),      
        fee_collector: collector 
    };
}

async function declareAndDeployConcLiquidityVault(
    poolKey: ReturnType<typeof createPoolKey>,
    bounds: ReturnType<typeof createBounds>,
    feeBps: number,
    collector: string,
    name: string,
    symbol: string,
) {
    const accessControl = ACCESS_CONTROL;
    // const { class_hash } = await myDeclare("ConcLiquidityVault");
    const class_hash = '0x30cdf64bacc2779e2f207b3992de1c2e5036b9e87c22eb60319ae25f1a73077'
    const feeSettings = createFeeSettings(
        feeBps,        
        collector 
    );

    await deployContract("ConcLiquidityVault", class_hash, {
        name: byteArray.byteArrayFromString(name),
        symbol: byteArray.byteArrayFromString(symbol),
        access_control: accessControl,
        ekubo_positions_contract: EKUBO_POSITIONS,
        bounds_settings: bounds,
        pool_key: poolKey,
        ekubo_positions_nft: EKUBO_POSITIONS_NFT,
        ekubo_core: EKUBO_CORE,
        oracle: ORACLE_OURS,
        fee_settings: feeSettings
    }, symbol);
}

async function rebalance() {
    // ! Ensure correct contract address
    const addr = '0x60bf566a17e5f3e82e21bf6a8cc2ed7956c867eb937e74c474b1ced2b403c58';
    const provider = getRpcProvider();
    const cls = await provider.getClassAt(addr);
    const contract = new Contract(cls.abi, addr, provider);

    // ! Ensure correct bounds
    const bounds = createBounds(
        priceToTick(1.033, true, 200, 18, 6),
        priceToTick(1.036, false, 200, 18, 6)
    );
    const swapInfo = await getSwapInfo(
        xSTRK,
        STRK,
        "0",
       addr,
        "0"
    );
    swapInfo.routes = []; // ! Add routes later
    const call = contract.populate('rebalance', [
        bounds,
        swapInfo
    ]);
    const acc = getAccount(ACCOUNT_NAME);
    const tx = await acc.execute([call]);
    console.log('Rebalance tx: ', tx.transaction_hash);
    await provider.waitForTransaction(tx.transaction_hash, {
        successStates: [TransactionExecutionStatus.SUCCEEDED]
    })
    console.log('Rebalance done');
}

async function upgrade() {
    const { class_hash } = await myDeclare("ConcLiquidityVault");
    // ! Ensure correct strategy
    const addr = EkuboCLVaultStrategies.find((strategy) => strategy.name.includes('xSTRK'))?.address.address;
    if (!addr) {
        throw new Error('No strategy found');
    }
    const cls = await getRpcProvider().getClassAt(addr);
    const contract = new Contract(cls.abi, addr, getRpcProvider());
    const acc = getAccount(accountKeyMap[SUPER_ADMIN]);

    const call = await contract.populate("upgrade", [class_hash]);
    const scheduleCall = await scheduleBatch([call], "0", "0x0", true);
    const executeCall = await executeBatch([call], "0", "0x0", true);
    const tx = await acc.execute([...scheduleCall, ...executeCall]);
    console.log(`Upgrade scheduled. tx: ${tx.transaction_hash}`);
    await getRpcProvider().waitForTransaction(tx.transaction_hash, {
        successStates: [TransactionExecutionStatus.SUCCEEDED]
    });
    console.log(`Upgrade done`);
}

function getSortedTokens(token0: string, token1: string) {
    const _token0 = BigInt(num.getDecimalString(token0));
    const _token1 = BigInt(num.getDecimalString(token1));
    if (_token0 < _token1) {
        return [num.getHexString(token0), num.getHexString(token1)];
    } else {
        return [num.getHexString(token1), num.getHexString(token0)];
    }
}

// 0x104d7db720522a6
// 0x104d7db720522a6
if (require.main === module) {
    // deploy cl vault
    const myToken0 = xsBTC;
    const myToken1 = solvBTC;
    const decimals = 18;

    const [token0, token1] = getSortedTokens(myToken0, myToken1);
    console.log('token0', token0);
    console.log('token1', token1);
    const poolKey = createPoolKey(
        token0,
        token1,
        '34028236692093847977029636859101184',
        200,
        0
    );

    // if equal, price is in token1 per token0, i.e. token0 price / token1 price
    const minPrice = ContractAddr.from(myToken0).eqString(token0) ? 0.997 : 1;
    const maxPrice = ContractAddr.from(myToken0).eqString(token0) ? 1 : 1.003;

    const bounds = createBounds(
        priceToTick(minPrice, false, poolKey.tick_spacing, decimals, decimals),
        priceToTick(maxPrice, false, poolKey.tick_spacing, decimals, decimals)
    );

    console.log('bounds', bounds);
    console.log('Pool key: ', poolKey);
    declareAndDeployConcLiquidityVault(
        poolKey,
        bounds,
        1000, // 10% fee
        "0x06419f7DeA356b74bC1443bd1600AB3831b7808D1EF897789FacFAd11a172Da7", // fee collector
        "tEkubo xtBTC/tBTC",
        "tEkxtBTCtBTC",
     );
    // rebalance();

    // upgrade()
}