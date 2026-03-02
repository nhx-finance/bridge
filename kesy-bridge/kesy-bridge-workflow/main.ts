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
import { encodeFunctionData, getAddress } from "viem";

// ========================================
// CONFIG
// ========================================
type Config = {
  schedule: string;

  // Stablecoin SDK Server
  hederaMirrorUrl: string;
  sdkServerUrl: string;
  hederaKesyTokenId: string;

  // Sepolia Spoke
  sepoliaChainSelector: string;
  	complianceConsumerAddress: string;	// ComplianceConsumer on Sepolia (owns RejectPolicy)
};

type Account = {
  accountId: string;
  evmAddress: string;
  frozenDate: string | null;
  freezeReason: string | null;
  status: string;
  isWiped: boolean;
  createdAt: string;
  updatedAt: string;
};

type FrozenAccountResponse = {
  recentFrozenOrWipedAccounts: Account[];
};

const SDK_API_KEY = "SDK_API_KEY";

// ========================================
// ABI for ComplianceConsumer.processReport
// ========================================
const ComplianceConsumerABI = [
	{
		type: "function",
		name: "processReport",
		inputs: [
			{ name: "account", type: "address" },
			{ name: "reject", type: "bool" },
		],
		outputs: [],
		stateMutability: "nonpayable",
	},
] as const;

// ========================================
// WORKFLOW: Poll our SDK Server for
// freeze events and propagate to Sepolia
// ACE RejectPolicy
// ========================================

/**
 * Main cron handler: Checks SDK Server for recent
 * freeze/unfreeze events on the KESY token and propagates
 * them to the Sepolia ACE RejectPolicy.
 *
 * Flow:
 *   1. Cron triggers every N seconds
 *   2. Fetch recent freeze transactions from Stablecoin SDK Server
 *   3. For each frozen address, build a DON-signed report
 *   4. Deliver report to RejectPolicy.rejectAddress() on Sepolia
 */
const onComplianceSyncTrigger = (runtime: Runtime<Config>): string => {
  const config = runtime.config;
  const secret = runtime.getSecret({ id: SDK_API_KEY }).result().value;
  let frozenOrWipedAccounts: Account[] = [];
  let calldatas: string[] = [];

  runtime.log("=== KESY Compliance Sync Workflow Triggered ===");
  runtime.log(`SDK Server: ${config.sdkServerUrl}`);
  runtime.log(`KESY Token: ${config.hederaKesyTokenId}`);
  	runtime.log(`ComplianceConsumer: ${config.complianceConsumerAddress}`);

  // ──────────────────────────────────────────────────────
  // STEP 1: Fetch recent freeze events from our SDK Server
  // ──────────────────────────────────────────────────────

  runtime.log(
    "\n[Step 1] Fetching recently frozen accounts from our SDK Server...",
  );

  const frozenAccounts = runtime
    .runInNodeMode((nodeRuntime: NodeRuntime<Config>) => {
      const httpClient = new cre.capabilities.HTTPClient();

      const url = config.sdkServerUrl;

      runtime.log(`Fetching: ${url}`);

      const response = httpClient
        .sendRequest(nodeRuntime, {
          url: url,
          method: "GET",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${secret}`,
          },
        })
        .result();

      const body = new TextDecoder().decode(response.body);
      const data = JSON.parse(body) as FrozenAccountResponse;
      if (data.recentFrozenOrWipedAccounts.length === 0) {
        runtime.log("No frozen accounts found in SDK Server response");
        return 0;
      }
      runtime.log(
        `Received ${data.recentFrozenOrWipedAccounts.length} frozen accounts from SDK Server`,
      );

      frozenOrWipedAccounts = data.recentFrozenOrWipedAccounts;

      return data.recentFrozenOrWipedAccounts.length;
    }, consensusMedianAggregation())()
    .result();

  runtime.log(`Found ${frozenAccounts} potentially frozen accounts`);

  // ──────────────────────────────────────────────────────
  	// STEP 2: If frozen accounts found, update ComplianceConsumer → RejectPolicy
  // ──────────────────────────────────────────────────────

  if (frozenAccounts === 0) {
    runtime.log("No frozen accounts to propagate. Done.");
    return "No updates needed";
  }

  	runtime.log(
		"\n[Step 2] Propagating freeze status to Sepolia ComplianceConsumer → RejectPolicy...",
	);

  frozenOrWipedAccounts.forEach((account, index) => {
    runtime.log(
      `Account ${index + 1}: ${account.evmAddress} | Status: ${account.status} | Frozen Date: ${account.frozenDate}`,
    );
    const evmAddress = `${account.evmAddress}` as `0x${string}`;
    runtime.log(`Validating EVM address: ${evmAddress}`);
    try {
      const checksummedAddress = getAddress(evmAddress);
      runtime.log(`Checksummed address: ${checksummedAddress}`);
    } catch (error) {
      runtime.log(`Invalid EVM address: ${evmAddress}. Skipping...`);
      return;
    }
		const calldata = encodeFunctionData({
			abi: ComplianceConsumerABI,
			functionName: "processReport",
			args: [evmAddress, true],
		});
		runtime.log(`Encoded processReport calldata: ${calldata.slice(0, 20)}...`);
    calldatas.push(calldata);

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

    const evmClient = new cre.capabilities.EVMClient(
      BigInt(config.sepoliaChainSelector),
    );

    const resp = evmClient
      .writeReport(runtime, {
  			receiver: config.complianceConsumerAddress,
        report: reportResponse,
        gasConfig: {
          gasLimit: "200000",
        },
      })
      .result();
    runtime.log("Transaction sent to Sepolia");
    runtime.log("Error: " + resp.errorMessage || "No Errors in response");
    runtime.log(
      "Hash: " + resp.txHash?.toString() || "No Transaction Hash in response",
    );
    runtime.log(
      "Status: " + resp.txStatus.toString() ||
        "No Transaction Status in response",
    );

    const txHash = resp.txHash ? bytesToHex(resp.txHash) : "pending";

    if (resp.txStatus !== TxStatus.SUCCESS) {
      runtime.log(
        `⚠️ Transaction failed: ${resp.errorMessage || "unknown error"}`,
      );
      return `Failed: ${resp.errorMessage}`;
    }

		runtime.log(`✅ ComplianceConsumer → RejectPolicy updated on Sepolia`);
    runtime.log(`   Tx: ${txHash}`);
    runtime.log(`   Verify: https://sepolia.etherscan.io/tx/${txHash}`);
  });

  return `Compliance sync complete. Txns: ${calldatas.length}`;
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
