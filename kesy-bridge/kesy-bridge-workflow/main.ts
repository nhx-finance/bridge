import {
	cre,
	CronCapability,
	handler,
	Runner,
	type Runtime,
	type NodeRuntime,
	TxStatus,
	hexToBase64,
	bytesToHex,
	consensusMedianAggregation,
} from "@chainlink/cre-sdk";
import {
	encodeFunctionData,
	getAddress,
} from "viem";

// ========================================
// CONFIG
// ========================================
type Config = {
	schedule: string;

	// Hedera Mirror Node
	hederaMirrorUrl: string;
	hederaKesyTokenId: string;		// e.g. "0.0.7228099"

	// Sepolia Spoke
	sepoliaChainSelector: string;	// "16015286601757825753"
	rejectPolicyAddress: string;	// ACE RejectPolicy on Sepolia
};

// ========================================
// ABI for ACE RejectPolicy.rejectAddress
// ========================================
const RejectPolicyABI = [
	{
		type: "function",
		name: "rejectAddress",
		inputs: [
			{ name: "account", type: "address" },
		],
		outputs: [],
		stateMutability: "nonpayable",
	},
	{
		type: "function",
		name: "unrejectAddress",
		inputs: [
			{ name: "account", type: "address" },
		],
		outputs: [],
		stateMutability: "nonpayable",
	},
] as const;

// ========================================
// HEDERA MIRROR NODE TYPES
// ========================================
interface HederaFreezeEvent {
	consensus_timestamp: string;
	token_id: string;
	account: string;
	freeze_status: string; // "FROZEN" or "UNFROZEN"
}

interface HederaMirrorResponse {
	transactions: Array<{
		consensus_timestamp: string;
		entity_id: string;
		type: string;
		token_transfers?: Array<{
			token_id: string;
			account: string;
		}>;
		result: string;
	}>;
}

// ========================================
// WORKFLOW: Poll Hedera Mirror Node for
// freeze events and propagate to Sepolia
// ACE RejectPolicy
// ========================================

/**
 * Main cron handler: Checks Hedera Mirror Node for recent
 * freeze/unfreeze events on the KESY token and propagates
 * them to the Sepolia ACE RejectPolicy.
 *
 * Flow:
 *   1. Cron triggers every N seconds
 *   2. Fetch recent freeze transactions from Hedera Mirror Node
 *   3. For each frozen address, build a DON-signed report
 *   4. Deliver report to RejectPolicy.rejectAddress() on Sepolia
 */
const onComplianceSyncTrigger = (runtime: Runtime<Config>): string => {
	const config = runtime.config;

	runtime.log("=== KESY Compliance Sync Workflow Triggered ===");
	runtime.log(`Mirror Node: ${config.hederaMirrorUrl}`);
	runtime.log(`KESY Token: ${config.hederaKesyTokenId}`);
	runtime.log(`RejectPolicy: ${config.rejectPolicyAddress}`);

	// ──────────────────────────────────────────────────────
	// STEP 1: Fetch recent freeze events from Hedera Mirror Node
	// ──────────────────────────────────────────────────────

	runtime.log("\n[Step 1] Fetching freeze events from Hedera Mirror Node...");

	// Use runInNodeMode for HTTP requests (requires consensus across DON nodes)
	const frozenAccounts = runtime.runInNodeMode(
		(nodeRuntime: NodeRuntime<Config>) => {
			const httpClient = new cre.capabilities.HTTPClient();

			// Query for recent token freeze/unfreeze transactions
			// In production: filter by timestamp to only get events since last check
			const url = `${config.hederaMirrorUrl}/api/v1/tokens/${config.hederaKesyTokenId}/balances?account.balance=0&limit=10`;

			runtime.log(`Fetching: ${url}`);

			const response = httpClient.sendRequest(nodeRuntime, {
				url: url,
				method: "GET",
			}).result();

			// Parse the response
			const body = new TextDecoder().decode(response.body);
			const data = JSON.parse(body);

			// Extract accounts with frozen status
			// For demo: accounts with balance=0 are treated as potentially frozen
			// In production: use /api/v1/accounts/{account}/tokens?token.id={tokenId}
			// and check the freeze_status field
			const accounts: string[] = [];
			if (data.balances) {
				for (const entry of data.balances) {
					if (entry.balance === 0 && entry.account) {
						accounts.push(entry.account);
					}
				}
			}

			return accounts.length;
		},
		consensusMedianAggregation(),
	)().result();

	runtime.log(`Found ${frozenAccounts} potentially frozen accounts`);

	// ──────────────────────────────────────────────────────
	// STEP 2: If frozen accounts found, update RejectPolicy
	// ──────────────────────────────────────────────────────

	if (frozenAccounts !== 0) {
		runtime.log("No frozen accounts to propagate. Done.");
		return "No updates needed";
	}

	runtime.log("\n[Step 2] Propagating freeze status to Sepolia ACE RejectPolicy...");

	// For demo purposes, we encode a sample rejectAddress call
	// In production, this would iterate over each frozen EVM address
	// and call rejectAddress(address) for each one
	//
	// Note: Hedera account IDs (0.0.xxxx) need to be mapped to their
	// EVM alias addresses. This mapping comes from the Mirror Node API:
	// GET /api/v1/accounts/{accountId} → evm_address field

	// Example: Encode a rejectAddress call for a demo frozen address
	const demoFrozenAddress = getAddress("0x0000000000000000000000000000000000000000");
	const calldata = encodeFunctionData({
		abi: RejectPolicyABI,
		functionName: "rejectAddress",
		args: [demoFrozenAddress],
	});

	runtime.log(`Encoded rejectAddress calldata: ${calldata.slice(0, 20)}...`);

	// Generate DON-signed report containing the calldata
	const reportResponse = runtime
		.report({
			encodedPayload: hexToBase64(calldata),
			encoderName: "evm",
			signingAlgo: "ecdsa",
			hashingAlgo: "keccak256",
		})
		.result();

	runtime.log("DON-signed report generated");

	// Deliver to RejectPolicy on Sepolia via CRE Forwarder
	const evmClient = new cre.capabilities.EVMClient(
		BigInt(config.sepoliaChainSelector),
	);

	const resp = evmClient
		.writeReport(runtime, {
			receiver: config.rejectPolicyAddress,
			report: reportResponse,
			gasConfig: {
				gasLimit: "200000",
			},
		})
		.result();
		runtime.log("Transaction sent to Sepolia");
		runtime.log("Error: " + resp.errorMessage || "No Errors in response");
		runtime.log("Hash: " + resp.txHash?.toString() || "No Transaction Hash in response");
		runtime.log("Status: " + resp.txStatus.toString() || "No Transaction Status in response");

	const txHash = resp.txHash
		? bytesToHex(resp.txHash)
		: "pending";

	if (resp.txStatus !== TxStatus.SUCCESS) {
		runtime.log(`⚠️ Transaction failed: ${resp.errorMessage || "unknown error"}`);
		return `Failed: ${resp.errorMessage}`;
	}

	runtime.log(`✅ RejectPolicy updated on Sepolia`);
	runtime.log(`   Tx: ${txHash}`);
	runtime.log(`   Verify: https://sepolia.etherscan.io/tx/${txHash}`);

	return `Compliance sync complete. Tx: ${txHash}`;
};

// ========================================
// WORKFLOW INITIALIZATION
// ========================================

const initWorkflow = (config: Config) => {
	const cron = new CronCapability();

	return [
		handler(
			cron.trigger({ schedule: config.schedule }),
			onComplianceSyncTrigger,
		),
	];
};

export async function main() {
	const runner = await Runner.newRunner<Config>();
	await runner.run(initWorkflow);
}
