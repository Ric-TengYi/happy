# HarmonyOS MVP Interfaces

This document describes the minimum HarmonyOS ArkTS/ArkUI client surface for
Happy. The recommended path is a native HarmonyOS client that reuses the
existing Happy Server, account model, encryption model, Socket.IO sync, and
CLI daemon RPC protocol.

The Android app is Expo + React Native, not an H5 shell. A HarmonyOS H5 shell
can prove connectivity quickly, but it is not the target for a production
client because the MVP still needs camera QR scan, local secure storage,
client-side cryptography, WebSocket sync, tool approval, and later push/audio
capabilities.

## Goal

For this fork, the MVP should be able to connect to the deployed server at
`https://47.118.25.177`, authenticate an account, approve a terminal QR login,
list machines and sessions, show chat messages, send user messages, approve or
deny tool permission requests, and keep state current through Socket.IO.

## Explicit Exclusions

These subsystems should be no-op or hidden in the HarmonyOS MVP:

- Push notifications and push token registration.
- Profile, settings sync, purchases, and native update checks.
- GitHub integration.
- Friends, feed, relationship updates, and public profiles.
- Artifacts, uploaded files, KV store, and access-key UI.
- Voice/realtime audio. Keep `voiceHooks` behavior as no-op equivalents.
- Worktree management. If it is added later, it needs machine-side bash/RPC
  commands, not only `spawn-happy-session`.

The socket client can safely ignore account/artifact/friend/feed/KV update
types for MVP, while still preserving the update sequence used by the server.

## Service Boundaries

The HarmonyOS client should use small services instead of one large sync class.
This mirrors the existing app behavior while keeping ArkTS modules testable.

```txt
ArkUI screens
|- ServerConfigService       server URL + server validation
|- CredentialStore           secure local token/secret persistence
|- LocalStateStore           non-secret drafts and UI selections
|- CryptoService             account secret, content key, per-session/machine keys
|- AuthService               create/restore account + QR approvals
|- SyncSocketClient          Socket.IO connect, reconnect, update dispatch
|- SessionRepository         /v1/sessions + decrypted session state
|- MessageRepository         /v3/sessions/:id/messages + seq catch-up
|- OutboxService             optimistic send + localId dedup
|- MachineRepository         /v1/machines + machine presence
|- MachineRpcClient          encrypted machine RPC spawn/resume
`- PermissionService         encrypted session RPC permission decisions
```

## Protocol Conventions

- Server URL is configurable and should persist across logout. This fork can
  default to `https://47.118.25.177`.
- HTTP auth uses `Authorization: Bearer <token>`.
- HTTP requests should include `X-Happy-Client`, for example
  `harmony/0.1.0`. This is used for logging/metrics, not authentication.
- Socket.IO connects to `path: "/v1/updates"` with auth:

```ts
{
  token: string;
  clientType: "user-scoped";
  happyClient: string;
}
```

- The existing app forces websocket transport. The server allows websocket and
  polling, but MVP should start with websocket-only to match app behavior.
- QR URL keys are base64url. HTTP body fields such as `publicKey`,
  `challenge`, `signature`, and encrypted `response` are standard base64.
- Server-side `connectionStateRecovery` is currently disabled. On reconnect,
  refetch sessions and machines; messages are caught up lazily per visible
  session using `after_seq`.

## Encryption Boundaries

The server stores and broadcasts most user content as ciphertext. The HarmonyOS
client must decrypt locally.

Server-visible plaintext:

- Account id, session id, machine id, message id, `seq`, `localId`.
- Timestamps, active flags, `activeAt`, client type, and connection metadata.

Client-encrypted payloads:

- Message content.
- Session metadata and agent state.
- Machine metadata and daemon state.
- Session RPC params/results.
- Machine RPC params/results.
- Session and machine data encryption keys.

```txt
Account secret: Uint8Array(32)
|- Ed25519 signing seed for /v1/auth challenge
|- legacy SecretBox key for older records
`- deriveKey(secret, "Happy EnCoder", ["content"])
   `- crypto_box_seed_keypair(contentDataKey)
      |- publicKey sent to CLI terminal auth V2
      `- privateKey opens per-session/per-machine dataEncryptionKey
```

NaCl box auth bundles use:

```txt
ephemeral public key(32) || nonce(24) || ciphertext
```

Encrypted strings in REST and Socket.IO payloads are base64-encoded binary
bundles. The MVP must implement these byte layouts exactly:

```txt
deriveKey(master, usage, path)
|- root = HMAC-SHA512(key = UTF8(usage + " Master Seed"), data = master)
|  |- key = root[0..31]
|  `- chainCode = root[32..63]
`- for each path item
   |- data = 0x00 || UTF8(item)
   |- I = HMAC-SHA512(key = chainCode, data = data)
   |- key = I[0..31]
   `- chainCode = I[32..63]
```

```txt
dataEncryptionKey field
`- base64(version(0) || boxBundle)
   `- boxBundle = ephemeral public key(32) || nonce(24) || ciphertext
      `- plaintext = 32-byte session or machine AES data key
```

```txt
legacy encrypted record
`- base64(nonce(24) || secretbox(JSON.stringify(value)))
   `- key = account secret bytes
```

```txt
data-key encrypted record
`- base64(version(0) || nonce(12) || ciphertext || authTag(16))
   |- algorithm = AES-256-GCM
   |- key = decrypted 32-byte session or machine data key
   `- plaintext = UTF8(JSON.stringify(value))
```

Session metadata, session agent state, machine metadata, machine daemon state,
messages, and RPC params/results all use the same record dispatcher: if the
server row has `dataEncryptionKey`, use the decrypted data-key AES layout;
otherwise use the legacy account-secret secretbox layout.

## Core Types

Use ArkTS classes or interfaces equivalent to these shapes. Exact syntax can
change to match the HarmonyOS compiler, but the fields should not be collapsed.

```ts
type ConnectionStatus = "disconnected" | "connecting" | "connected" | "error";

interface Credentials {
  token: string;
  secretBase64Url: string;
}

interface ApiUpdateContainer {
  id: string;
  seq: number;
  createdAt: number;
  body: ApiUpdateBody;
}

type ApiUpdateBody =
  | NewMessageUpdate
  | NewSessionUpdate
  | UpdateSessionUpdate
  | DeleteSessionUpdate
  | NewMachineUpdate
  | UpdateMachineUpdate
  | DeleteMachineUpdate
  | UnknownIgnoredUpdate;

interface NewSessionUpdate {
  t: "new-session";
  id: string;
  seq: number;
  metadata: string;
  metadataVersion: number;
  agentState: string | null;
  agentStateVersion: number;
  dataEncryptionKey: string | null;
  active: boolean;
  activeAt: number;
  createdAt: number;
  updatedAt: number;
}

interface UpdateSessionUpdate {
  t: "update-session";
  id: string;
  metadata?: { value: string; version: number };
  agentState?: { value: string | null; version: number };
}

interface DeleteSessionUpdate {
  t: "delete-session";
  sid: string;
}

interface NewMessageUpdate {
  t: "new-message";
  sid: string;
  message: ApiMessage;
}

interface NewMachineUpdate {
  t: "new-machine";
  machineId: string;
  seq: number;
  metadata: string;
  metadataVersion: number;
  daemonState: string | null;
  daemonStateVersion: number;
  dataEncryptionKey: string | null;
  active: boolean;
  activeAt: number;
  createdAt: number;
  updatedAt: number;
}

interface UpdateMachineUpdate {
  t: "update-machine";
  machineId: string;
  metadata?: { value: string; version: number };
  daemonState?: { value: string; version: number };
}

interface DeleteMachineUpdate {
  t: "delete-machine";
  machineId: string;
}

interface UnknownIgnoredUpdate {
  t: string;
  [key: string]: unknown;
}

interface ApiMessage {
  id: string;
  seq: number;
  content: { t: "encrypted"; c: string };
  localId?: string | null;
  createdAt: number;
  updatedAt: number;
}

interface Session {
  id: string;
  seq: number;
  active: boolean;
  activeAt: number;
  presence: "online" | number;
  thinking: boolean;
  thinkingAt: number;
  createdAt: number;
  updatedAt: number;
  metadata: SessionMetadata | null;
  metadataVersion: number;
  agentState: AgentState | null;
  agentStateVersion: number;
  draft?: string | null;
  permissionMode?: string | null;
  modelMode?: string | null;
  effortLevel?: string | null;
}

interface SessionMetadata {
  path: string;
  host: string;
  summary?: { text: string; updatedAt: number };
  machineId?: string;
  homeDir?: string;
  flavor?: string | null;
  sandbox?: unknown;
  dangerouslySkipPermissions?: boolean | null;
}

interface AgentState {
  controlledByUser?: boolean | null;
  requests?: Record<string, {
    tool: string;
    arguments: unknown;
    createdAt?: number | null;
  }> | null;
  completedRequests?: Record<string, {
    tool: string;
    arguments: unknown;
    createdAt?: number | null;
    completedAt?: number | null;
    status: "canceled" | "denied" | "approved";
    reason?: string | null;
    mode?: string | null;
    allowedTools?: string[] | null;
    allowTools?: string[] | null;
    decision?: "approved" | "approved_for_session" | "denied" | "abort" | null;
  }> | null;
}

interface MessageMeta {
  sentFrom?: string;
  permissionMode?: "default" | "acceptEdits" | "bypassPermissions" | "plan" |
    "read-only" | "safe-yolo" | "yolo";
  model?: string | null;
  fallbackModel?: string | null;
  customSystemPrompt?: string | null;
  appendSystemPrompt?: string | null;
  allowedTools?: string[] | null;
  disallowedTools?: string[] | null;
  displayText?: string;
}

interface Machine {
  id: string;
  seq: number;
  active: boolean;
  activeAt: number;
  createdAt: number;
  updatedAt: number;
  metadata: MachineMetadata | null;
  metadataVersion: number;
  daemonState: unknown | null;
  daemonStateVersion: number;
}

interface MachineMetadata {
  host: string;
  platform: string;
  happyCliVersion: string;
  happyHomeDir: string;
  homeDir: string;
  username?: string;
  arch?: string;
  displayName?: string;
  cliAvailability?: {
    claude: boolean;
    codex: boolean;
    gemini: boolean;
    openclaw: boolean;
    detectedAt: number;
  };
  resumeSupport?: {
    rpcAvailable: boolean;
    requiresSameMachine: boolean;
    requiresHappyAgentAuth: boolean;
    happyAgentAuthenticated: boolean;
    detectedAt: number;
  };
}

interface SessionPermissionRequest {
  id: string;
  approved: boolean;
  reason?: string;
  mode?: "default" | "acceptEdits" | "bypassPermissions" | "plan";
  allowTools?: string[];
  updatedInput?: Record<string, unknown>;
  decision?: "approved" | "approved_for_session" | "denied" | "abort";
}
```

## HTTP Response Wrappers

The main MVP HTTP endpoints do not all use the same response envelope:

```ts
// GET /v1/sessions
{ sessions: Array<{
  id: string;
  seq: number;
  metadata: string;
  metadataVersion: number;
  agentState: string | null;
  agentStateVersion: number;
  dataEncryptionKey: string | null;
  active: boolean;
  activeAt: number;
  createdAt: number;
  updatedAt: number;
  lastMessage: ApiMessage | null;
}> }

// GET /v1/machines
Array<{
  id: string;
  metadata: string;
  metadataVersion: number;
  daemonState?: string | null;
  daemonStateVersion?: number;
  dataEncryptionKey?: string | null;
  seq: number;
  active: boolean;
  activeAt: number;
  createdAt: number;
  updatedAt: number;
}>

// GET /v3/sessions/:sessionId/messages
{ messages: ApiMessage[]; hasMore: boolean }

// POST /v3/sessions/:sessionId/messages
// content is intentionally omitted from the response.
{ messages: Array<{
  id: string;
  seq: number;
  localId: string | null;
  createdAt: number;
  updatedAt: number;
}> }
```

## ServerConfigService

Responsibilities:

- Persist custom server URL outside account credentials so logout does not
  reset it.
- Validate syntax: only `http:` and `https:` are allowed.
- Validate server identity with `GET <serverUrl>` and require the response body
  to contain `Welcome to Happy Server!`.
- Expose reset-to-default and current server info.

```ts
interface ServerConfigService {
  getServerUrl(): string;
  setServerUrl(url: string | null): void;
  validateUrl(url: string): { valid: boolean; error?: string };
  validateServer(url: string): Promise<boolean>;
  isUsingCustomServer(): boolean;
}
```

Reference: `packages/happy-app/sources/sync/serverConfig.ts`,
`packages/happy-app/sources/app/(app)/server.tsx`,
`packages/happy-server/sources/app/api/api.ts`.

## CredentialStore

Responsibilities:

- Store `{ token, secret }` in HarmonyOS secure storage.
- Return credentials before HTTP and socket calls.
- Clear credentials on logout without clearing server URL.

```ts
interface CredentialStore {
  getCredentials(): Promise<Credentials | null>;
  setCredentials(credentials: Credentials): Promise<boolean>;
  removeCredentials(): Promise<boolean>;
}
```

The existing mobile app stores both fields together via SecureStore. The
HarmonyOS implementation should use the platform security storage equivalent.
Server tokens are privacy-kit persistent tokens. The 24 hour value in the
server auth module is only a verifier cache TTL, not a token expiration time.
Logout should remove local credentials; it should not assume the server token
has been revoked.

Reference: `packages/happy-app/sources/auth/tokenStorage.ts`.

## LocalStateStore

Responsibilities:

- Persist non-secret local UI state outside the secure credential store.
- Keep per-session drafts, permission mode, model mode, and effort level.
- Remove per-session local state when a session is deleted.
- Clear account-scoped local state on logout, while keeping server URL.

```ts
interface LocalStateStore {
  getDraft(sessionId: string): string | null;
  setDraft(sessionId: string, draft: string | null): void;
  getSessionMode(sessionId: string): {
    permissionMode?: string | null;
    modelMode?: string | null;
    effortLevel?: string | null;
  };
  setSessionMode(sessionId: string, mode: {
    permissionMode?: string | null;
    modelMode?: string | null;
    effortLevel?: string | null;
  }): void;
  removeSession(sessionId: string): void;
  clearAccountState(): void;
}
```

Reference: `packages/happy-app/sources/sync/persistence.ts`,
`packages/happy-app/sources/sync/storage.ts`.

## CryptoService

Responsibilities:

- Generate and parse 32-byte account secrets.
- Produce `/v1/auth` challenge signatures.
- Derive the content data key from the account secret.
- Decrypt session and machine `dataEncryptionKey` values.
- Maintain per-session and per-machine encryptors.
- Encrypt/decrypt raw RPC payloads and messages.

```ts
interface CryptoService {
  createFromAccountSecret(secret: Uint8Array): Promise<void>;
  getContentDataPublicKey(): Uint8Array;
  createAuthChallenge(secret: Uint8Array): {
    publicKey: Uint8Array;
    challenge: Uint8Array;
    signature: Uint8Array;
  };
  decryptEncryptionKey(encryptedBase64: string): Promise<Uint8Array | null>;
  initializeSessions(keys: Map<string, Uint8Array | null>): Promise<void>;
  initializeMachines(keys: Map<string, Uint8Array | null>): Promise<void>;
  getSessionCrypto(sessionId: string): SessionCrypto | null;
  getMachineCrypto(machineId: string): MachineCrypto | null;
}
```

`/v1/auth` is not a server challenge-response flow. The challenge is generated
by the client, and the server does not persist nonce state. A previously valid
`{ publicKey, challenge, signature }` can request a token again for the same
account. Treat it as proof of account-secret possession.

Reference: `packages/happy-app/sources/auth/authChallenge.ts`,
`packages/happy-app/sources/sync/encryption/encryption.ts`,
`packages/happy-app/sources/sync/encryption/sessionEncryption.ts`,
`packages/happy-app/sources/sync/encryption/machineEncryption.ts`.

## AuthService

### Create Or Restore Account

Create account and manual restore both end at `POST /v1/auth`.

```txt
Create/manual restore
`- secret: Uint8Array(32)
   |- Ed25519 keypair from seed secret
   |- challenge: random Uint8Array(32)
   |- signature: sign(challenge, privateKey)
   `- POST /v1/auth
      body { publicKey, challenge, signature } // base64
      headers { X-Happy-Client }
      -> { success: true, token: string }
```

Manual restore must accept both base64url secret and the formatted backup
secret used by the current app, but the decoded result must be exactly 32
bytes. The formatted backup string is RFC 4648 base32 without padding, grouped
with dashes in 5-character chunks. Parsing is intentionally forgiving:
uppercase input, map common mistakes `0 -> O`, `1 -> I`, `8 -> B`, `9 -> G`,
drop non-base32 characters, decode, and then reject unless the result is
exactly 32 bytes.

### Terminal QR Approval

Terminal auth connects a CLI daemon to an existing account. The CLI creates a
fresh temporary NaCl box keypair and registers it with the server.

```txt
CLI terminal auth
|- CLI random box keypair
|- CLI POST /v1/auth/request
|  body { publicKey: base64, supportsV2: true }
|- CLI displays happy://terminal?<base64url publicKey>
|- App scans URL and GET /v1/auth/request/status?publicKey=<base64>
|- App POST /v1/auth/response Bearer token
|  body { publicKey: base64, response: base64(encrypted bundle) }
`- CLI polls POST /v1/auth/request until
   { state: "authorized", token, response }
```

Compatibility details:

- V1 encrypted plaintext is the 32-byte account secret.
- V2 encrypted plaintext is `0x00 || content public key(32 bytes)`.
- The current CLI sends `supportsV2: true`, decrypts V2, stores the content
  public key, and creates a local random `machineKey`.
- `GET /v1/auth/request/status` returns
  `{ status: "not_found" | "pending" | "authorized", supportsV2: boolean }`.
- The CLI does not use the status endpoint; it polls `POST /v1/auth/request`.
- Terminal auth rows are unique by public key and are not expired, deleted, or
  consumed after authorization. Temporary QR keys must be fresh and high
  entropy and must not be reused.

### Account QR Restore

Account QR restore links a new mobile app instance to an already-authenticated
app.

```txt
New app account restore
|- New app random box keypair
|- New app POST /v1/auth/account/request { publicKey: base64 }
|- New app displays happy:///account?<base64url publicKey>
|- Existing app scans URL
|- Existing app POST /v1/auth/account/response Bearer token
|  body { publicKey: base64, response: base64(encrypted account secret) }
`- New app polls POST /v1/auth/account/request until
   { state: "authorized", token, response }
```

Note the URL shape: terminal uses `happy://terminal?`, account linking uses
`happy:///account?`.
Account auth request rows have the same long-lived unique-public-key shape as
terminal auth requests. The new app must generate a fresh temporary keypair for
each QR restore attempt.

Reference: `packages/happy-server/sources/app/api/routes/authRoutes.ts`,
`packages/happy-cli/src/ui/auth.ts`,
`packages/happy-app/sources/auth/authGetToken.ts`,
`packages/happy-app/sources/auth/authApprove.ts`,
`packages/happy-app/sources/auth/authQRStart.ts`,
`packages/happy-app/sources/auth/authQRWait.ts`,
`packages/happy-app/sources/hooks/useConnectTerminal.ts`,
`packages/happy-app/sources/hooks/useConnectAccount.ts`,
`packages/happy-server/prisma/schema.prisma`.

## SyncSocketClient

Responsibilities:

- Own one user-scoped Socket.IO connection.
- Dispatch durable `update` events and transient `ephemeral` events.
- Reconnect forever with short backoff.
- Expose encrypted RPC call helper for session and machine services.

```ts
interface SyncSocketClient {
  connect(endpoint: string, token: string, crypto: CryptoService): void;
  disconnect(): void;
  status(): ConnectionStatus;
  onStatusChange(listener: (status: ConnectionStatus) => void): () => void;
  onReconnect(listener: () => void): () => void;
  onUpdate(listener: (update: ApiUpdateContainer) => void): () => void;
  onEphemeral(listener: (event: ApiEphemeralEvent) => void): () => void;
  sessionRpc<R, A>(sessionId: string, method: string, params: A): Promise<R>;
  machineRpc<R, A>(machineId: string, method: string, params: A): Promise<R>;
}
```

Important Socket.IO events:

- Client receives: `update`, `ephemeral`, `rpc-request`.
- RPC control: `rpc-call`, `rpc-register`, `rpc-unregister`,
  `rpc-registered`, `rpc-unregistered`, `rpc-error`.
- Session-scoped clients can emit `update-metadata`, `update-state`,
  `session-alive`, `session-end`, `message`, `usage-report`.
- Machine-scoped clients can emit `machine-alive`, `machine-update-metadata`,
  `machine-update-state`.
- MVP HarmonyOS app mainly needs user-scoped receive events plus `rpc-call`.

RPC ACK nuance:

- Caller receives `{ ok: boolean, result?: string, error?: string }`.
- Target `rpc-request` callback returns an encrypted string.
- If target handler throws, the CLI `RpcHandlerManager` encrypts
  `{ error: string }` and returns it. The server can still wrap that as
  `{ ok: true, result }`, so callers must decrypt and inspect semantic errors
  in addition to checking `ok`.

Reference: `packages/happy-app/sources/sync/apiSocket.ts`,
`packages/happy-server/sources/app/api/socket.ts`,
`packages/happy-server/sources/app/api/socket/rpcHandler.ts`,
`packages/happy-cli/src/api/rpc/RpcHandlerManager.ts`.

## SessionRepository

Responsibilities:

- Load sessions from `GET /v1/sessions`.
- Decrypt session `dataEncryptionKey`, metadata, and agent state.
- Merge local fields: draft, permission mode, model mode, effort level.
- Derive list state from `active`, `activeAt`, `thinking`, and permission
  requests.

```txt
Initial session load
`- GET /v1/sessions Bearer token
   `- sessions[]
      |- decrypt dataEncryptionKey with content key, if present
      |- initialize SessionCrypto(sessionId, dataKey | legacy)
      |- decrypt metadata
      |- decrypt agentState
      `- applySessions(...)
         |- presence = active ? "online" : activeAt
         |- permission_required if agentState.requests is non-empty
         `- rebuild session list view data
```

MVP list fields:

- `Session.id`, `createdAt`, `updatedAt`, `active`, `activeAt`, `presence`.
- `metadata.summary.text`, `metadata.path`, `metadata.machineId`,
  `metadata.homeDir`, `metadata.flavor`.
- `agentState.requests` for permission-required state.
- `todos`, `draft`, `thinking` can be shown later, but the repository should
  keep them if present.

Reference: `packages/happy-app/sources/sync/sync.ts`,
`packages/happy-app/sources/sync/storage.ts`,
`packages/happy-app/sources/sync/storageTypes.ts`.

## MessageRepository And OutboxService

Messages are not loaded globally at startup. They are fetched lazily per
visible session and by sequence gap.

```txt
Visible session message catch-up
`- GET /v3/sessions/:sessionId/messages?after_seq=<lastSeq>&limit=100
   |- decrypt each { t: "encrypted", c }
   |- normalize RawRecord into UI message model
   |- update sessionLastSeq to max message seq
   `- continue while hasMore
```

```txt
Send message
`- user text
   |- localId = randomUUID()
   |- resolve { permissionMode, model }
   |- RawRecord {
   |    role: "user",
   |    content: { type: "text", text },
   |    meta: { sentFrom, permissionMode, model, fallbackModel, appendSystemPrompt }
   |  }
   |- encryptRawRecord(...)
   |- optimistic local enqueue
   `- POST /v3/sessions/:sessionId/messages
      body { messages: [{ localId, content }] }
      |- server dedups by localId
      `- server emits update { body: { t: "new-message", sid, message } }
```

`permissionMode` should keep the shared Happy values:
`default`, `acceptEdits`, `bypassPermissions`, `plan`, `read-only`,
`safe-yolo`, `yolo`. The current send path sends `model: string | null` in
message metadata. MVP can default the UI to `default`, but the message meta
must preserve selected values when present.

Reference: `packages/happy-app/sources/sync/sync.ts`,
`packages/happy-app/sources/sync/messageMeta.ts`,
`packages/happy-wire/src/messageMeta.ts`,
`packages/happy-server/sources/app/api/routes/v3SessionRoutes.ts`.

## MachineRepository

Responsibilities:

- Load machines from `GET /v1/machines`.
- Decrypt `dataEncryptionKey`, metadata, and daemon state.
- Update online state from `machine-activity` ephemeral events.
- Degrade gracefully if metadata is missing or cannot decrypt.

```txt
Initial machine load
`- GET /v1/machines Bearer token
   `- machines[]
      |- decrypt dataEncryptionKey with content key, if present
      |- initialize MachineCrypto(machineId, dataKey | legacy)
      |- decrypt metadata and daemonState
      `- applyMachines(...)
```

MVP display fields:

- `Machine.id`, `active`, `activeAt`.
- `metadata.displayName || metadata.host || id`.
- `metadata.homeDir`.
- `metadata.cliAvailability` to decide which agents can be started.

If metadata is null, show a stable fallback name and disable spawn. Presence is
derived from machine-scoped connect/disconnect, `machine-alive`, and a 10
minute server timeout.

Sharp edge: the server can emit `new-machine`, but the current app schema does
not handle it. The HarmonyOS MVP can choose to handle `new-machine` directly,
or match current app behavior and rely on `/v1/machines` plus later
`update-machine`. Handling it directly is better for a new client because the
payload includes `dataEncryptionKey`. If the MVP ever ignores `new-machine`,
it must force a `/v1/machines` refetch after terminal QR approval and whenever
an update references an unknown machine id.

Reference: `packages/happy-app/sources/sync/sync.ts`,
`packages/happy-server/sources/app/api/routes/machinesRoutes.ts`,
`packages/happy-server/sources/app/api/socket/machineUpdateHandler.ts`,
`packages/happy-server/sources/app/presence/timeout.ts`.

## MachineRpcClient

Responsibilities:

- Start a new remote Happy session on an online machine.
- Resume a previous remote session when supported.
- Gate resume UI and calls on `machine.metadata.resumeSupport.rpcAvailable`;
  daemons only register `resume-happy-session` when the capability exists.
- Decrypt RPC result and normalize errors.

```ts
interface MachineRpcClient {
  spawnHappySession(input: {
    machineId: string;
    directory: string;
    approvedNewDirectoryCreation?: boolean;
    token?: string;
    agent?: "codex" | "claude" | "gemini" | "openclaw";
  }): Promise<SpawnSessionResult>;

  resumeHappySession(input: {
    machineId: string;
    sessionId: string;
    model?: string;
    permissionMode?: string;
  }): Promise<SpawnSessionResult>;
}
```

```txt
Remote spawn
`- machineRpc(machineId, "spawn-happy-session", encrypted params)
   `- Server rpc-call -> room rpc:<userId>:<machineId>:spawn-happy-session
      `- Daemon rpc-request
         |- decrypt params
         |- maybe request directory creation approval
         |- spawn Happy CLI remote session
         |- wait up to 15s for local /session-started webhook
         `- encrypted result
```

Spawn params must include:

```ts
{
  type: "spawn-in-directory";
  directory: string;
  approvedNewDirectoryCreation?: boolean;
  token?: string;
  agent?: "codex" | "claude" | "gemini" | "openclaw";
}
```

Reference: `packages/happy-app/sources/sync/ops.ts`,
`packages/happy-cli/src/api/apiMachine.ts`,
`packages/happy-cli/src/daemon/run.ts`,
`packages/happy-cli/src/daemon/controlServer.ts`.

## PermissionService

Tool approval is encrypted session RPC. Do not reduce it to a boolean; the
current app supports one-time approval, edit acceptance, bypass, tool-specific
allow lists, Codex approve-for-session, denial, and abort.

```ts
interface PermissionService {
  approve(sessionId: string, requestId: string): Promise<void>;
  approveMode(
    sessionId: string,
    requestId: string,
    mode: "acceptEdits" | "bypassPermissions" | "plan"
  ): Promise<void>;
  approveTools(
    sessionId: string,
    requestId: string,
    allowTools: string[]
  ): Promise<void>;
  approveDecision(
    sessionId: string,
    requestId: string,
    decision: "approved" | "approved_for_session",
    updatedInput?: Record<string, unknown>
  ): Promise<void>;
  deny(
    sessionId: string,
    requestId: string,
    decision?: "denied" | "abort"
  ): Promise<void>;
}
```

Wire call:

```txt
Permission action
`- sessionRpc(sessionId, "permission", SessionPermissionRequest)
   |- encrypt with SessionCrypto
   |- server rpc-call to session-scoped owner
   `- CLI handler resolves waiting permission promise
```

Pending requests come from `agentState.requests`. Completed status can come
from `agentState.completedRequests` or message tool-result permission data.
The UI should represent at least `pending`, `approved`, `denied`, and
`canceled`, with optional `mode`, `allowedTools`, `decision`, `reason`, and
`date`.

Compatibility detail: session RPC requests send the field name `allowTools`.
Some completed permission state is written back as `allowTools`, while current
app UI models often read `allowedTools`. HarmonyOS should send `allowTools`
and tolerate both `allowTools` and `allowedTools` when reading completed
permission state.

Reference: `packages/happy-app/sources/sync/ops.ts`,
`packages/happy-app/sources/components/tools/PermissionFooter.tsx`,
`packages/happy-app/sources/sync/storageTypes.ts`,
`packages/happy-app/sources/sync/reducer/reducer.ts`.

## Reconnect And Catch-Up Rules

```txt
Socket reconnect
|- status = connected
|- invalidate sessions -> GET /v1/sessions
|- invalidate machines -> GET /v1/machines
|- keep outbox send sync active
`- messages
   |- not globally refetched
   `- visible sessions call GET /v3/sessions/:id/messages?after_seq=<lastSeq>
```

Durable update events have a per-user `seq`, but the current app does not rely
on Socket.IO recovery. HarmonyOS should use REST refetch as the source of truth
after reconnect and treat socket updates as fast-path deltas.

Presence:

- Session presence uses `session-alive`, `session-end`, and a 10 minute server
  timeout.
- Machine presence uses machine-scoped connect/disconnect, `machine-alive`,
  and the same 10 minute timeout.
- App-side `presence` can be `active ? "online" : activeAt`.

## Implementation Order

1. Server config screen and `GET /` validation for `https://47.118.25.177`.
2. Secure credential storage and account create/manual restore.
3. Local state store for drafts and session UI mode selections.
4. Crypto service: account secret, content key, auth challenge, base64 helpers.
5. Terminal QR approval V1/V2 and account QR restore.
6. Socket.IO user-scoped connection and reconnect status.
7. Session repository from `/v1/sessions`, including metadata and agentState
   decryption.
8. Message repository and outbox from `/v3/sessions/:id/messages`.
9. Machine repository from `/v1/machines`, including `new-machine` handling
   and degraded display.
10. Machine RPC spawn/resume.
11. Permission service and approval UI.
12. Polish: local drafts, permission mode/model mode persistence, empty/error
   states.

## Source Map

- App entry/config: `packages/happy-app/index.ts`,
  `packages/happy-app/app.config.js`.
- Existing mobile source root: `packages/happy-app/sources`.
- Server root response: `packages/happy-server/sources/app/api/api.ts`.
- Auth routes: `packages/happy-server/sources/app/api/routes/authRoutes.ts`.
- App auth: `packages/happy-app/sources/auth/*`.
- Backup secret parser: `packages/happy-app/sources/auth/secretKeyBackup.ts`.
- CLI auth: `packages/happy-cli/src/ui/auth.ts`.
- Encryption byte layouts: `packages/happy-app/sources/sync/encryption/*`,
  `packages/happy-cli/src/api/encryption.ts`,
  `packages/happy-agent/src/encryption.ts`.
- App sync: `packages/happy-app/sources/sync/sync.ts`,
  `packages/happy-app/sources/sync/apiSocket.ts`,
  `packages/happy-app/sources/sync/ops.ts`.
- Server socket/RPC: `packages/happy-server/sources/app/api/socket.ts`,
  `packages/happy-server/sources/app/api/socket/rpcHandler.ts`,
  `packages/happy-server/sources/app/events/eventRouter.ts`.
- Message routes: `packages/happy-server/sources/app/api/routes/v3SessionRoutes.ts`.
- Machine routes: `packages/happy-server/sources/app/api/routes/machinesRoutes.ts`.
- Types: `packages/happy-app/sources/sync/storageTypes.ts`,
  `packages/happy-wire/src/messageMeta.ts`.
