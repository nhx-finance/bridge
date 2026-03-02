import {
  cre,
  CronCapability,
  HTTPCapability,
  handler,
  Runner,
  type Runtime,
  type NodeRuntime,
  type HTTPPayload,
  TxStatus,
  hexToBase64,
  bytesToHex,
  decodeJson,
  consensusMedianAggregation,
} from "@chainlink/cre-sdk";
import { encodeFunctionData, getAddress } from "viem";

// ========================================
// CONFIG
// ========================================
type Config = {
  schedule: string;

  hederaMirrorUrl: string;
  sdkServerUrl: string;
  hederaKesyTokenId: string;

  sepoliaChainSelector: string;
  complianceConsumerAddress: string;
  authorizedEVMAddress: string;
};

// ========================================
// HTTP Trigger Payload Type
// ========================================
type UnfreezePayload = {
  evmAddress: string;
  reason: string;
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
// HTTP TRIGGER: On-demand address unfreeze
// ========================================

/**
 * HTTP handler: Called by the compliance server to unreject an address.
 *
 * Flow:
 *   1. Server POST → CRE Gateway (JWT-signed, authorized key)
 *   2. CRE delivers payload.input to this handler
 *   3. Handler encodes processReport(evmAddress, false) calldata
 *   4. DON signs + delivers to ComplianceConsumer on Sepolia
 *   5. ComplianceConsumer calls RejectPolicy.unrejectAddress()
 *   6. Return value sent back to server as HTTP response
 *
 * Expected payload: { "evmAddress": "0x...", "reason": "..." }
 */
const onUnfreezeTrigger = (runtime: Runtime<Config>, payload: HTTPPayload): string => {
  const config = runtime.config;
  const request = decodeJson(payload.input) as UnfreezePayload;

  runtime.log("=== KESY Unfreeze Trigger Received ===");
  runtime.log(`Address to unreject: ${request.evmAddress}`);
  runtime.log(`Reason: ${request.reason}`);

  let checksummedAddress: string;
  try {
    checksummedAddress = getAddress(request.evmAddress as `0x${string}`);
  } catch {
    runtime.log(`❌ Invalid EVM address: ${request.evmAddress}`);
    return JSON.stringify({ status: "error", message: `Invalid EVM address: ${request.evmAddress}` });
  }

  const calldata = encodeFunctionData({
    abi: ComplianceConsumerABI,
    functionName: "processReport",
    args: [checksummedAddress as `0x${string}`, false],
  });

  runtime.log(`Encoded processReport(${checksummedAddress}, false) calldata: ${calldata.slice(0, 20)}...`);

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
      gasConfig: { gasLimit: "200000" },
    })
    .result();

  const txHash = resp.txHash ? bytesToHex(resp.txHash) : "pending";

  if (resp.txStatus !== TxStatus.SUCCESS) {
    runtime.log(`⚠️ Unfreeze failed: ${resp.errorMessage || "unknown error"}`);
    return JSON.stringify({
      status: "error",
      address: checksummedAddress,
      message: resp.errorMessage || "unknown error",
    });
  }

  runtime.log(`✅ Address unrejected on Sepolia: ${checksummedAddress}`);
  runtime.log(`   Tx: ${txHash}`);
  runtime.log(`   Verify: https://sepolia.etherscan.io/tx/${txHash}`);

  return JSON.stringify({
    status: "success",
    address: checksummedAddress,
    reason: request.reason,
    txHash,
    etherscan: `https://sepolia.etherscan.io/tx/${txHash}`,
  });
};

// ========================================
// WORKFLOW INITIALIZATION
// ========================================

const initWorkflow = (config: Config) => {
  const cron = new CronCapability();
  const http = new HTTPCapability();

  return [
    // Trigger 1: Cron — polls SDK Server for freeze events every N seconds
    handler(
      cron.trigger({ schedule: config.schedule }),
      onComplianceSyncTrigger,
    ),
    // Trigger 2: HTTP — on-demand unfreeze called by compliance server
    handler(
      http.trigger(
        config.authorizedEVMAddress
          ? { authorizedKeys: [{ type: "KEY_TYPE_ECDSA_EVM", publicKey: config.authorizedEVMAddress }] }
          : {},
      ),
      onUnfreezeTrigger,
    ),
  ];
};

export async function main() {
  const runner = await Runner.newRunner<Config>();
  await runner.run(initWorkflow);
}
