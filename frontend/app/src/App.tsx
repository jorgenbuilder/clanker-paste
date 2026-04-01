import { useState, useCallback, useRef } from "react";
import { createActor } from "./backend/api/backend";
import { getCanisterEnv } from "@icp-sdk/core/agent/canister-env";

interface CanisterEnv {
  readonly "PUBLIC_CANISTER_ID:backend": string;
}

const canisterEnv = getCanisterEnv<CanisterEnv>();
const canisterId = canisterEnv["PUBLIC_CANISTER_ID:backend"];

const backend = createActor(canisterId, {
  agentOptions: {
    rootKey: !import.meta.env.DEV ? canisterEnv!.IC_ROOT_KEY : undefined,
    shouldFetchRootKey: import.meta.env.DEV,
  },
});

type View = "create" | "result" | "view";
type InputMode = "text" | "file";

interface PasteResult {
  pasteId: string;
  paymentAddress: string;
  expectedAmount: string;
  chain: string;
  expiresAt: bigint;
}

function App() {
  const [view, setView] = useState<View>("create");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");

  // Create form state
  const [inputMode, setInputMode] = useState<InputMode>("text");
  const [content, setContent] = useState("");
  const [fileBytes, setFileBytes] = useState<Uint8Array | null>(null);
  const [fileContentType, setFileContentType] = useState("");
  const [fileName, setFileName] = useState("");
  const [title, setTitle] = useState("");
  const [duration, setDuration] = useState(7);
  const [chain, setChain] = useState("eth");
  const fileInputRef = useRef<HTMLInputElement>(null);

  // Result state
  const [result, setResult] = useState<PasteResult | null>(null);
  const [txHash, setTxHash] = useState("");

  // View paste state
  const [viewPasteId, setViewPasteId] = useState("");
  const [viewContent, setViewContent] = useState("");
  const [, setViewContentType] = useState("");
  const [viewImageUrl, setViewImageUrl] = useState("");

  const handleFileSelect = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    if (file.size > 1_048_576) {
      setError("File too large. Max 1MB.");
      return;
    }
    setFileName(file.name);
    setFileContentType(file.type || "application/octet-stream");
    const reader = new FileReader();
    reader.onload = () => {
      setFileBytes(new Uint8Array(reader.result as ArrayBuffer));
    };
    reader.readAsArrayBuffer(file);
  }, []);

  const createPaste = useCallback(async () => {
    setLoading(true);
    setError("");
    try {
      let bytes: Uint8Array;
      let ct: string;

      if (inputMode === "file") {
        if (!fileBytes) {
          setError("No file selected");
          setLoading(false);
          return;
        }
        bytes = fileBytes;
        ct = fileContentType;
      } else {
        bytes = new TextEncoder().encode(content);
        ct = "text/plain";
      }

      const res = await backend.createPaste({
        content: bytes,
        contentType: ct,
        title: title || fileName || "Untitled",
        durationDays: BigInt(duration),
        paymentChain: chain,
      });
      setResult({
        pasteId: res.pasteId,
        paymentAddress: res.paymentAddress,
        expectedAmount: res.expectedAmount,
        chain: res.chain,
        expiresAt: res.expiresAt,
      });
      setView("result");
    } catch (e: any) {
      setError(e.message || "Failed to create paste");
    } finally {
      setLoading(false);
    }
  }, [content, fileBytes, fileContentType, fileName, inputMode, title, duration, chain]);

  const confirmPayment = useCallback(async () => {
    if (!result) return;
    setLoading(true);
    try {
      const confirmed = await backend.confirmPayment(result.pasteId, txHash.trim());
      if (confirmed) {
        setError("");
        alert("Payment confirmed! Your paste is now live.");
      } else {
        setError("Payment verification failed. Check your tx hash and try again.");
      }
    } catch (e: any) {
      setError(e.message || "Failed to confirm");
    } finally {
      setLoading(false);
    }
  }, [result, txHash]);

  const loadPaste = useCallback(async () => {
    setLoading(true);
    setError("");
    setViewContent("");
    setViewImageUrl("");
    try {
      // Get metadata first to know the content type
      const info: any = await backend.getPasteInfo(viewPasteId);
      if (!info || info.length === 0 || !info[0]) {
        setError("Paste not found, expired, or payment pending");
        setLoading(false);
        return;
      }
      const meta = info[0];
      setViewContentType(meta.contentType);

      const res: any = await backend.getPasteContent(viewPasteId);
      if (!res || res.length === 0 || !res[0]) {
        setError("Paste not found, expired, or payment pending");
        return;
      }

      const data = new Uint8Array(res[0]);

      if (meta.contentType.startsWith("image/")) {
        // Create a blob URL for images
        const blob = new Blob([data], { type: meta.contentType });
        setViewImageUrl(URL.createObjectURL(blob));
      } else {
        setViewContent(new TextDecoder().decode(data));
      }
    } catch (e: any) {
      setError(e.message || "Failed to load paste");
    } finally {
      setLoading(false);
    }
  }, [viewPasteId]);

  const formatAmount = (amount: string, chain: string) => {
    if (amount === "0") return "FREE";
    switch (chain) {
      case "eth":
        return `${(Number(amount) / 1e18).toFixed(8)} ETH`;
      case "usdc":
        return `${(Number(amount) / 1e6).toFixed(4)} USDC`;
      case "btc":
        return `${Number(amount)} sats`;
      default:
        return amount;
    }
  };

  const hasContent = inputMode === "text" ? content.length > 0 : fileBytes !== null;

  // Backend canister ID for raw HTTP links
  const backendCanisterId = "245pc-kaaaa-aaaas-qgfpq-cai";

  return (
    <div className="min-h-screen bg-zinc-950 text-zinc-100">
      <header className="border-b border-zinc-800 px-6 py-4">
        <div className="max-w-2xl mx-auto flex items-center justify-between">
          <h1
            className="text-xl font-bold tracking-tight cursor-pointer"
            onClick={() => {
              setView("create");
              setResult(null);
              setViewContent("");
              setViewImageUrl("");
              setError("");
            }}
          >
            <span className="text-green-400">Clanker</span>Paste
          </h1>
          <div className="flex gap-2">
            <button
              onClick={() => setView("create")}
              className={`px-3 py-1.5 text-sm rounded ${
                view === "create"
                  ? "bg-green-500/20 text-green-400"
                  : "text-zinc-400 hover:text-zinc-200"
              }`}
            >
              New Paste
            </button>
            <button
              onClick={() => setView("view")}
              className={`px-3 py-1.5 text-sm rounded ${
                view === "view"
                  ? "bg-green-500/20 text-green-400"
                  : "text-zinc-400 hover:text-zinc-200"
              }`}
            >
              View Paste
            </button>
          </div>
        </div>
      </header>

      <main className="max-w-2xl mx-auto px-6 py-8">
        {error && (
          <div className="mb-4 p-3 bg-red-500/10 border border-red-500/30 rounded text-red-400 text-sm">
            {error}
          </div>
        )}

        {/* CREATE VIEW */}
        {view === "create" && (
          <div className="space-y-4">
            <input
              type="text"
              placeholder="Title (optional)"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              className="w-full px-3 py-2 bg-zinc-900 border border-zinc-700 rounded text-sm focus:outline-none focus:border-green-500"
            />

            {/* Text / File toggle */}
            <div className="flex gap-2">
              <button
                onClick={() => setInputMode("text")}
                className={`px-3 py-1 text-xs rounded ${
                  inputMode === "text"
                    ? "bg-zinc-700 text-zinc-100"
                    : "text-zinc-500 hover:text-zinc-300"
                }`}
              >
                Text
              </button>
              <button
                onClick={() => setInputMode("file")}
                className={`px-3 py-1 text-xs rounded ${
                  inputMode === "file"
                    ? "bg-zinc-700 text-zinc-100"
                    : "text-zinc-500 hover:text-zinc-300"
                }`}
              >
                Image / File
              </button>
            </div>

            {inputMode === "text" ? (
              <textarea
                placeholder="Paste your content here..."
                value={content}
                onChange={(e) => setContent(e.target.value)}
                rows={12}
                className="w-full px-3 py-2 bg-zinc-900 border border-zinc-700 rounded text-sm font-mono focus:outline-none focus:border-green-500 resize-y"
              />
            ) : (
              <div
                onClick={() => fileInputRef.current?.click()}
                className="w-full px-3 py-12 bg-zinc-900 border border-zinc-700 border-dashed rounded text-sm text-center cursor-pointer hover:border-green-500 transition-colors"
              >
                {fileName ? (
                  <div>
                    <p className="text-zinc-200">{fileName}</p>
                    <p className="text-xs text-zinc-500 mt-1">
                      {fileBytes ? `${(fileBytes.length / 1024).toFixed(1)} KB` : ""} — {fileContentType}
                    </p>
                  </div>
                ) : (
                  <p className="text-zinc-500">
                    Click to select an image or file (max 1MB)
                  </p>
                )}
                <input
                  ref={fileInputRef}
                  type="file"
                  className="hidden"
                  accept="image/*,text/*,application/*"
                  onChange={handleFileSelect}
                />
              </div>
            )}

            <div className="flex gap-4 items-end">
              <div className="flex-1">
                <label className="block text-xs text-zinc-400 mb-1">Duration</label>
                <select
                  value={duration}
                  onChange={(e) => setDuration(Number(e.target.value))}
                  className="w-full px-3 py-2 bg-zinc-900 border border-zinc-700 rounded text-sm"
                >
                  <option value={1}>1 day</option>
                  <option value={7}>7 days</option>
                  <option value={30}>30 days</option>
                  <option value={90}>90 days</option>
                  <option value={365}>1 year</option>
                </select>
              </div>
              <div className="flex-1">
                <label className="block text-xs text-zinc-400 mb-1">Pay with</label>
                <select
                  value={chain}
                  onChange={(e) => setChain(e.target.value)}
                  className="w-full px-3 py-2 bg-zinc-900 border border-zinc-700 rounded text-sm"
                >
                  <option value="eth">Sepolia ETH</option>
                  <option value="usdc">Sepolia USDC</option>
                  <option value="btc">Testnet BTC</option>
                </select>
              </div>
              <button
                onClick={createPaste}
                disabled={loading || !hasContent}
                className="px-6 py-2 bg-green-600 hover:bg-green-500 disabled:opacity-50 rounded text-sm font-medium"
              >
                {loading ? "Creating..." : "Create Paste"}
              </button>
            </div>
            <p className="text-xs text-zinc-500">
              Pastes under 1KB are free. Larger pastes require payment.
              Content is stored on-chain and served via HTTP. Uncensorable.
            </p>
          </div>
        )}

        {/* RESULT VIEW */}
        {view === "result" && result && (
          <div className="space-y-4">
            <div className="p-4 bg-zinc-900 border border-zinc-700 rounded">
              <h2 className="text-lg font-medium mb-3">Paste Created</h2>
              <div className="space-y-2 text-sm">
                <div className="flex justify-between">
                  <span className="text-zinc-400">ID</span>
                  <span className="font-mono">{result.pasteId}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-zinc-400">Cost</span>
                  <span className="font-mono text-green-400">
                    {formatAmount(result.expectedAmount, result.chain)}
                  </span>
                </div>
                {result.expectedAmount !== "0" && (
                  <>
                    <div className="flex justify-between">
                      <span className="text-zinc-400">Pay to</span>
                      <span className="font-mono text-xs break-all">
                        {result.paymentAddress}
                      </span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-zinc-400">Amount</span>
                      <span className="font-mono">
                        {result.expectedAmount} {result.chain === "btc" ? "sats" : "wei"}
                      </span>
                    </div>
                    <div className="mt-4 p-3 bg-yellow-500/10 border border-yellow-500/30 rounded text-yellow-400 text-xs">
                      Send exactly the amount above to the payment address on Sepolia testnet. Then paste your tx hash below.
                    </div>
                    <input
                      type="text"
                      placeholder="0x... transaction hash"
                      value={txHash}
                      onChange={(e) => setTxHash(e.target.value)}
                      className="w-full mt-2 px-3 py-2 bg-zinc-800 border border-zinc-600 rounded text-xs font-mono focus:outline-none focus:border-green-500"
                    />
                    <button
                      onClick={confirmPayment}
                      disabled={loading || !txHash}
                      className="w-full mt-2 px-4 py-2 bg-green-600 hover:bg-green-500 disabled:opacity-50 rounded text-sm font-medium"
                    >
                      {loading ? "Verifying on Sepolia..." : "Verify Payment"}
                    </button>
                  </>
                )}
                <div className="mt-4 p-3 bg-zinc-800 rounded space-y-2">
                  <div>
                    <p className="text-xs text-zinc-400 mb-1">Direct link (raw HTTP):</p>
                    <code className="text-xs text-green-400 break-all">
                      https://{backendCanisterId}.raw.icp0.io/p/{result.pasteId}
                    </code>
                  </div>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* VIEW PASTE */}
        {view === "view" && (
          <div className="space-y-4">
            <div className="flex gap-2">
              <input
                type="text"
                placeholder="Enter paste ID..."
                value={viewPasteId}
                onChange={(e) => setViewPasteId(e.target.value)}
                className="flex-1 px-3 py-2 bg-zinc-900 border border-zinc-700 rounded text-sm font-mono focus:outline-none focus:border-green-500"
              />
              <button
                onClick={loadPaste}
                disabled={loading || !viewPasteId}
                className="px-4 py-2 bg-green-600 hover:bg-green-500 disabled:opacity-50 rounded text-sm font-medium"
              >
                {loading ? "Loading..." : "Load"}
              </button>
            </div>
            {viewImageUrl && (
              <div className="p-4 bg-zinc-900 border border-zinc-700 rounded">
                <img src={viewImageUrl} alt="Paste content" className="max-w-full rounded" />
              </div>
            )}
            {viewContent && (
              <pre className="p-4 bg-zinc-900 border border-zinc-700 rounded text-sm text-zinc-200 font-mono whitespace-pre-wrap break-all overflow-auto max-h-[60vh]">
                {viewContent}
              </pre>
            )}
          </div>
        )}
      </main>

      <footer className="border-t border-zinc-800 px-6 py-4 text-center text-xs text-zinc-600">
        ClankerPaste — Uncensorable pastebin on the Internet Computer.
        No accounts. No censorship. Pay in Sepolia ETH, USDC, or testnet BTC.
      </footer>
    </div>
  );
}

export default App;
