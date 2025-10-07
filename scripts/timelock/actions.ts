import { Call, Contract, hash, TransactionExecutionStatus } from "starknet";
import { getAccount, getRpcProvider } from "../lib/utils";
import { accountKeyMap, SUPER_ADMIN, TIMELOCK, TIMELOCK_DELAY } from "../lib/constants";

function processCalls(calls: Call[]) {
    return calls.map((call) => {
        return {
            to: call.contractAddress,
            selector: hash.getSelectorFromName(call.entrypoint),
            calldata: call.calldata
        }
    })
}

export async function scheduleBatch(
    calls: Call[],
    salt: string, // same salt to be used while executing the batch
    predecessor: string = "0x0", // if provided, should be of a batch that is from past
    justReturnCalls: boolean = false
) {
    const provider = getRpcProvider();
    const timelockCls = await provider.getClassAt(TIMELOCK);
    const timelock = new Contract({abi: timelockCls.abi, address: TIMELOCK, providerOrAccount: provider});

    if (predecessor !== "0x0") {
        const is_operation: any = await timelock.call("is_operation", [predecessor]);
        console.log(`Predecessor is an operation: ${is_operation}`);
        if (is_operation != true) {
            throw new Error(`Predecessor is not an operation`);
        }
    }
    const _calls = processCalls(calls);
    const call = timelock.populate("schedule_batch", [_calls, predecessor, salt, TIMELOCK_DELAY]);
    const acc = getAccount(accountKeyMap[SUPER_ADMIN]);
    const gas = await acc.estimateInvokeFee([call]);
    console.log(`Estimated gas: ${gas.overall_fee}`);
    if (justReturnCalls) {
        return [call];
    }
    const tx = await acc.execute([call]);
    console.log(`Batch scheduled. tx: ${tx.transaction_hash}`);
    await provider.waitForTransaction(tx.transaction_hash, {
        successStates: [TransactionExecutionStatus.SUCCEEDED]
    });
    console.log(`Batch scheduled`);
}

export async function executeBatch(
    calls: Call[],
    salt: string,
    predecessor: string = "0x0", // if provided, should be of a batch that is from past
    justReturnCalls: boolean = false
) {
    const provider = getRpcProvider();
    const timelockCls = await provider.getClassAt(TIMELOCK);
    const timelock = new Contract({abi: timelockCls.abi, address: TIMELOCK, providerOrAccount: provider});

    if (predecessor !== "0x0") {
        const is_operation: any = await timelock.call("is_operation", [salt]);
        console.log(`Predecessor is an operation: ${is_operation}`);
        if (is_operation != true) {
            throw new Error(`Operation is not an operation`);
        }
    }
    console.log(`Executing batch`, calls);
    const _calls = processCalls(calls);
    const call = timelock.populate("execute_batch", [_calls, predecessor, salt]);
    if (justReturnCalls) {
        return [call];
    }
    const acc = getAccount(accountKeyMap[SUPER_ADMIN]);
    const tx = await acc.execute([call]);
    console.log(`Batch execution. tx: ${tx.transaction_hash}`);
    await provider.waitForTransaction(tx.transaction_hash, {
        successStates: [TransactionExecutionStatus.SUCCEEDED]
    });
    console.log(`Batch executed`);
}

// todo add monitor on role changes of timelock
// todo Double check: the self ownership of timelock role doesnt cause issues