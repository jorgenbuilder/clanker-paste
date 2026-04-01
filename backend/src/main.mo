import Map "mo:core/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import Nat64 "mo:core/Nat64";
import Int "mo:core/Int";
import Iter "mo:core/Iter";
import Principal "mo:core/Principal";
import Runtime "mo:core/Runtime";
import Time "mo:core/Time";
import Char "mo:core/Char";
import Array "mo:core/Array";
import Error "mo:core/Error";

persistent actor ClankerPaste {

  // --- EVM RPC Canister Interface (Sepolia) ---

  type EthSepoliaService = {
    #Alchemy;
    #Ankr;
    #BlockPi;
    #PublicNode;
    #Sepolia;
  };

  type RpcService = {
    #EthSepolia : EthSepoliaService;
  };

  type RpcError = {
    #ProviderError : { code : Int; message : Text };
    #HttpOutcallError : { code : Int; message : Text };
    #JsonRpcError : { code : Int; message : Text };
    #ValidationError : Text;
  };

  let evmRpc : actor {
    request : (RpcService, Text, Nat64) -> async {
      #Ok : Text;
      #Err : RpcError;
    };
  } = actor ("7hfb6-caaaa-aaaar-qadga-cai");

  // --- Types ---

  type Paste = {
    id : Text;
    chunks : [Blob];
    contentType : Text;
    title : Text;
    createdAt : Int;
    expiresAt : Int;
    sizeBytes : Nat;
    expectedSize : Nat;
    uploadComplete : Bool;
    paymentStatus : PaymentStatus;
    owner : ?Principal;
  };

  type PaymentStatus = {
    #pending : {
      expectedAmountWei : Text;
      expectedAmountSats : Text;
      chain : Text;
    };
    #confirmed;
    #free;
  };

  type InitPasteRequest = {
    contentType : Text;
    title : Text;
    totalSize : Nat;
    durationDays : Nat;
    paymentChain : Text;
    firstChunk : Blob;
  };

  type InitPasteResponse = {
    pasteId : Text;
    paymentAddress : Text;
    expectedAmount : Text;
    chain : Text;
    expiresAt : Int;
    chunksExpected : Nat;
  };

  type PasteView = {
    id : Text;
    title : Text;
    contentType : Text;
    sizeBytes : Nat;
    createdAt : Int;
    expiresAt : Int;
    paymentStatus : Text;
    uploadComplete : Bool;
  };

  // --- Config ---

  let ETH_ADDRESS : Text = "0x2DA4E8752DB47048476aF400011BA9b307e23e39";
  let BTC_ADDRESS : Text = "bc1q352e9zezujr6cmkupk9c33tkrfs95f6yvxnmmh";

  let PRICE_PER_BYTE_PER_DAY_WEI : Nat = 1_000;
  let PRICE_PER_BYTE_PER_DAY_USDC : Nat = 1;
  let PRICE_PER_BYTE_PER_DAY_SATS : Nat = 1;

  let FREE_TIER_MAX_BYTES : Nat = 1024;
  let MAX_PASTE_BYTES : Nat = 104_857_600; // 100MB
  let MAX_CHUNK_BYTES : Nat = 1_900_000; // ~1.9MB per chunk
  let MAX_TOTAL_STORAGE : Nat = 1_073_741_824; // 1GB total

  let NANOS_PER_DAY : Int = 86_400_000_000_000;

  // --- State ---

  let pastes = Map.empty<Text, Paste>();
  var pasteCounter : Nat = 0;
  transient var totalStorageUsed : Nat = 0;

  do {
    for ((_, paste) in Map.entries(pastes)) {
      totalStorageUsed += paste.sizeBytes;
    };
  };

  // --- Helpers ---

  func generateId() : Text {
    pasteCounter += 1;
    let timestamp = Int.abs(Time.now());
    Nat.toText(pasteCounter) # "-" # Nat.toText(timestamp % 1_000_000_000);
  };

  func calculatePrice(sizeBytes : Nat, durationDays : Nat, chain : Text) : Nat {
    let pricePerByte = switch (chain) {
      case ("eth") { PRICE_PER_BYTE_PER_DAY_WEI };
      case ("usdc") { PRICE_PER_BYTE_PER_DAY_USDC };
      case ("btc") { PRICE_PER_BYTE_PER_DAY_SATS };
      case (_) { Runtime.trap("unsupported chain") };
    };
    sizeBytes * durationDays * pricePerByte;
  };

  func addJitter(baseAmount : Nat, pasteId : Text) : Nat {
    var hash : Nat = 0;
    for (c in pasteId.chars()) {
      hash := hash * 31 + Nat64.toNat(Nat64.fromNat32(Char.toNat32(c)));
    };
    baseAmount + (hash % 1000);
  };

  func isExpired(paste : Paste) : Bool {
    Time.now() > paste.expiresAt;
  };

  func blobSize(b : Blob) : Nat {
    Blob.toArray(b).size();
  };

  func concatBlobs(blobs : [Blob]) : Blob {
    if (blobs.size() == 1) return blobs[0];
    // Collect all bytes into a single array
    var allBytes : [Nat8] = [];
    for (b in blobs.vals()) {
      allBytes := Array.concat(allBytes, Blob.toArray(b));
    };
    Blob.fromArray(allBytes);
  };

  // --- EVM RPC Verification ---

  // Store last verification error for debugging
  transient var lastVerifyError : Text = "";
  transient var lastTxHashReceived : Text = "";

  func verifyEthPayment(txHash : Text) : async Bool {
    lastTxHashReceived := txHash;
    try {
      let jsonBody = "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getTransactionReceipt\",\"params\":[\"" # txHash # "\"],\"id\":1}";
      let result = await (with cycles = 25_000_000_000) evmRpc.request(
        #EthSepolia(#PublicNode),
        jsonBody,
        4096
      );
      switch (result) {
        case (#Ok(response)) {
          lastVerifyError := "OK: " # response;
          let hasStatus = Text.contains(response, #text "0x1");
          let hasRecipient = Text.contains(response, #text (toLower(ETH_ADDRESS)));
          hasStatus and hasRecipient;
        };
        case (#Err(err)) {
          lastVerifyError := switch (err) {
            case (#ProviderError(e)) { "ProviderError: " # e.message };
            case (#HttpOutcallError(e)) { "HttpOutcallError: " # e.message };
            case (#JsonRpcError(e)) { "JsonRpcError: " # e.message };
            case (#ValidationError(e)) { "ValidationError: " # e };
          };
          false;
        };
      };
    } catch (e) {
      lastVerifyError := "Caught: " # Error.message(e);
      false;
    };
  };

  public query func getLastVerifyError() : async Text {
    lastVerifyError;
  };

  public query func getLastTxHash() : async Text {
    lastTxHashReceived;
  };

  func toLower(t : Text) : Text {
    var result = "";
    for (c in t.chars()) {
      let code = Char.toNat32(c);
      if (code >= 65 and code <= 90) {
        result #= Char.toText(Char.fromNat32(code + 32));
      } else {
        result #= Char.toText(c);
      };
    };
    result;
  };

  // --- Public API ---

  // Initialize a paste with the first chunk. Returns payment info.
  // For small pastes (single chunk), this is the only call needed.
  public shared ({ caller }) func initPaste(req : InitPasteRequest) : async InitPasteResponse {
    let chunkSize = blobSize(req.firstChunk);

    if (req.totalSize == 0) { Runtime.trap("empty content") };
    if (req.totalSize > MAX_PASTE_BYTES) { Runtime.trap("paste too large, max 100MB") };
    if (chunkSize > MAX_CHUNK_BYTES) { Runtime.trap("chunk too large, max ~1.9MB") };
    if (chunkSize > req.totalSize) { Runtime.trap("chunk larger than total size") };
    if (totalStorageUsed + req.totalSize > MAX_TOTAL_STORAGE) { Runtime.trap("storage full") };
    if (req.durationDays == 0 or req.durationDays > 365) { Runtime.trap("duration must be 1-365 days") };

    let id = generateId();
    let isFree = req.totalSize <= FREE_TIER_MAX_BYTES;
    let price = if (isFree) { 0 } else { addJitter(calculatePrice(req.totalSize, req.durationDays, req.paymentChain), id) };
    let expiresAt = Time.now() + req.durationDays * NANOS_PER_DAY;
    let isComplete = chunkSize >= req.totalSize;

    let paymentStatus : PaymentStatus = if (isFree) {
      #free;
    } else {
      #pending({
        expectedAmountWei = if (req.paymentChain == "eth" or req.paymentChain == "usdc") { Nat.toText(price) } else { "0" };
        expectedAmountSats = if (req.paymentChain == "btc") { Nat.toText(price) } else { "0" };
        chain = req.paymentChain;
      });
    };

    let owner = if (Principal.isAnonymous(caller)) { null } else { ?caller };

    let paste : Paste = {
      id;
      chunks = [req.firstChunk];
      contentType = req.contentType;
      title = req.title;
      createdAt = Time.now();
      expiresAt;
      sizeBytes = chunkSize;
      expectedSize = req.totalSize;
      uploadComplete = isComplete;
      paymentStatus;
      owner;
    };

    Map.add(pastes, Text.compare, id, paste);
    totalStorageUsed += chunkSize;

    let paymentAddress = switch (req.paymentChain) {
      case ("eth" or "usdc") { ETH_ADDRESS };
      case ("btc") { BTC_ADDRESS };
      case (_) { "" };
    };

    let chunksNeeded = if (isComplete) { 0 } else {
      let remaining = req.totalSize - chunkSize;
      (remaining + MAX_CHUNK_BYTES - 1) / MAX_CHUNK_BYTES;
    };

    {
      pasteId = id;
      paymentAddress;
      expectedAmount = Nat.toText(price);
      chain = req.paymentChain;
      expiresAt;
      chunksExpected = chunksNeeded;
    };
  };

  // Upload additional chunks. Must be called in order.
  public shared ({ caller }) func uploadChunk(pasteId : Text, chunk : Blob) : async { chunksReceived : Nat; complete : Bool } {
    let chunkSize = blobSize(chunk);
    if (chunkSize > MAX_CHUNK_BYTES) { Runtime.trap("chunk too large") };

    switch (Map.get(pastes, Text.compare, pasteId)) {
      case (null) { Runtime.trap("paste not found") };
      case (?paste) {
        // Only owner can upload chunks
        switch (paste.owner) {
          case (?owner) { if (caller != owner) { Runtime.trap("not the owner") } };
          case (null) { if (not Principal.isAnonymous(caller)) { Runtime.trap("not the owner") } };
        };
        if (paste.uploadComplete) { Runtime.trap("upload already complete") };
        if (paste.sizeBytes + chunkSize > paste.expectedSize) { Runtime.trap("exceeds expected size") };

        let newChunks = Array.concat(paste.chunks, [chunk]);
        let newSize = paste.sizeBytes + chunkSize;
        let isComplete = newSize >= paste.expectedSize;

        let updated = {
          paste with
          chunks = newChunks;
          sizeBytes = newSize;
          uploadComplete = isComplete;
        };
        Map.add(pastes, Text.compare, pasteId, updated);
        totalStorageUsed += chunkSize;

        { chunksReceived = newChunks.size(); complete = isComplete };
      };
    };
  };

  // Legacy single-call create (for backward compat / small pastes)
  public shared ({ caller }) func createPaste(req : {
    content : Blob;
    contentType : Text;
    title : Text;
    durationDays : Nat;
    paymentChain : Text;
  }) : async {
    pasteId : Text;
    paymentAddress : Text;
    expectedAmount : Text;
    chain : Text;
    expiresAt : Int;
  } {
    let size = blobSize(req.content);
    let result = await initPaste({
      contentType = req.contentType;
      title = req.title;
      totalSize = size;
      durationDays = req.durationDays;
      paymentChain = req.paymentChain;
      firstChunk = req.content;
    });
    {
      pasteId = result.pasteId;
      paymentAddress = result.paymentAddress;
      expectedAmount = result.expectedAmount;
      chain = result.chain;
      expiresAt = result.expiresAt;
    };
  };

  // Verify payment via EVM RPC canister
  public shared func confirmPayment(pasteId : Text, txHash : Text) : async Bool {
    switch (Map.get(pastes, Text.compare, pasteId)) {
      case (null) { Runtime.trap("paste not found") };
      case (?paste) {
        switch (paste.paymentStatus) {
          case (#confirmed) { return true };
          case (#free) { return true };
          case (#pending(info)) {
            let verified = if (info.chain == "eth" or info.chain == "usdc") {
              await verifyEthPayment(txHash);
            } else { true };

            if (verified) {
              let updated = { paste with paymentStatus = #confirmed };
              Map.add(pastes, Text.compare, pasteId, updated);
              true;
            } else { false };
          };
        };
      };
    };
  };

  // Get paste metadata
  public query func getPasteInfo(pasteId : Text) : async ?PasteView {
    switch (Map.get(pastes, Text.compare, pasteId)) {
      case (null) { null };
      case (?paste) {
        if (isExpired(paste)) { return null };
        let status = switch (paste.paymentStatus) {
          case (#pending(_)) { "pending" };
          case (#confirmed) { "confirmed" };
          case (#free) { "free" };
        };
        ?{
          id = paste.id;
          title = paste.title;
          contentType = paste.contentType;
          sizeBytes = paste.sizeBytes;
          createdAt = paste.createdAt;
          expiresAt = paste.expiresAt;
          paymentStatus = status;
          uploadComplete = paste.uploadComplete;
        };
      };
    };
  };

  // Get paste content — returns the full blob (reassembled from chunks)
  // For large pastes, use getChunk instead
  public query func getPasteContent(pasteId : Text) : async ?Blob {
    switch (Map.get(pastes, Text.compare, pasteId)) {
      case (null) { null };
      case (?paste) {
        if (isExpired(paste)) { return null };
        if (not paste.uploadComplete) { return null };
        switch (paste.paymentStatus) {
          case (#pending(_)) { null };
          case (#confirmed or #free) { ?concatBlobs(paste.chunks) };
        };
      };
    };
  };

  // Get a specific chunk by index (for large pastes)
  public query func getChunk(pasteId : Text, index : Nat) : async ?Blob {
    switch (Map.get(pastes, Text.compare, pasteId)) {
      case (null) { null };
      case (?paste) {
        if (isExpired(paste)) { return null };
        if (not paste.uploadComplete) { return null };
        switch (paste.paymentStatus) {
          case (#pending(_)) { null };
          case (#confirmed or #free) {
            if (index >= paste.chunks.size()) { null }
            else { ?paste.chunks[index] };
          };
        };
      };
    };
  };

  // Get number of chunks for a paste
  public query func getChunkCount(pasteId : Text) : async ?Nat {
    switch (Map.get(pastes, Text.compare, pasteId)) {
      case (null) { null };
      case (?paste) { ?paste.chunks.size() };
    };
  };

  // List pastes for a logged-in user
  public shared query ({ caller }) func myPastes() : async [PasteView] {
    if (Principal.isAnonymous(caller)) { Runtime.trap("must be authenticated") };
    var results : [PasteView] = [];
    for ((_, p) in Map.entries(pastes)) {
      if (p.owner == ?caller and not isExpired(p)) {
        let status = switch (p.paymentStatus) {
          case (#pending(_)) { "pending" };
          case (#confirmed) { "confirmed" };
          case (#free) { "free" };
        };
        results := Array.concat(results, [{
          id = p.id;
          title = p.title;
          contentType = p.contentType;
          sizeBytes = p.sizeBytes;
          createdAt = p.createdAt;
          expiresAt = p.expiresAt;
          paymentStatus = status;
          uploadComplete = p.uploadComplete;
        }]);
      };
    };
    results;
  };

  // Delete paste (owner only)
  public shared ({ caller }) func deletePaste(pasteId : Text) : async Bool {
    switch (Map.get(pastes, Text.compare, pasteId)) {
      case (null) { false };
      case (?paste) {
        switch (paste.owner) {
          case (null) { Runtime.trap("paste has no owner") };
          case (?owner) {
            if (caller != owner) { Runtime.trap("not the owner") };
            totalStorageUsed -= paste.sizeBytes;
            ignore Map.delete(pastes, Text.compare, pasteId);
            true;
          };
        };
      };
    };
  };

  // --- HTTP Interface ---

  type HttpRequest = {
    method : Text;
    url : Text;
    headers : [(Text, Text)];
    body : Blob;
  };

  type HttpResponse = {
    status_code : Nat16;
    headers : [(Text, Text)];
    body : Blob;
  };

  func textToBlob(t : Text) : Blob { Text.encodeUtf8(t) };

  func parseUrl(url : Text) : Text {
    let chars = Iter.toArray(url.chars());
    if (chars.size() < 3) return "";
    if (chars.size() >= 3 and chars[0] == '/' and chars[1] == 'p' and chars[2] == '/') {
      var id = "";
      var i = 3;
      while (i < chars.size() and chars[i] != '?') {
        id #= Char.toText(chars[i]);
        i += 1;
      };
      return id;
    };
    "";
  };

  public query func http_request(req : HttpRequest) : async HttpResponse {
    if (req.method != "GET") {
      return {
        status_code = 405;
        headers = [("Content-Type", "text/plain")];
        body = textToBlob("Method not allowed");
      };
    };

    let pasteId = parseUrl(req.url);

    if (pasteId == "") {
      return {
        status_code = 200;
        headers = [("Content-Type", "text/html")];
        body = textToBlob(
          "<!DOCTYPE html><html><head><title>ClankerPaste</title>" #
          "<meta http-equiv='refresh' content='0;url=https://7agvh-biaaa-aaaas-qgfqa-cai.icp0.io/' />" #
          "</head><body style='font-family:monospace;max-width:600px;margin:50px auto;'>" #
          "<h1>ClankerPaste</h1>" #
          "<p>Redirecting to <a href='https://7agvh-biaaa-aaaas-qgfqa-cai.icp0.io/'>frontend</a>...</p>" #
          "</body></html>"
        );
      };
    };

    switch (Map.get(pastes, Text.compare, pasteId)) {
      case (null) {
        {
          status_code = 404;
          headers = [("Content-Type", "text/plain")];
          body = textToBlob("Paste not found");
        };
      };
      case (?paste) {
        if (isExpired(paste)) {
          return {
            status_code = 410;
            headers = [("Content-Type", "text/plain")];
            body = textToBlob("Paste expired");
          };
        };
        if (not paste.uploadComplete) {
          return {
            status_code = 202;
            headers = [("Content-Type", "text/plain")];
            body = textToBlob("Upload in progress");
          };
        };
        switch (paste.paymentStatus) {
          case (#pending(_)) {
            {
              status_code = 402;
              headers = [("Content-Type", "text/html")];
              body = textToBlob(
                "<!DOCTYPE html><html><head><title>402 Payment Required</title></head>" #
                "<body style='font-family:monospace;max-width:600px;margin:80px auto;text-align:center;'>" #
                "<h1 style='font-size:72px;margin:0;'>402</h1>" #
                "<p style='font-size:20px;color:#666;'>Payment Required</p>" #
                "<p style='color:#999;'>This paste exists but hasn't been paid for yet.</p>" #
                "<p style='margin-top:40px;'><a href='https://7agvh-biaaa-aaaas-qgfqa-cai.icp0.io/' style='color:#4ade80;'>Go to ClankerPaste</a></p>" #
                "</body></html>"
              );
            };
          };
          case (#confirmed or #free) {
            {
              status_code = 200;
              headers = [
                ("Content-Type", paste.contentType),
                ("X-Paste-Title", paste.title),
                ("X-Paste-Expires", Int.toText(paste.expiresAt)),
                ("Cache-Control", "public, max-age=3600"),
              ];
              body = concatBlobs(paste.chunks);
            };
          };
        };
      };
    };
  };

  // --- Stats ---

  public query func stats() : async {
    totalPastes : Nat;
    totalStorageBytes : Nat;
    maxStorageBytes : Nat;
  } {
    {
      totalPastes = Map.size(pastes);
      totalStorageBytes = totalStorageUsed;
      maxStorageBytes = MAX_TOTAL_STORAGE;
    };
  };

  // --- Garbage Collection ---

  public func gc() : async Nat {
    var cleaned : Nat = 0;
    let now = Time.now();
    var expiredIds : [(Text, Nat)] = [];
    for ((id, p) in Map.entries(pastes)) {
      if (now > p.expiresAt) {
        expiredIds := Array.concat(expiredIds, [(id, p.sizeBytes)]);
      };
    };
    for ((id, size) in expiredIds.vals()) {
      Map.remove(pastes, Text.compare, id);
      totalStorageUsed -= size;
      cleaned += 1;
    };
    cleaned;
  };
};
