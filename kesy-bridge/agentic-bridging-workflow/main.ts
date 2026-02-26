import {
	cre,
	HTTPCapability,
	handler,
	Runner,
	type Runtime,
	type NodeRuntime,
	type HTTPPayload,
	decodeJson,
	consensusMedianAggregation,
} from "@chainlink/cre-sdk";
import {
	encodeFunctionData,
	getAddress,
	formatUnits,
} from "viem";

// ========================================
// CONFIG
// ========================================
type Config = {
	// Tenderly Virtual TestNet for bridge simulation
	tenderlyRpcUrl: string;

	// Gemini AI API key for natural language analysis
	geminiApiKey: string;

	// Deployed contract addresses (Sepolia)
	spokeBridgeAddress: string;
	wKesyAddress: string;
	policyEngineAddress: string;
	rejectPolicyAddress: string;
	volumePolicyAddress: string;

	// Hedera Hub Bridge
	hubBridgeAddress: string;

	// Authorized EVM address (for HTTP trigger auth)
	authorizedEVMAddress: string;
};

// ========================================
// TYPES
// ========================================
type BridgeSimRequest = {
	sourceChain: string;		// e.g. "sepolia", "hedera"
	destChain: string;			// e.g. "hedera", "sepolia"
	amount: string;				// amount in human-readable (e.g. "100")
	senderAddress: string;		// sender EVM address
	receiverAddress: string;	// receiver address
};

type SimulationResult = {
	success: boolean;
	gasUsed: string;
	error: string | null;
	logs: string[];
	returnData: string;
};

// ========================================
// ABIs for simulation
// ========================================
const BridgeABI = [
	{
		type: "function",
		name: "bridgeKESY",
		inputs: [
			{ name: "destinationChainSelector", type: "uint64" },
			{ name: "receiver", type: "bytes" },
			{ name: "amount", type: "uint256" },
		],
		outputs: [{ name: "messageId", type: "bytes32" }],
		stateMutability: "nonpayable",
	},
] as const;

const ERC20ABI = [
	{
		type: "function",
		name: "balanceOf",
		inputs: [{ name: "account", type: "address" }],
		outputs: [{ name: "", type: "uint256" }],
		stateMutability: "view",
	},
	{
		type: "function",
		name: "allowance",
		inputs: [
			{ name: "owner", type: "address" },
			{ name: "spender", type: "address" },
		],
		outputs: [{ name: "", type: "uint256" }],
		stateMutability: "view",
	},
] as const;

const RejectPolicyABI = [
	{
		type: "function",
		name: "addressRejected",
		inputs: [{ name: "account", type: "address" }],
		outputs: [{ name: "", type: "bool" }],
		stateMutability: "view",
	},
] as const;

// ========================================
// CHAIN SELECTORS
// ========================================
const CHAIN_SELECTORS: Record<string, string> = {
	"sepolia": "16015286601757825753",
	"hedera": "222782988166878823",
};

// ========================================
// AGENTIC BRIDGING HANDLER
// ========================================
const onAgenticBridge = (runtime: Runtime<Config>, payload: HTTPPayload): string => {
	const config = runtime.config;
	const request = decodeJson<BridgeSimRequest>(payload.input);

	runtime.log("=== Agentic Bridging Workflow Triggered ===");
	runtime.log(`Source: ${request.sourceChain} → Dest: ${request.destChain}`);
	runtime.log(`Amount: ${request.amount} KESY`);
	runtime.log(`Sender: ${request.senderAddress}`);
	runtime.log(`Receiver: ${request.receiverAddress}`);

	// ──────────────────────────────────────────────────────
	// STEP 1: Validate bridge direction
	// ──────────────────────────────────────────────────────
	const src = request.sourceChain.toLowerCase();
	const dst = request.destChain.toLowerCase();

	if (src === "hedera") {
		runtime.log("⚠️ Hedera → EVM simulation not available (Tenderly does not support Hedera Virtual TestNets)");
		const earlyResult = JSON.stringify({
			status: "unsupported",
			direction: `${src} → ${dst}`,
			message: "Simulation for Hedera → EVM bridges is not available yet. Tenderly Virtual TestNets do not support Hedera. The bridge would lock KESY on Hedera Hub and mint wKESY on the destination EVM chain via CCIP. Please proceed with the actual bridge — your tokens are protected by Chainlink ACE policies on the destination chain.",
			recommendation: "proceed_with_actual_bridge",
		});
		return earlyResult;
	}

	if (!CHAIN_SELECTORS[dst]) {
		return JSON.stringify({
			status: "error",
			message: `Unknown destination chain: ${dst}. Supported: ${Object.keys(CHAIN_SELECTORS).join(", ")}`,
		});
	}

	runtime.log(`\n[Step 1] Direction validated: ${src} → ${dst} (EVM → Hedera/EVM)`);

	// ──────────────────────────────────────────────────────
	// STEP 2: Run pre-flight checks on Tenderly Virtual TestNet
	// ──────────────────────────────────────────────────────
	runtime.log("\n[Step 2] Running pre-flight checks on Tenderly Virtual TestNet...");

	const amountRaw = BigInt(parseFloat(request.amount) * 1e6).toString(16).padStart(64, "0");
	const senderAddr = request.senderAddress.toLowerCase().replace("0x", "").padStart(64, "0");

	// Check wKESY balance
	const balanceCalldata = encodeFunctionData({
		abi: ERC20ABI,
		functionName: "balanceOf",
		args: [getAddress(request.senderAddress)],
	});

	// Check if sender is blacklisted
	const rejectCalldata = encodeFunctionData({
		abi: RejectPolicyABI,
		functionName: "addressRejected",
		args: [getAddress(request.senderAddress)],
	});

	// Check if receiver is blacklisted
	const receiverRejectCalldata = encodeFunctionData({
		abi: RejectPolicyABI,
		functionName: "addressRejected",
		args: [getAddress(request.receiverAddress)],
	});

	// Run all pre-flight checks via DON consensus
	const preflightResults = runtime.runInNodeMode(
		(nodeRuntime: NodeRuntime<Config>) => {
			const httpClient = new cre.capabilities.HTTPClient();

			// Helper to make eth_call via Tenderly RPC
			const ethCall = (to: string, data: string): string => {
				const response = httpClient.sendRequest(nodeRuntime, {
					url: config.tenderlyRpcUrl,
					method: "POST",
					body: new TextEncoder().encode(JSON.stringify({
						jsonrpc: "2.0",
						method: "eth_call",
						params: [{ to, data }, "latest"],
						id: 1,
					})),
					headers: { "Content-Type": "application/json" },
				}).result();

				const body = new TextDecoder().decode(response.body);
				const parsed = JSON.parse(body);
				return parsed.result || parsed.error?.message || "error";
			};

			// 1. Check wKESY balance
			const balanceResult = ethCall(config.wKesyAddress, balanceCalldata);

			// 2. Check sender blacklist status
			const senderRejected = ethCall(config.rejectPolicyAddress, rejectCalldata);

			// 3. Check receiver blacklist status
			const receiverRejected = ethCall(config.rejectPolicyAddress, receiverRejectCalldata);

			// Encode results as a delimited string for consensus
			return `${balanceResult}|${senderRejected}|${receiverRejected}`;
		},
		consensusMedianAggregation(),
	)().result();

	runtime.log(`Pre-flight results: ${preflightResults}`);

	// Parse pre-flight results
	const [balanceHex, senderRejectedHex, receiverRejectedHex] = String(preflightResults).split("|");

	const balance = balanceHex !== "error" ? BigInt(balanceHex) : BigInt(0);
	const senderBlacklisted = senderRejectedHex !== "error" && senderRejectedHex.endsWith("1");
	const receiverBlacklisted = receiverRejectedHex !== "error" && receiverRejectedHex.endsWith("1");
	const amountWei = BigInt(parseFloat(request.amount) * 1e6);
	const hasBalance = balance >= amountWei;

	runtime.log(`Balance: ${formatUnits(balance, 6)} wKESY (need ${request.amount})`);
	runtime.log(`Sender blacklisted: ${senderBlacklisted}`);
	runtime.log(`Receiver blacklisted: ${receiverBlacklisted}`);
	runtime.log(`Has sufficient balance: ${hasBalance}`);

	// ──────────────────────────────────────────────────────
	// STEP 3: Simulate the bridge transaction
	// ──────────────────────────────────────────────────────
	runtime.log("\n[Step 3] Simulating bridge transaction on Tenderly...");

	const bridgeCalldata = encodeFunctionData({
		abi: BridgeABI,
		functionName: "bridgeKESY",
		args: [
			BigInt(CHAIN_SELECTORS[dst]),
			`0x${senderAddr}` as `0x${string}`,
			amountWei,
		],
	});

	const simResult = runtime.runInNodeMode(
		(nodeRuntime: NodeRuntime<Config>) => {
			const httpClient = new cre.capabilities.HTTPClient();

			const response = httpClient.sendRequest(nodeRuntime, {
				url: config.tenderlyRpcUrl,
				method: "POST",
				body: new TextEncoder().encode(JSON.stringify({
					jsonrpc: "2.0",
					method: "eth_call",
					params: [{
						from: request.senderAddress,
						to: config.spokeBridgeAddress,
						data: bridgeCalldata,
						gas: "0x7A120", // 500k gas
					}, "latest"],
					id: 2,
				})),
				headers: { "Content-Type": "application/json" },
			}).result();

			const body = new TextDecoder().decode(response.body);
			return body;
		},
		consensusMedianAggregation(),
	)().result();

	runtime.log(`Simulation result: ${String(simResult).slice(0, 200)}...`);

	// ──────────────────────────────────────────────────────
	// STEP 4: Send everything to Gemini AI for analysis
	// ──────────────────────────────────────────────────────
	runtime.log("\n[Step 4] Sending simulation data to Gemini AI for analysis...");

	const analysisPrompt = `You are an AI assistant for the KESY cross-chain bridge system. Analyze this bridge simulation and provide a clear, user-friendly summary.

## Bridge Request
- Direction: ${request.sourceChain} → ${request.destChain}
- Amount: ${request.amount} KESY (6 decimals)
- Sender: ${request.senderAddress}
- Receiver: ${request.receiverAddress}

## Pre-flight Check Results
- Sender wKESY Balance: ${formatUnits(balance, 6)} wKESY
- Has Sufficient Balance: ${hasBalance}
- Sender Blacklisted (ACE RejectPolicy): ${senderBlacklisted}
- Receiver Blacklisted (ACE RejectPolicy): ${receiverBlacklisted}

## Bridge Simulation (Tenderly Virtual TestNet)
Raw result: ${String(simResult).slice(0, 500)}

## System Context
- This bridge uses Chainlink CCIP for cross-chain messaging
- wKESY is protected by Chainlink ACE (Automated Compliance Engine)
- ACE policies: RejectPolicy (address blacklist) + VolumePolicy (min/max transfer caps)
- The bridge burns wKESY on Sepolia and unlocks native KESY on Hedera via CCIP

## Instructions
1. Summarize whether the bridge would succeed or fail
2. If it would fail, explain exactly why (insufficient balance, blacklisted, policy violation, etc.)
3. Estimate approximate costs (CCIP fee in LINK, gas costs)
4. Provide a confidence level (high/medium/low) for the simulation accuracy
5. If there are any compliance concerns, flag them clearly
6. Keep the response conversational and under 200 words
7. Use emojis sparingly for visual clarity`;

	const geminiResponse = runtime.runInNodeMode(
		(nodeRuntime: NodeRuntime<Config>) => {
			const httpClient = new cre.capabilities.HTTPClient();

			const geminiUrl = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${config.geminiApiKey}`;

			const response = httpClient.sendRequest(nodeRuntime, {
				url: geminiUrl,
				method: "POST",
				body: new TextEncoder().encode(JSON.stringify({
					contents: [{
						parts: [{ text: analysisPrompt }],
					}],
					generationConfig: {
						temperature: 0.3,
						maxOutputTokens: 512,
					},
				})),
				headers: { "Content-Type": "application/json" },
			}).result();

			const body = new TextDecoder().decode(response.body);
			return body;
		},
		consensusMedianAggregation(),
	)().result();

	// Parse Gemini response
	let aiAnalysis = "Unable to parse AI response";
	try {
		const geminiData = JSON.parse(String(geminiResponse));
		if (geminiData.candidates?.[0]?.content?.parts?.[0]?.text) {
			aiAnalysis = geminiData.candidates[0].content.parts[0].text;
		}
	} catch {
		aiAnalysis = `Raw AI response: ${String(geminiResponse).slice(0, 500)}`;
	}

	runtime.log(`\n[Step 5] Gemini Analysis:\n${aiAnalysis}`);

	// ──────────────────────────────────────────────────────
	// STEP 5: Return structured response
	// ──────────────────────────────────────────────────────
	const response = JSON.stringify({
		status: "simulated",
		direction: `${request.sourceChain} → ${request.destChain}`,
		amount: request.amount,
		sender: request.senderAddress,
		receiver: request.receiverAddress,
		preflight: {
			balance: formatUnits(balance, 6),
			hasSufficientBalance: hasBalance,
			senderBlacklisted,
			receiverBlacklisted,
		},
		aiAnalysis,
		timestamp: Date.now(),
	});

	return response;
};

// ========================================
// WORKFLOW INITIALIZATION
// ========================================
const initWorkflow = (config: Config) => {
	const httpTrigger = new HTTPCapability();

	return [
		handler(
			httpTrigger.trigger({
				authorizedKeys: config.authorizedEVMAddress
					? [{
						type: "KEY_TYPE_ECDSA_EVM",
						publicKey: config.authorizedEVMAddress,
					}]
					: [],
			}),
			onAgenticBridge,
		),
	];
};

export async function main() {
	const runner = await Runner.newRunner<Config>();
	await runner.run(initWorkflow);
}
