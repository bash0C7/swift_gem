# rb-apple-sdk-mac — Design Spec

**Date:** 2026-05-04
**Status:** Draft (post-brainstorming, pre-implementation plan)
**Author/User:** bash0C7 (with Claude assistance)
**Repo origin (brainstorming session):** github.com/bash0C7/swift_gem

## 1. Purpose and Scope

Build a Ruby framework that lets a Ruby developer call **any** Apple SDK API on macOS without pre-declaring signatures, types, or stubs. Modeled in spirit on PicoRuby-wasm's `js.c` bridge between Ruby and the browser JavaScript world, but adapted to the realities of Apple platforms — Obj-C runtime, Swift ABI, C frameworks, and Swift-only modern APIs.

The framework is named `rb-apple-sdk-mac`. It is **not** an extension of the existing static-binding gem `swift_gem`; it is a separate runtime-dynamic bridge. `swift_gem` continues to exist for the static path used by gems like `rb-vision-ocrmac`.

### Goals

- **G1.** Ruby developers write zero pre-declarations. `Apple::CoreMIDI.MIDIClientCreate(...)` works as if it always existed.
- **G2.** Coverage spans **all of Apple's macOS SDK**, not a single framework. CoreMIDI is the proving-ground use case but is not the design target.
- **G3.** Hot iteration prioritized: experimenting from `irb` is the primary user story (B:7). Boilerplate reduction is secondary (A:3). OO-Ruby ergonomics is not a goal (C:0) — verbatim Apple naming is acceptable.
- **G4.** Generation must be **on-device, offline, deterministic where possible**. Network access is forbidden in the runtime path.
- **G5.** Swift-only modern APIs (SwiftUI, FoundationModels, SwiftData, Observation) are in scope.

### Non-goals (v1)

- iOS / iPadOS / watchOS / tvOS / visionOS targets (CRuby on those platforms is not supported).
- Third-party (non-Apple) frameworks.
- Apple **private** frameworks under `/System/Library/PrivateFrameworks/` (no public headers, ABI-unstable). The bridge targets only public frameworks visible in the Xcode SDK at `/Applications/Xcode.app/.../MacOSX.sdk/System/Library/Frameworks/` plus their Swift overlays.
- An embedded Swift REPL/interpreter inside Ruby (we use file-based codegen plus swiftc).

### Priority weighting

| Axis | Weight |
|---|---|
| B — hot iteration from `irb` | 7 |
| A — boilerplate reduction | 3 |
| C — Ruby-idiomatic OO ergonomics | 0 |

## 2. Gem Decomposition

Three gems with clean responsibility boundaries.

### 2.1 `rb-foundation-model-mac` (gem A)

- **Role:** Static Swift extension wrapping Apple's Foundation Models (on-device LLM, the text-generation portion of Apple Intelligence).
- **Form:** swift_gem-pattern static native ext, modeled after `rb-vision-mac` / `rb-vision-ocrmac`.
- **Standalone usable:** any Ruby app needing on-device LLM inference depends on this gem alone.
- **Public API surface (sketch):** `AppleFoundationModel.generate(prompt:, schema:)`, `AppleFoundationModel::Session.new(instructions:)`, streaming `respond` helpers.
- **Depends on:** `swift_gem`.
- **Note:** Other Apple Intelligence frameworks (ImagePlayground, Writing Tools, Genmoji) get their own per-framework gems on the same convention. They are not bundled.

### 2.2 `rb-apple-sdk-knowledge` (gem B)

- **Role:** Read-only data gem. Provides a SQLite knowledge base of the Apple SDK API surface installed on the local machine.
- **Form:** Small Ruby loader plus an install-time build script. **The SQLite content is generated at gem-install time against the user's local Xcode SDK** (see §9), not pre-baked at gem release. Same model as swift_gem doing build/generation at install time.
- **Pattern reference:** `chiebukuro-mcp`, `long-term-memory` (SQLite + sqlite-vec, FTS5 trigram + 768-dim vec0).
- **Use cases beyond the bridge:** lint, type completion, RBS generation, IDE plugins.
- **Depends on:** `sqlite3`, `sqlite-vec`. Optionally consults `rb-foundation-model-mac` at install time for embedding generation; if absent, embeddings are populated lazily on first use.

### 2.3 `rb-apple-sdk-mac` (gem C — the bridge proper)

- **Role:** Runtime dynamic bridge. The framework named in this spec's title.
- **Form:** Pure-Ruby framework gem with one internal swift_gem-based static Swift ext (the Glue Runtime).
- **Depends on:** `rb-foundation-model-mac` (for LLM-driven glue codegen), `rb-apple-sdk-knowledge` (for SDK metadata), `swift_gem` (for the Glue Runtime build).

### 2.4 Dependency Graph

```
rb-apple-sdk-mac (gem C)
├──▶ rb-foundation-model-mac (gem A)  ──▶ swift_gem
├──▶ rb-apple-sdk-knowledge (gem B)
└──▶ swift_gem                         (for the Glue Runtime ext build)
```

## 3. Ruby-Side API Surface

### 3.1 Top-Level Constant — `Apple` is a `Ruby::Box`

The bridge uses `Ruby::Box` (Ruby 4.x master feature, `RUBY_BOX=1`) as a hard isolation boundary. The top-level `Apple` constant is itself the box. Reach-in is via the documented `box::Const` syntax.

```ruby
require "rb-apple-sdk-mac"

Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
Apple::Foundation::NSString.stringWithUTF8String("hi")
Apple::FoundationModels::LanguageModelSession.new(instructions: "...")
```

`Ruby::Box` provides isolated constant tables, isolated monkey patches, and isolated top-level methods — meaning the bridge can:
- Define thousands of methods and constants without polluting the user's main namespace.
- Apply security overrides (SecurityCop) only inside the box.
- Coexist with arbitrary other gems without conflict.

### 3.2 Eager `define_method` — No `method_missing`

All known SDK symbols are eagerly defined at gem load time using `define_method` / `const_set` inside the box, populated from the SQLite knowledge base.

- `respond_to?` works naturally.
- `irb` Tab completion works naturally.
- Stack traces don't include `method_missing`.
- Typos hit `NoMethodError` immediately.

`method_missing` is **forbidden as a primary dispatch mechanism** in this gem. The only deliberate use of `method_missing` semantics is via the `did_you_mean` integration (see §3.5).

### 3.3 Symbol-Kind to Ruby Mapping

| Apple side | Ruby representation | Example |
|---|---|---|
| Framework | module | `Apple::CoreMIDI` |
| Function (global) | method on the framework module | `Apple::CoreMIDI.MIDIClientCreate(...)` |
| Type (class / struct / actor) | constant holding a Class proxy | `Apple::Foundation::NSString` |
| Class method | method on the class proxy | `Apple::Foundation::NSString.stringWithUTF8String(...)` |
| Instance method | method on `OpaqueRef` | `ns_str.length` |
| Instance property | accessor method | `ns_str.length`, `view.frame=` |
| Nested type | nested constant | `Apple::Foundation::URL::Components` |
| Swift enum | module + per-case constants | `Apple::CoreMIDI::MIDIObjectType::Client` |
| C enum / `kFooBar` | method on framework module | `Apple::CoreMIDI.kMIDIObjectType_Client` |
| Protocol | module marker | `Apple::FoundationModels::Generable` |
| Global constant (uppercase-first) | constant | `Apple::Foundation::NSUTF8StringEncoding` |
| Global constant (`kFoo` style) | method | `Apple::CoreFoundation.kCFAllocatorDefault` |

Rule: **types → constants**, **functions and lowercase-prefixed globals → methods**. Apple class names are valid Ruby constants by virtue of starting uppercase; the Ruby class object stored in the constant is itself the class proxy. C-style `kFoo` globals cannot be Ruby constants (lowercase initial), so they are exposed as methods.

### 3.4 Selector and Argument Mapping

Obj-C compound selectors map to Ruby keyword arguments after the first positional argument:

```objc
- (void)replaceCharactersInRange:(NSRange)r withString:(NSString *)s;
```

```ruby
ns_str.replaceCharactersInRange(range, withString: "HEY")
```

Rule: first selector segment = positional, subsequent segments = kwargs whose keys are the remaining selector parts.

Out-params (e.g., `OSStatus MIDIClientCreate(name, callback, refcon, MIDIClientRef *outRef)`) and OSStatus-returning C APIs default to **raise on error**, returning the out-ref directly:

```ruby
client = Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
# raises Apple::CoreMIDI::MIDIError if OSStatus != 0
# returns OpaqueRef of MIDIClientRef on success
```

User can opt out via `Apple.configure { |c| c.raise_on_error = false }` to get tuple `[OSStatus, ref]` returns.

### 3.5 Long-Tail (Unknown API) — Explicit `discover`

For symbols not in the SQLite knowledge base (true long-tail), explicit discovery is the entry point. No `method_missing`.

```ruby
Apple.discover(framework: :CoreMIDI, symbol: :MIDISomeBrandNewAPI)
# Generates Swift glue, compiles, dlopens, registers in box.

Apple.discover_framework(:CoreMIDI)
# Bulk discover for an entire framework.
```

When user code calls a not-yet-known symbol, `NoMethodError` fires. A `did_you_mean` integration (`DidYouMean::Correctable`-based, no `method_missing`) provides:

- FTS5 lexical suggestions ("did you mean MIDIClientCreate?")
- vec semantic suggestions
- An explicit pointer to `Apple.discover(...)` if the user genuinely wants a new API

Ruby's standard `did_you_mean` formatter is the integration point — no method_missing or class-level magic needed.

## 4. Internal Architecture

### 4.1 Component Inventory

```
Ruby world (inside Apple = Ruby::Box):

  Apple = Ruby::Box
   ├── eager-defined namespace tree (per gem B SQLite)
   │     each method/class proxy is a thin shim that calls Dispatcher
   │
   ├── Dispatcher  ───▶  Knowledge Cache (SQLite RO from gem B)
   │     │
   │     ▼ glue_id resolved
   │   Glue Loader  ──▶  Compiled Glue Cache (SQLite RW + FS .dylibs)
   │     │
   │     ▼ on miss
   │   Glue Compiler  ──┬──▶ Template Generator (deterministic)
   │     │              │      └─ for known shape patterns (see §4.6)
   │     │              └──▶ LLM (rb-foundation-model-mac)
   │     │                     └─ for novel/complex shapes only
   │     │
   │     ▼ verified .dylib
   │   Glue Runtime (static Swift ext, swift_gem-built)
   │     ├ Ref Table        (Apple object lifetime)
   │     ├ Marshalling      (with zero-copy buffer path)
   │     ├ Callback Bridge  (4 closure conventions)
   │     ├ ARC Bridge       (Ruby GC ↔ Swift release)
   │     ├ Error Bridge     (NSError / Swift throws / OSStatus / Result)
   │     ├ Async Bridge     (Swift async/await + AsyncSequence)
   │     ├ Threading Bridge (GVL ↔ Apple threads)
   │     ├ RunLoop Bridge   (CFRunLoop pump + Fiber.scheduler integration)
   │     └ Conformance Bridge (Ruby class → Swift protocol/superclass)
   │
   ├── SecurityCop (in-box monkey patches; see §7)
   └── Suggestion Engine (irb completion, RBS export, did_you_mean)

Outside the box:
   └── Glue Compiler subprocess invocation (swiftc, file I/O,
       Process.fork) lives outside the Apple box specifically because
       SecurityCop forbids these inside the box.
```

### 4.2 Hot Path (known API call)

```
Ruby:        Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
              │
              ▼ box-internal define_method'd shim
Dispatcher:  framework=:CoreMIDI symbol=:MIDIClientCreate args=[...]
              │
              ▼ Knowledge Cache SELECT (≈1ms)
Glue Loader: glue_id → in-process function pointer (already loaded)
              │
              ▼ single C invocation through Glue Runtime
Apple SDK:   MIDIClientCreate executes
              │
              ▼ marshalling
Ruby:        OpaqueRef of MIDIClientRef returned (or raise on error)
```

No LLM. No swiftc. Single SQLite RO query plus cached function-pointer call.

### 4.3 Cold Path (`discover` for unknown symbol)

```
Apple.discover(framework: :CoreMIDI, symbol: :MIDIWhatever)
   │
   ▼  GATE 1: Knowledge Cache lookup — symbol exists in SDK metadata?
   ▼  GATE 2: Framework allowlist — Apple-only check
   │
   ▼  Knowledge Cache: assemble type info + doc text
   │
   ▼  Glue Compiler:
   │     ├─ Template Generator tries first (deterministic path)
   │     │     └─ if shape recognized, emit Swift glue file
   │     └─ LLM fallback (rb-foundation-model-mac with Generable schema)
   │           └─ on-device, offline, output schema-constrained
   │
   ▼  GATE 3: AST allowlist (SwiftSyntax) — import safety
   ▼  GATE 4: Banned API scan (SwiftSyntax walk)
   ▼  GATE 5: Glue shape verification — single @c export, single target call
   │
   ▼  swiftc invocation (subprocess, outside Apple box)
   │
   ▼  GATE 6: dylib symbol audit (nm / dlsym)
   │
   ▼  Compiled Glue Cache write (SQLite + FS .dylib)
   ▼  Eager define_method on Apple box namespace
   │
   ▼  return — subsequent calls go through Hot Path
```

GATE failures retry up to 3 times against the LLM with the violation as feedback, then fall through to deterministic Template Generator if applicable, then raise `Apple::CompileError`.

### 4.4 Glue Runtime — Swift Public API

```swift
import Foundation

public enum GlueRuntime {
  // ── 1. Ref Table ─────────────────────────────────
  public static func retain(_ obj: AnyObject) -> RefHandle
  public static func release(_ handle: RefHandle)
  public static func lookup<T>(_ handle: RefHandle, as: T.Type) -> T?

  // ── 2. Marshalling ────────────────────────────────
  public static func toRuby(_ swift: Any) -> RubyVALUE
  public static func fromRuby<T>(_ ruby: RubyVALUE, as: T.Type) -> T?
  public static func borrowBufferFromRuby(_ rb: RubyVALUE) -> UnsafeBufferPointer<UInt8>
  public static func lendBufferToRuby(_ ptr: UnsafePointer<UInt8>,
                                      _ count: Int,
                                      lifetime: AnyObject) -> RubyVALUE

  // ── 3. Callback Bridge (4 conventions) ────────────
  public static func registerProcAsCFunction(rubyProcId: UInt64,
                                             signature: String) -> UnsafeMutableRawPointer
  public static func registerProcAsObjcBlock(rubyProcId: UInt64,
                                             signature: String) -> AnyObject
  public static func registerProcAsSwiftClosure<T>(rubyProcId: UInt64,
                                                   _ type: T.Type) -> T
  public static func registerProcAsMainActorAsync(rubyProcId: UInt64,
                                                  signature: String) -> AnyObject

  // ── 4. ARC Bridge ─────────────────────────────────
  public static func bindLifetime(rubyHandle: RubyVALUE, appleObject: AnyObject)
  public static func retainRubyValue(_ rb: RubyVALUE)  // protect Ruby Proc from GC
  public static func releaseRubyValue(_ rb: RubyVALUE)

  // ── 5. Error Bridge ───────────────────────────────
  public static func raiseRuby(_ klass: RubyClass, message: String) -> Never
  public static func wrapNSError(_ error: NSError) -> RubyException
  public static func wrapSwiftError(_ error: Error) -> RubyException

  // ── 6. Async Bridge ───────────────────────────────
  public static func awaitAsync<T>(_ task: () async throws -> T) throws -> T
  public static func bridgeAsyncSequence<S: AsyncSequence>(_ seq: S,
                                                            into: RubyEnumeratorHandle)
  // Cancellation: hooked via signal handler; Ruby Thread#raise → Task.cancel()

  // ── 7. Threading Bridge ───────────────────────────
  public enum CallbackMode { case deferred, synchronous, realtime }
  public static func enqueueCallback(rubyProcId: UInt64,
                                     args: [Any],
                                     mode: CallbackMode)
  public static func dispatchOnMain<T>(_ block: () -> T) -> T

  // ── 8. RunLoop Bridge ─────────────────────────────
  public static func pumpRunLoop(timeoutSeconds: Double)
  public static func runRunLoop(stopFlag: UnsafePointer<Bool>)

  // ── 9. Conformance Bridge ─────────────────────────
  public static func instantiateShim(shimClassName: String,
                                     rubyHandlersHandle: RubyVALUE) -> AnyObject
  // The shim class itself is generated per-protocol/superclass via LLM
}

public typealias RefHandle = UInt32
public typealias RubyVALUE = UInt
```

### 4.5 Generated Glue — Required Shape

```swift
// File generated by Glue Compiler at:
//   ~/.cache/rb-apple-sdk-mac/<sdk_ver>/sources/<glue_id>.swift
import <TargetFramework>      // exactly one Apple framework allowed
import GlueRuntime
import Foundation              // value-type imports only; no I/O API use

@c
public func glue_<glue_id>_<symbol>(
  _ argv: UnsafePointer<RubyVALUE>,
  _ argc: Int32
) -> RubyVALUE {
  // Allowed body content:
  //   1. argc validation
  //   2. GlueRuntime.fromRuby for each arg
  //   3. Single invocation of <symbol> (the API requested by the user)
  //   4. GlueRuntime.toRuby on the result
  //
  // Forbidden:
  //   - Network APIs (URLSession, NSURLConnection, BSD sockets)
  //   - File APIs (FileManager, FileHandle, contents-of-URL initializers)
  //   - Process APIs (Process, posix_spawn, system())
  //   - IPC (NSXPCConnection, NSDistributedNotificationCenter)
  //   - Persistence (UserDefaults, Keychain Services)
  //   - Mutating ProcessInfo.environment
  //   - Any side-effecting call other than the requested symbol
  //   - Multiple @c exports
  //   - Global mutable state
  //   - Public helpers (private only)
}
```

The exception: if the user-requested `<symbol>` itself **is** one of the otherwise-forbidden APIs (e.g., `URLSession.shared.dataTask`), it is the legitimate target invocation and is permitted as the single allowed call.

### 4.6 Template Generator — Shape Catalog (v1)

The Template Generator deterministically emits glue for these shape patterns without invoking the LLM:

- Pure C function: `(Int, String, Pointer) -> Status`
- Pure C function with out params: `(..., inout Result) -> Status`
- Obj-C class method: `+[NSString stringWithUTF8String:]`
- Obj-C instance method: `-[NSString length]`
- Obj-C method with single completion block (escaping)
- Swift module-level synchronous function
- Swift type init / class member access
- Swift property getter/setter
- Foundation value-type natural marshalling

LLM is invoked only for shapes outside this catalog: variadic functions, generics with constraints, async-with-cancellation, AsyncSequence, property wrappers, protocol-conformance shims, class-subclass shims, atypical out-param structures, typedef'd block bodies that need analysis.

## 5. SQLite Schemas

### 5.1 gem B — Knowledge Base (Read-Only at runtime; written at install time)

```sql
CREATE TABLE frameworks (
  id           INTEGER PRIMARY KEY,
  name         TEXT NOT NULL UNIQUE,
  swift_module TEXT NOT NULL,
  category     TEXT,
  doc_url      TEXT,
  min_macos    TEXT
);

CREATE TABLE symbols (
  id              INTEGER PRIMARY KEY,
  framework_id    INTEGER REFERENCES frameworks(id),
  name            TEXT NOT NULL,
  parent_id       INTEGER REFERENCES symbols(id),
  kind            TEXT NOT NULL,   -- function|class|struct|actor|protocol|
                                   -- enum_module|enum_case|class_method|
                                   -- instance_method|class_property|
                                   -- instance_property|global_constant|typealias
  signature       TEXT,
  abi             TEXT NOT NULL,   -- c|objc|swift
  documentation   TEXT,
  return_type     TEXT,
  parameters_json TEXT,
  availability    TEXT,
  deprecated      INTEGER DEFAULT 0,
  requires_main_thread INTEGER DEFAULT 0,
  content_hash    TEXT NOT NULL UNIQUE
);

CREATE INDEX idx_symbols_framework_name ON symbols(framework_id, name);
CREATE INDEX idx_symbols_parent          ON symbols(parent_id);
CREATE INDEX idx_symbols_kind            ON symbols(kind);

CREATE VIRTUAL TABLE symbols_fts USING fts5(
  name, documentation, signature,
  tokenize = 'trigram',
  content = 'symbols',
  content_rowid = 'id'
);

CREATE VIRTUAL TABLE symbols_vec USING vec0(
  symbol_id INTEGER PRIMARY KEY,
  embedding FLOAT[768]
);
```

`content_hash` covers `(framework, name, normalized_signature)`. Argument-name-only differences are normalized away so that semantically-identical signatures collapse to one hash.

### 5.2 gem C — Glue Cache (Read-Write)

```sql
CREATE TABLE compiled_glue (
  glue_id              TEXT PRIMARY KEY,
  framework_name       TEXT NOT NULL,
  symbol_name          TEXT NOT NULL,
  swift_source         BLOB NOT NULL,
  dylib_path           TEXT NOT NULL,
  exported_symbol      TEXT NOT NULL,
  generator            TEXT NOT NULL,   -- 'template'|'llm'
  llm_model_version    TEXT,
  llm_prompt_hash      TEXT,
  compile_swiftc_args  TEXT NOT NULL,
  verification_status  TEXT NOT NULL,   -- 'pass'|'fail'|'pending'
  generated_at         INTEGER NOT NULL,
  last_used_at         INTEGER,
  use_count            INTEGER DEFAULT 0
);

CREATE INDEX idx_glue_framework_symbol ON compiled_glue(framework_name, symbol_name);

CREATE TABLE compile_history (
  id            INTEGER PRIMARY KEY,
  framework     TEXT NOT NULL,
  symbol        TEXT NOT NULL,
  attempt_at    INTEGER NOT NULL,
  generator     TEXT NOT NULL,
  llm_response  BLOB,
  error_stage   TEXT,
  error_detail  TEXT,
  glue_id       TEXT REFERENCES compiled_glue(glue_id)
);

CREATE TABLE conformance_shims (
  shim_id              TEXT PRIMARY KEY,
  protocol_or_class    TEXT NOT NULL,
  framework_name       TEXT NOT NULL,
  swift_source         BLOB NOT NULL,
  dylib_path           TEXT NOT NULL,
  shim_class_name      TEXT NOT NULL,
  required_methods     TEXT NOT NULL,
  generated_at         INTEGER NOT NULL
);
```

The Knowledge Cache (gem B) is mounted via `ATTACH DATABASE` so cross-DB joins work.

## 6. Threading, Async, and RunLoop Concrete Protocols

### 6.1 Threading Bridge

**Ruby → Apple:** Knowledge Cache flags `requires_main_thread`. Dispatcher auto-wraps such calls via `dispatch_async(dispatch_get_main_queue(), ...)` plus a semaphore wait, transparent to the user. Bulk-optimization helper:

```ruby
Apple.on_main_thread { ... }   # all Apple calls inside batched on main queue
```

**Apple → Ruby:** Three callback modes:

- `deferred` (default): Apple thread enqueues to a lock-free queue and returns immediately. Ruby pumps the queue via `Apple.poll_callbacks(timeout:)` on the main Ruby thread (where GVL is held).
- `synchronous` (opt-in): Apple thread acquires GVL via `rb_thread_call_with_gvl` and invokes the Ruby Proc immediately. Used for completion-handler-driven flows where the next step depends on the result. Risky on RT paths.
- `realtime` (opt-in, RT-critical): Apple thread writes to an SPSC ring buffer. Ruby reads via `Apple::CoreMIDI.read_packets(timeout:)` from a regular Ruby thread. No Proc invocation on Apple thread.

### 6.2 Async Bridge

```ruby
# Synchronous form (no Fiber.scheduler required)
response = Apple.await { session.respond(to: "Hello") }

# Fiber.scheduler-aware form (auto-detected)
require 'async'
Async do
  response = Apple.await { session.respond(to: "Hello") }
end

# AsyncSequence as Ruby Enumerator
session.streamResponse(to: "Hello").each { |chunk| print chunk }

# Cancellation: Thread#raise → Swift Task.cancel()
```

Fiber.scheduler integration is in v1 scope.

### 6.3 RunLoop Bridge

```ruby
Apple.run_loop_pump(timeout: 0.01)   # one CFRunLoop cycle, non-blocking

Apple.run_loop do |stop|
  # use stop.call to exit
end

# v1 integrated helper (combines RunLoop + callback queue + Fiber.scheduler)
Apple.event_loop do |ctx|
  # ctx.stop, ctx.elapsed, ctx.fiber_scheduler_active?
  # internal cycle: CFRunLoopRunInMode → callback drain → scheduler yield
  do_periodic_work
  ctx.stop if condition_met
end
```

### 6.4 Worked Example — CoreMIDI Receive Loop

```ruby
require "rb-apple-sdk-mac"

client  = Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
in_port = Apple::CoreMIDI.MIDIInputPortCreate(client, "input", nil, nil) do |packets, _|
  packets.each do |pkt|
    puts "MIDI: #{pkt.data.unpack('C*').inspect} @ #{pkt.timeStamp}"
  end
end

src = Apple::CoreMIDI.MIDIGetSource(0)
Apple::CoreMIDI.MIDIPortConnectSource(in_port, src, nil)

Apple.event_loop { |ctx| ctx.stop if some_condition }
```

Bridges exercised: Marshalling, Glue Loader, Ref Table, Callback Bridge (deferred mode), ARC Bridge, Threading Bridge (MIDI thread → Ruby main), RunLoop Bridge.

## 7. Trust Boundary

### 7.1 Generated Swift Glue — Forbidden Content

Imports allowlist:
- `import <TargetFramework>` — exactly one, the user-requested framework
- `import GlueRuntime`
- `import Foundation` — for value types only

Forbidden APIs in glue body (detected by SwiftSyntax AST walk):
- URL/network: `URLSession`, `NSURLConnection`, `URLRequest` direct construction, `NWConnection`, BSD sockets, `getaddrinfo`
- Files: `FileManager`, `FileHandle`, contents-of-URL initializers on `Data` and `String`, `Bundle.main.url(forResource:)`
- Process: `Process`, `posix_spawn`, `system()`, `execve()`
- IPC: `NSXPCConnection`, `NSDistributedNotificationCenter`
- Persistence: `UserDefaults`, Keychain Services
- Mutating `ProcessInfo.processInfo.environment`

**Exception:** if the user-requested target symbol is one of these APIs, it is the legitimate target invocation. The single-target-call shape rule (§4.5) ensures the rest of the body is still innocent.

### 7.2 Glue Compilation — Hermeticity

- Knowledge Cache lookup → local SQLite, no network.
- LLM invocation → `rb-foundation-model-mac` → on-device Foundation Models, no network.
- swiftc invocation → local toolchain, explicit `-sdk` path, no `DYLD_FALLBACK` modifications.
- dlopen → local `.dylib` from cache.

The runtime path is fully offline. Network access is reserved for the install-time pipeline of `rb-apple-sdk-knowledge` (see §9), which optionally consults `developer.apple.com` and does not execute at end-user runtime after install.

### 7.3 Ruby-Side Forbidden Operations Inside the Box

`SecurityCop` is loaded into the `Apple` Ruby::Box at boot. By Ruby::Box's monkey-patch isolation, these overrides apply only inside the box and have **zero effect on the user's main program**.

Inside the box:
- Forbidden: the string-form code-evaluation methods (Kernel-level eval, plus the eval-family on Module and BasicObject when called with a String argument; and Binding-level evaluation by string). Block forms remain permitted.
- Forbidden: `system`, `spawn`, `exec`, backticks.
- Forbidden: `Net::HTTP`, `URI.open`, `Socket`, etc. — removed/raised on access.
- Forbidden: `File.read`, `IO.read`, `File.open`, etc. except for the gem's own SQLite (which is accessed via `sqlite3` C-ext, not File).
- Permitted exception: subprocess spawn for `swiftc` invocation. Implemented by routing all `swiftc` calls through the **Glue Compiler running outside the box**. The box itself never spawns processes.

Outside the box (user's main program): unchanged. `Net::HTTP`, `system`, and the eval-family work normally.

### 7.4 Validation Gates (compile-time pipeline)

```
GATE 1  Knowledge Cache check          symbol exists in gem B SDK metadata?
GATE 2  Framework allowlist            Apple-only frameworks (no third party)
GATE 3  AST allowlist (SwiftSyntax)    import set adheres to §7.1
GATE 4  Banned API scan                no forbidden API call (except target)
GATE 5  Glue shape verification        single @c export, single target call
GATE 6  Compiled dylib symbol audit    only expected exported symbol
```

Failures retry up to 3 times against the LLM with violation feedback. Then fall to the Template Generator if applicable. Then raise `Apple::CompileError` with `compile_history` row id for inspection.

### 7.5 Cache Integrity

- On startup: each `compiled_glue` row is verified against its `.dylib` (existence + content hash). Mismatches mark the row as `verification_status='pending'` for regeneration on next use.
- SDK version detection: `xcrun --show-sdk-version` compared with stored version. Mismatch → swap to a new `<sdk_ver>` cache directory; previous version retained for rollback.

## 8. Configuration

XDG-respecting layered defaults:

```
priority: ENV > ~/.config/rb-apple-sdk-mac/config.yml > XDG default > built-in
```

YAML example:

```yaml
# ~/.config/rb-apple-sdk-mac/config.yml
cache_dir: /Volumes/SSD/rb-apple-sdk-mac
llm_model: foundation-models/large
trust_mode: review_each_glue   # auto | review_each | review_first
raise_on_error: true
```

Programmatic form:

```ruby
Apple.configure do |c|
  c.cache_dir = "tmp/apple-sdk-cache"
  c.trust_mode = :auto
end
```

## 9. SDK Knowledge Import — Install-Time Pipeline (gem B)

**Runs on the user's machine at `gem install rb-apple-sdk-knowledge` time, against the locally installed Xcode SDK.** This matches the user's actual SDK version and matches the swift_gem precedent of doing build/generation at install time.

```
gem install rb-apple-sdk-knowledge
   │
   ▼
extconf.rb-equivalent install hook fires
   │
   ▼
1. Detect local SDK:
   xcrun --show-sdk-version            → e.g. "26.1"
   xcrun --show-sdk-path               → e.g. "/Applications/Xcode.app/.../MacOSX.sdk"
   ↓ writes to data/sdk_version.txt
   │
   ▼
2. Walk SDK directory for each framework:
   ├─ Parse .swiftinterface (under <fw>.swiftmodule/<arch>.swiftinterface)
   │     → Swift API surface (signatures, generics, availability) via swift-syntax
   └─ Parse module.modulemap + headers (under <fw>.framework/Headers/)
         → C / Obj-C API surface via clang -ast-dump
   ↓ inserts rows into symbols / frameworks
   │
   ▼
3. Walk Apple's local DocC archives:
   /Applications/Xcode.app/.../Documentation/
   docc convert → JSON, join by symbol name with step 2 rows.
   ↓ enriches rows with documentation column
   │
   ▼
4. (Optional) Crawl developer.apple.com for symbols missing doc text:
   - URL pattern: /documentation/<framework>/<symbol>
   - Rate-limited, single-threaded.
   - Skipped when ENV RB_APPLE_SDK_KNOWLEDGE_OFFLINE=1.
   ↓ enriches more rows
   │
   ▼
5. Compute embeddings via rb-foundation-model-mac (if installed):
   - Input: doc + signature
   - Output: 768-dim float vector
   - Skipped when rb-foundation-model-mac is absent or
     ENV RB_APPLE_SDK_KNOWLEDGE_FAST=1; vec search remains available
     but fts5 is the primary lookup until embeddings are filled later.
   ↓ inserts rows into symbols_vec
   │
   ▼
6. Final SQLite at:
   <gem_install_path>/data/sdk_knowledge_<sdk_ver>.sqlite
```

**Dependency-order considerations:**

- gem A (`rb-foundation-model-mac`) is consulted at gem B install time **only if already installed**. If absent, gem B install completes successfully without embeddings; embeddings are filled in lazily on first vec-search miss at runtime by gem C (which always has gem A available as a dependency).
- This avoids a circular install-order dependency and keeps gem B usable as a standalone IDE-completion data source.

**Expected install-time cost (orders of magnitude):**

- Step 2 (SDK walk + parse): seconds to a few minutes (hundreds of frameworks, many thousands of symbols).
- Step 5 (embeddings): minutes to hours depending on model and symbol count. `RB_APPLE_SDK_KNOWLEDGE_FAST=1` skips this and relies on FTS5; embeddings lazy-fill at runtime.

**Re-run triggers:**

- Xcode SDK version change detected on next gem load → emit a "knowledge stale" warning suggesting `gem pristine rb-apple-sdk-knowledge` to rebuild.
- Manual re-run: `bundle exec rake apple:knowledge:rebuild`.

## 10. Versioning and Compatibility

- gem B's `data/sdk_knowledge_<sdk_ver>.sqlite` is generated locally per install and tagged with the user's local SDK version. No per-SDK gem release variants required.
- gem A and gem C track macOS minor version compatibility. The Glue Cache invalidates per-`<sdk_ver>` automatically.
- Ruby version: Ruby 4.x master required (for `Ruby::Box`).
- Swift toolchain: Swift 6.3+ (SE-0495 `@c` attribute).

## 11. Out of Scope (v1)

The following are deferred. Each deferral has a technical justification (not engineering effort).

- **iOS / watchOS / tvOS / visionOS:** CRuby is not supported on these platforms.
- **Third-party (non-Apple) frameworks:** The trust boundary explicitly validates that target framework is Apple-shipped.
- **Embedded Swift REPL:** swiftc-based file codegen is more deterministic and avoids the complexity of embedding the Swift compiler.

Specific bridge features marked `v2` only when there is a concrete technical blocker. None currently identified — all 9 Glue Runtime pillars are v1 scope.

## 12. Open Questions for Review

These items are flagged for the user's pre-implementation review pass.

- **Q1.** Conformance Bridge implementation strategy is LLM-codegen of shim classes per protocol. The exact ABI between the generated shim and the Ruby side (handler dispatch table format, argument marshalling for protocol methods) needs a worked-out example before the first implementation cycle.
- **Q2.** `Ruby::Box`-based gems do not yet have widespread real-world examples. If `RUBY_BOX=1` proves too unstable in Ruby 4.x master during implementation, a fallback isolation strategy (e.g., a vanilla `module Apple` with carefully scoped monkey patches) should be specified. Currently no fallback specified.
- **Q3.** The Template Generator's shape catalog (§4.6) covers what we expect to be the majority case. Empirical validation: pick 50 random Apple SDK functions and check whether each is a template-shape or an LLM-shape. If too many fall to LLM, the catalog needs expansion.
- **Q4.** Install-time embedding generation (§9 step 5) cost may be prohibitive on user machines (potentially hours). A `FAST=1` skip with lazy fill is specified; needs empirical timing on a target machine to decide whether the FAST path should be the default.
- **Q5.** "Ruby block replaces a function-pointer argument in the original Apple signature" is a desirable convention for callback-taking APIs (e.g., `MIDIInputPortCreate` whose `MIDIReadProc` argument is the obvious block target). The exact rule needs nailing down: which callback argument the block replaces (always the last function-pointer argument? the one whose convention is `@convention(c)`? user-selectable per call?), how the still-positional `refCon` arguments are handled, and whether multi-callback APIs accept multiple blocks via `lambda` arguments. The §6.4 worked example currently shows ambiguous arity for `MIDIInputPortCreate` and will be regenerated once this rule lands.
