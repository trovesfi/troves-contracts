import { ACCOUNT_NAME, deployContract, getAccount, getRpcProvider, getSwapInfo, myDeclare } from "../lib/utils";
import { EKUBO_POSITIONS, EKUBO_CORE, EKUBO_POSITIONS_NFT, ORACLE_OURS, wstETH, ETH, ACCESS_CONTROL, xSTRK, STRK, accountKeyMap, SUPER_ADMIN, USDC, USDT} from "../lib/constants";
import { byteArray, Call, Contract, TransactionExecutionStatus, uint256 } from "starknet";
import { ContractAddr, EkuboCLVault, EkuboCLVaultStrategies, getMainnetConfig, Global, PricerFromApi, TokenInfo } from "@strkfarm/sdk";
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

async function deployRebalancer() {
    const { class_hash } = await myDeclare("ClVaultRebalancer");
    await deployContract("ClVaultRebalancer", class_hash, {
        access_control: ACCESS_CONTROL,
    });
}

async function upgradeRebalancer() {
    const { class_hash } = await myDeclare("ClVaultRebalancer");
    const addr = '0x2b8572889935025b16ad39a9235d1c3c46bc2b5694de5d81338931149f39a0d';
    const cls = await getRpcProvider().getClassAt(addr);
    const contract = new Contract({abi: cls.abi, address: addr, providerOrAccount: getRpcProvider()});
    const acc = getAccount(accountKeyMap[SUPER_ADMIN]);

    const call = await contract.populate("upgrade", [class_hash]);
    const salt = '0x1';
    const scheduleCall = await scheduleBatch([call], salt, "0x0", true);
    const executeCall = await executeBatch([call], salt, "0x0", true);
    const tx = await acc.execute([...scheduleCall, ...executeCall]);
    console.log(`Upgrade scheduled. tx: ${tx.transaction_hash}`);
    await getRpcProvider().waitForTransaction(tx.transaction_hash, {
        successStates: [TransactionExecutionStatus.SUCCEEDED]
    });
    console.log(`Upgrade done`);
}

async function initializePools() {
  const ekuboCORE = '0x00000005dd3d2f4429af886cd1a3b08289dbcea99a294197e9eb43b0e0325b4b';

  const STRK = Global.getDefaultTokens().filter(t => t.symbol === 'STRK')[0].address;
  const USDC = ContractAddr.from('0x033068F6539f8e6e6b131e6B2B814e6c34A5224bC66947c47DaB9dFeE93b35fb'); // new
  const WBTC = Global.getDefaultTokens().filter(t => t.symbol === 'WBTC')[0].address;
  const ETH = Global.getDefaultTokens().filter(t => t.symbol === 'ETH')[0].address;
  const USDT = Global.getDefaultTokens().filter(t => t.symbol === 'USDT')[0].address;
  const USDCOld = Global.getDefaultTokens().filter(t => t.symbol === 'USDC')[0].address;
  const pools = [{
    token0: STRK,
    token1: USDC,
    strat: EkuboCLVaultStrategies.find(s => s.name.includes('STRK/USDC'))!
  }, {
    token0: USDC,
    token1: USDT,
    strat: EkuboCLVaultStrategies.find(s => s.name.includes('USDC/USDT'))!
  }, {
    token0: WBTC,
    token1: USDC,
    strat: EkuboCLVaultStrategies.find(s => s.name.includes('WBTC/USDC'))!
  }, {
    token0: ETH,
    token1: USDC,
    strat: EkuboCLVaultStrategies.find(s => s.name.includes('ETH/USDC'))!
  }];
    // }, {
  //   token0: STRK,
  //   token1: Global.getDefaultTokens().filter(t => t.symbol === 'xSTRK')[0].address,
  //   strat: EkuboCLVaultStrategies.find(s => s.name.includes('xSTRK/STRK'))!
  // }, {
  //   token0: STRK,
  //   token1: USDCOld,
  //   strat: EkuboCLVaultStrategies.find(s => s.name.includes('STRK/USDC'))!
  // }, {
  //   token0: ETH,
  //   token1: USDCOld,
  //   strat: EkuboCLVaultStrategies.find(s => s.name.includes('ETH/USDC'))!
  // }, {
  //   token0: WBTC,
  //   token1: USDCOld,
  //   strat: EkuboCLVaultStrategies.find(s => s.name.includes('WBTC/USDC'))!
  // }, {
  //   token0: USDC,
  //   token1: USDT,
  //   strat: EkuboCLVaultStrategies.find(s => s.name.includes('USDC/USDT'))!
  // }];

  console.log('Initializing pools...');
  const config = getMainnetConfig(process.env.RPC_URL!);
  const provider = getRpcProvider();
  const pricer = new PricerFromApi(config, await Global.getTokens());
  const acc = getAccount(ACCOUNT_NAME);
  const ekuboCls = await provider.getClassAt(ekuboCORE);
  const ekuboContract = new Contract({ abi: ekuboCls.abi, address: ekuboCORE, providerOrAccount: provider });
  const calls: Call[] = [];
  const newPoolKeys: any[] = [];
  for (const pool of pools) {
    if (!pool.strat) {
      throw new Error(`No strategy found for pool ${pool.token0}-${pool.token1}`);
    }

    // arrange ascending
    const token0 = BigInt(pool.token0.address) < BigInt(pool.token1.address) ? pool.token0 : pool.token1;
    const token1 = BigInt(pool.token0.address) < BigInt(pool.token1.address) ? pool.token1 : pool.token0;

    const mod = new EkuboCLVault(config, pricer, pool.strat);
    const poolKey = await mod.getPoolKey();
    console.log(`Initializing pool ${token0}-${token1}...`);

    const token0Info = USDC.eq(token0) ? { symbol: 'USDC', decimals: 6} as TokenInfo : await Global.getTokenInfoFromAddr(token0);
    const token1Info = USDC.eq(token1) ? { symbol: 'USDC', decimals: 6} as TokenInfo : await Global.getTokenInfoFromAddr(token1);
    const token0Price = await pricer.getPrice(token0Info.symbol);
    const token1Price = await pricer.getPrice(token1Info.symbol);
    console.log(`Token0: ${token0Info.symbol}, price: ${token0Price.price}`);
    console.log(`Token1: ${token1Info.symbol}, price: ${token1Price.price}`);

    const poolPrice = token0Price.price * (Math.pow(10, token1Info.decimals)) / (token1Price.price * (Math.pow(10, token0Info.decimals)));
    const tickSpacing = Number(poolKey.tick_spacing);
    const tick = Math.log(poolPrice) / Math.log(1.000001);
    const roundedTick = Math.floor(tick / tickSpacing) * tickSpacing;
    console.log(`Current price: ${poolPrice}, tick: ${tick}, rounded tick: ${roundedTick}`);
    const newPoolKey = {
        token0: token0.address,
        token1: token1.address,
        fee: poolKey.fee,
        tick_spacing: poolKey.tick_spacing,
        extension: poolKey.extension,
    };
    newPoolKeys.push({
      pool_key: newPoolKey,
      name: `${token0Info.symbol}/${token1Info.symbol}`
    });
    const data = [
      newPoolKey ,{
        mag: Math.abs(roundedTick),
        sign: roundedTick < 0 ? 1 : 0
      }
    ];
    const call = ekuboContract.populate('maybe_initialize_pool', data);
    calls.push(call);
  }
  console.log('New pool keys: ', newPoolKeys);
  // const tx = await acc.execute(calls);
  // console.log(`Initialize pools tx: ${tx.transaction_hash}`);
  // await provider.waitForTransaction(tx.transaction_hash, {
  //     successStates: [TransactionExecutionStatus.SUCCEEDED]
  // });
  // console.log('Initialize pools done');
}

// 0x104d7db720522a6
// 0x104d7db720522a6
if (require.main === module) {
    // deploy cl vault
    // const poolKey = createPoolKey(
    //     STRK,
    //     USDC,
    //     '170141183460469235273462165868118016',
    //     1000,
    //     0
    // );

    // const bounds = createBounds(
    //     priceToTick(0.10, false, poolKey.tick_spacing, 18, 6),
    //     priceToTick(0.12, false, poolKey.tick_spacing, 18, 6)
    // );

    // console.log('bounds', bounds);
    // console.log('Pool key: ', poolKey);
    // declareAndDeployConcLiquidityVault(
    //     poolKey,
    //     bounds,
    //     1000, // 10% fee
    //     "0x06419f7DeA356b74bC1443bd1600AB3831b7808D1EF897789FacFAd11a172Da7", // fee collector
    //     "tEkubo STRK/USDC",
    //     "tEkSTRKUSDC",
    //  );
    // rebalance();

    // upgrade()
    // deployRebalancer();
    // upgradeRebalancer()
    initializePools();
}