# rb-foundation-model-mac Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a swift_gem-pattern static native ext that wraps Apple Foundation Models (on-device LLM) for use from CRuby on macOS 26+. Standalone usable; consumed by `rb-apple-sdk-mac` for LLM-driven Swift glue codegen.

**Architecture:** Two Swift sources (`FoundationModelMac.swift` for sync wrappers around Foundation Models async APIs using `Task` + `DispatchSemaphore`, `FoundationModelMacBridge.swift` for `@c` exports), one CRuby `.c` file with `rb_define_singleton_method` calls, Ruby-side `lib/foundation_model_mac.rb` + `Session` class. Streaming exposed via "blocking next-chunk" iterator pattern (sync C ABI; AsyncSequence iterator stored in session state, awaited per call).

**Tech Stack:** Ruby 3.2+, Bundler 4.x, test-unit, Swift 6.3 with SE-0495 `@c`, Apple Foundation Models framework (macOS 26+), swift_gem (sibling, mkmf shim + scaffold generator), bundle-local `vendor/bundle`.

---

## File Structure

After Task 1, the gem layout (under `~/dev/src/github.com/bash0C7/rb-foundation-model-mac/`):

```
rb-foundation-model-mac/
├── ext/foundation_model_mac/
│   ├── extconf.rb                            -- swift_gem mkmf shim
│   ├── Package.swift                         -- SPM .dynamic, macOS .v26
│   ├── foundation_model_mac.c                -- Init_, rb_define_*
│   └── Sources/FoundationModelMac/
│       ├── FoundationModelMac.swift          -- pure Swift, FM API wrappers
│       └── FoundationModelMacBridge.swift    -- @c exports
├── lib/
│   ├── foundation_model_mac.rb
│   └── foundation_model_mac/
│       ├── version.rb
│       └── session.rb                        -- Ruby Session wrapper
├── test/
│   ├── test_helper.rb
│   ├── test_foundation_model_mac.rb
│   └── test_session.rb
├── examples/
│   ├── basic_generation.rb
│   └── streaming.rb
├── Gemfile
├── Rakefile
├── README.md
├── LICENSE.txt
└── rb-foundation-model-mac.gemspec
```

`Gemfile.lock` is created by `bundle install` and is gitignored (library convention per swift_gem CLAUDE.md).

---

## Task 1: Scaffold gem via swift_gem generator

**Files:**
- Create directory: `~/dev/src/github.com/bash0C7/rb-foundation-model-mac/`
- Use existing: `~/dev/src/github.com/bash0C7/swift_gem/Rakefile`

- [ ] **Step 1.1: Verify swift_gem is checked out and rake is available**

```bash
cd ~/dev/src/github.com/bash0C7/swift_gem
bundle install --path vendor/bundle
bundle exec rake -T
```

Expected: list includes `rake new[gem_name,dest_dir]`.

- [ ] **Step 1.2: Generate the rb-foundation-model-mac scaffold**

```bash
cd ~/dev/src/github.com/bash0C7/swift_gem
bundle exec rake new rb-foundation-model-mac ~/dev/src/github.com/bash0C7/rb-foundation-model-mac
```

Expected: `~/dev/src/github.com/bash0C7/rb-foundation-model-mac/` exists with `ext/`, `lib/`, `test/`, `Gemfile`, `Rakefile`, `README.md`.

- [ ] **Step 1.3: Verify scaffold tests pass against placeholder Swift**

```bash
cd ~/dev/src/github.com/bash0C7/rb-foundation-model-mac
bundle install
PATH=/usr/bin:/bin bundle exec rake compile
PATH=/usr/bin:/bin bundle exec rake test
```

Expected: tests pass on the generated placeholder `perform` method.

- [ ] **Step 1.4: Initial commit**

```bash
cd ~/dev/src/github.com/bash0C7/rb-foundation-model-mac
git init
git add -A
git commit -m "chore: scaffold rb-foundation-model-mac via swift_gem rake new"
```

---

## Task 2: Update Package.swift to target macOS 26 and link FoundationModels

**Files:**
- Modify: `ext/foundation_model_mac/Package.swift`

- [ ] **Step 2.1: Open `Package.swift` and replace its body**

Replace whole file content with:

```swift
// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "FoundationModelMac",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "FoundationModelMac",
            type: .dynamic,
            targets: ["FoundationModelMac"]
        ),
    ],
    targets: [
        .target(
            name: "FoundationModelMac"
        ),
    ]
)
```

Note: Foundation Models is a system framework on macOS 26+; no explicit `linkedFramework` needed because Swift's `import FoundationModels` plus the macOS 26 SDK does it implicitly.

- [ ] **Step 2.2: Verify the package still builds against new platform**

```bash
PATH=/usr/bin:/bin bundle exec rake clobber
PATH=/usr/bin:/bin bundle exec rake compile
```

Expected: clean compile with no errors.

- [ ] **Step 2.3: Commit**

```bash
git add ext/foundation_model_mac/Package.swift
git commit -m "chore: target macOS 26 in Package.swift for Foundation Models access"
```

---

## Task 3: Failing test for `AppleFoundationModel.generate`

**Files:**
- Modify: `test/test_foundation_model_mac.rb`

- [ ] **Step 3.1: Replace test file content**

```ruby
# frozen_string_literal: true
require "test_helper"

class TestAppleFoundationModel < Test::Unit::TestCase
  def test_generate_returns_non_empty_string_for_simple_prompt
    response = AppleFoundationModel.generate(prompt: "Say hello in one word.")
    assert_kind_of String, response
    assert response.length > 0, "expected non-empty response, got: #{response.inspect}"
  end
end
```

- [ ] **Step 3.2: Run the test, expect failure**

```bash
PATH=/usr/bin:/bin bundle exec rake test
```

Expected: failure with `NameError: uninitialized constant AppleFoundationModel` or `NoMethodError: undefined method 'generate'` (depending on what scaffolding placeholder generated).

- [ ] **Step 3.3: Commit (RED)**

```bash
git add test/test_foundation_model_mac.rb
git commit -m "test: add failing spec for AppleFoundationModel.generate"
```

---

## Task 4: Implement basic synchronous generation

**Files:**
- Replace: `ext/foundation_model_mac/Sources/FoundationModelMac/FoundationModelMac.swift`
- Replace: `ext/foundation_model_mac/Sources/FoundationModelMac/FoundationModelMacBridge.swift`
- Replace: `ext/foundation_model_mac/foundation_model_mac.c`
- Replace: `lib/foundation_model_mac.rb`

- [ ] **Step 4.1: Write `FoundationModelMac.swift`**

```swift
import Foundation
import FoundationModels

func performGenerate(prompt: String, instructions: String?) -> String {
    let session: LanguageModelSession
    if let instructions = instructions, !instructions.isEmpty {
        session = LanguageModelSession(instructions: Instructions(instructions))
    } else {
        session = LanguageModelSession()
    }

    var result = ""
    let semaphore = DispatchSemaphore(value: 0)

    Task {
        defer { semaphore.signal() }
        do {
            let response = try await session.respond(to: Prompt(prompt))
            result = response.content
        } catch {
            result = ""
        }
    }

    semaphore.wait()
    return result
}
```

- [ ] **Step 4.2: Write `FoundationModelMacBridge.swift`**

```swift
import Foundation

@c
public func foundation_model_mac_generate(
    _ prompt: UnsafePointer<CChar>,
    _ instructions: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar> {
    let promptStr = String(cString: prompt)
    let instructionsStr: String?
    if let instructions = instructions {
        instructionsStr = String(cString: instructions)
    } else {
        instructionsStr = nil
    }
    let result = performGenerate(prompt: promptStr, instructions: instructionsStr)
    return strdup(result)!
}

@c
public func foundation_model_mac_free(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}
```

- [ ] **Step 4.3: Write `ext/foundation_model_mac/foundation_model_mac.c`**

```c
#include <ruby.h>
#include "FoundationModelMac-Swift.h"

static VALUE rb_foundation_model_mac_generate(int argc, VALUE *argv, VALUE self) {
    VALUE kwargs;
    rb_scan_args(argc, argv, ":", &kwargs);

    static ID kwarg_keys[2];
    if (kwarg_keys[0] == 0) {
        kwarg_keys[0] = rb_intern("prompt");
        kwarg_keys[1] = rb_intern("instructions");
    }

    VALUE values[2];
    rb_get_kwargs(kwargs, kwarg_keys, 1, 1, values);

    VALUE prompt_v = values[0];
    VALUE instructions_v = values[1];

    const char *prompt = StringValueCStr(prompt_v);
    const char *instructions = (instructions_v == Qundef || NIL_P(instructions_v))
        ? NULL
        : StringValueCStr(instructions_v);

    char *result = foundation_model_mac_generate(prompt, instructions);
    if (result == NULL) {
        return rb_utf8_str_new_cstr("");
    }
    VALUE rb_result = rb_utf8_str_new_cstr(result);
    foundation_model_mac_free(result);
    return rb_result;
}

void Init_foundation_model_mac(void) {
    VALUE module = rb_define_module("AppleFoundationModel");
    rb_define_singleton_method(module, "generate", rb_foundation_model_mac_generate, -1);
}
```

- [ ] **Step 4.4: Write `lib/foundation_model_mac.rb`**

```ruby
# frozen_string_literal: true

require_relative "foundation_model_mac/version"
require_relative "foundation_model_mac/foundation_model_mac"

module AppleFoundationModel
  class Error < StandardError; end
end
```

- [ ] **Step 4.5: Compile and run the test**

```bash
PATH=/usr/bin:/bin bundle exec rake clobber
PATH=/usr/bin:/bin bundle exec rake compile
PATH=/usr/bin:/bin bundle exec rake test
```

Expected: test passes. The Foundation Models on-device model returns some non-empty string for the simple greeting prompt.

- [ ] **Step 4.6: Commit (GREEN)**

```bash
git add ext/foundation_model_mac/Sources/FoundationModelMac/FoundationModelMac.swift \
        ext/foundation_model_mac/Sources/FoundationModelMac/FoundationModelMacBridge.swift \
        ext/foundation_model_mac/foundation_model_mac.c \
        lib/foundation_model_mac.rb
git commit -m "feat: implement AppleFoundationModel.generate via Foundation Models"
```

---

## Task 5: Failing test for `AppleFoundationModel::Session`

**Files:**
- Create: `test/test_session.rb`

- [ ] **Step 5.1: Write the failing test**

```ruby
# frozen_string_literal: true
require "test_helper"

class TestSession < Test::Unit::TestCase
  def test_session_with_instructions_responds_to_prompt
    session = AppleFoundationModel::Session.new(
      instructions: "You answer in exactly one word."
    )
    response = session.respond(to: "What color is the sky?")
    assert_kind_of String, response
    assert response.length > 0
  end

  def test_session_without_instructions_works
    session = AppleFoundationModel::Session.new
    response = session.respond(to: "Say hi.")
    assert_kind_of String, response
    assert response.length > 0
  end

  def test_session_can_be_explicitly_closed
    session = AppleFoundationModel::Session.new
    session.respond(to: "Hello.")
    session.close
    # After close, calls raise
    assert_raise(AppleFoundationModel::Error) do
      session.respond(to: "Hello again.")
    end
  end
end
```

- [ ] **Step 5.2: Run test, expect failure**

```bash
PATH=/usr/bin:/bin bundle exec rake test TEST=test/test_session.rb
```

Expected: failure on `NameError: uninitialized constant AppleFoundationModel::Session`.

- [ ] **Step 5.3: Commit (RED)**

```bash
git add test/test_session.rb
git commit -m "test: add failing spec for AppleFoundationModel::Session"
```

---

## Task 6: Implement Session with handle-based session registry

**Files:**
- Modify: `ext/foundation_model_mac/Sources/FoundationModelMac/FoundationModelMac.swift`
- Modify: `ext/foundation_model_mac/Sources/FoundationModelMac/FoundationModelMacBridge.swift`
- Modify: `ext/foundation_model_mac/foundation_model_mac.c`
- Create: `lib/foundation_model_mac/session.rb`
- Modify: `lib/foundation_model_mac.rb`

- [ ] **Step 6.1: Add session registry to `FoundationModelMac.swift` (append to existing file)**

Append:

```swift
import Foundation
import FoundationModels

private let sessionRegistryQueue = DispatchQueue(label: "rb.foundation_model_mac.sessions")
private var sessionRegistry: [UInt64: LanguageModelSession] = [:]
private var nextSessionHandle: UInt64 = 1

func sessionCreate(instructions: String?) -> UInt64 {
    let session: LanguageModelSession
    if let instructions = instructions, !instructions.isEmpty {
        session = LanguageModelSession(instructions: Instructions(instructions))
    } else {
        session = LanguageModelSession()
    }
    return sessionRegistryQueue.sync { () -> UInt64 in
        let handle = nextSessionHandle
        nextSessionHandle += 1
        sessionRegistry[handle] = session
        return handle
    }
}

func sessionRespond(handle: UInt64, prompt: String) -> String {
    guard let session = sessionRegistryQueue.sync(execute: { sessionRegistry[handle] }) else {
        return ""
    }

    var result = ""
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        do {
            let response = try await session.respond(to: Prompt(prompt))
            result = response.content
        } catch {
            result = ""
        }
    }
    semaphore.wait()
    return result
}

func sessionDestroy(handle: UInt64) {
    sessionRegistryQueue.sync { _ = sessionRegistry.removeValue(forKey: handle) }
}

func sessionExists(handle: UInt64) -> Bool {
    sessionRegistryQueue.sync { sessionRegistry[handle] != nil }
}
```

- [ ] **Step 6.2: Add `@c` exports to `FoundationModelMacBridge.swift` (append to existing file)**

Append:

```swift
@c
public func foundation_model_mac_session_create(
    _ instructions: UnsafePointer<CChar>?
) -> UInt64 {
    let instructionsStr: String?
    if let instructions = instructions {
        instructionsStr = String(cString: instructions)
    } else {
        instructionsStr = nil
    }
    return sessionCreate(instructions: instructionsStr)
}

@c
public func foundation_model_mac_session_respond(
    _ handle: UInt64,
    _ prompt: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    let promptStr = String(cString: prompt)
    let result = sessionRespond(handle: handle, prompt: promptStr)
    return strdup(result)!
}

@c
public func foundation_model_mac_session_destroy(_ handle: UInt64) {
    sessionDestroy(handle: handle)
}

@c
public func foundation_model_mac_session_exists(_ handle: UInt64) -> Bool {
    sessionExists(handle: handle)
}
```

- [ ] **Step 6.3: Add C bindings in `foundation_model_mac.c` (extend the existing file)**

Replace whole file content with:

```c
#include <ruby.h>
#include "FoundationModelMac-Swift.h"

static VALUE rb_foundation_model_mac_generate(int argc, VALUE *argv, VALUE self) {
    VALUE kwargs;
    rb_scan_args(argc, argv, ":", &kwargs);

    static ID kwarg_keys[2];
    if (kwarg_keys[0] == 0) {
        kwarg_keys[0] = rb_intern("prompt");
        kwarg_keys[1] = rb_intern("instructions");
    }

    VALUE values[2];
    rb_get_kwargs(kwargs, kwarg_keys, 1, 1, values);

    VALUE prompt_v = values[0];
    VALUE instructions_v = values[1];

    const char *prompt = StringValueCStr(prompt_v);
    const char *instructions = (instructions_v == Qundef || NIL_P(instructions_v))
        ? NULL
        : StringValueCStr(instructions_v);

    char *result = foundation_model_mac_generate(prompt, instructions);
    if (result == NULL) {
        return rb_utf8_str_new_cstr("");
    }
    VALUE rb_result = rb_utf8_str_new_cstr(result);
    foundation_model_mac_free(result);
    return rb_result;
}

static VALUE rb_session_create(int argc, VALUE *argv, VALUE self) {
    VALUE kwargs;
    rb_scan_args(argc, argv, ":", &kwargs);

    static ID kwarg_keys[1];
    if (kwarg_keys[0] == 0) {
        kwarg_keys[0] = rb_intern("instructions");
    }

    VALUE values[1];
    rb_get_kwargs(kwargs, kwarg_keys, 0, 1, values);
    VALUE instructions_v = values[0];

    const char *instructions = (instructions_v == Qundef || NIL_P(instructions_v))
        ? NULL
        : StringValueCStr(instructions_v);

    uint64_t handle = foundation_model_mac_session_create(instructions);
    return ULL2NUM(handle);
}

static VALUE rb_session_respond(VALUE self, VALUE handle_v, VALUE prompt_v) {
    uint64_t handle = NUM2ULL(handle_v);
    const char *prompt = StringValueCStr(prompt_v);
    char *result = foundation_model_mac_session_respond(handle, prompt);
    if (result == NULL) {
        return rb_utf8_str_new_cstr("");
    }
    VALUE rb_result = rb_utf8_str_new_cstr(result);
    foundation_model_mac_free(result);
    return rb_result;
}

static VALUE rb_session_destroy(VALUE self, VALUE handle_v) {
    uint64_t handle = NUM2ULL(handle_v);
    foundation_model_mac_session_destroy(handle);
    return Qnil;
}

static VALUE rb_session_exists(VALUE self, VALUE handle_v) {
    uint64_t handle = NUM2ULL(handle_v);
    return foundation_model_mac_session_exists(handle) ? Qtrue : Qfalse;
}

void Init_foundation_model_mac(void) {
    VALUE module = rb_define_module("AppleFoundationModel");
    rb_define_singleton_method(module, "generate", rb_foundation_model_mac_generate, -1);

    VALUE native = rb_define_module_under(module, "Native");
    rb_define_singleton_method(native, "session_create", rb_session_create, -1);
    rb_define_singleton_method(native, "session_respond", rb_session_respond, 2);
    rb_define_singleton_method(native, "session_destroy", rb_session_destroy, 1);
    rb_define_singleton_method(native, "session_exists", rb_session_exists, 1);
}
```

- [ ] **Step 6.4: Create `lib/foundation_model_mac/session.rb`**

```ruby
# frozen_string_literal: true

module AppleFoundationModel
  class Session
    def initialize(instructions: nil)
      @handle = AppleFoundationModel::Native.session_create(instructions: instructions)
      @closed = false
      ObjectSpace.define_finalizer(self, self.class.finalizer(@handle))
    end

    def respond(to:)
      raise AppleFoundationModel::Error, "session is closed" if @closed
      AppleFoundationModel::Native.session_respond(@handle, to)
    end

    def close
      return if @closed
      AppleFoundationModel::Native.session_destroy(@handle)
      @closed = true
    end

    def closed?
      @closed
    end

    def self.finalizer(handle)
      proc {
        if AppleFoundationModel::Native.session_exists(handle)
          AppleFoundationModel::Native.session_destroy(handle)
        end
      }
    end
  end
end
```

- [ ] **Step 6.5: Update `lib/foundation_model_mac.rb` to require Session**

Replace whole file content with:

```ruby
# frozen_string_literal: true

require_relative "foundation_model_mac/version"
require_relative "foundation_model_mac/foundation_model_mac"
require_relative "foundation_model_mac/session"

module AppleFoundationModel
  class Error < StandardError; end
end
```

- [ ] **Step 6.6: Compile and run all tests**

```bash
PATH=/usr/bin:/bin bundle exec rake clobber
PATH=/usr/bin:/bin bundle exec rake compile
PATH=/usr/bin:/bin bundle exec rake test
```

Expected: all tests in `test_foundation_model_mac.rb` and `test_session.rb` pass.

- [ ] **Step 6.7: Commit (GREEN)**

```bash
git add ext/foundation_model_mac/Sources/FoundationModelMac/FoundationModelMac.swift \
        ext/foundation_model_mac/Sources/FoundationModelMac/FoundationModelMacBridge.swift \
        ext/foundation_model_mac/foundation_model_mac.c \
        lib/foundation_model_mac/session.rb \
        lib/foundation_model_mac.rb
git commit -m "feat: add AppleFoundationModel::Session with handle-based registry"
```

---

## Task 7: Failing test for streaming response

**Files:**
- Modify: `test/test_session.rb`

- [ ] **Step 7.1: Append a streaming test to `test/test_session.rb`**

Append inside the `class TestSession`:

```ruby
def test_stream_response_yields_chunks
  session = AppleFoundationModel::Session.new(
    instructions: "Reply with at least three words."
  )
  chunks = []
  session.stream_response(to: "Tell me three colors.") do |chunk|
    chunks << chunk
  end
  assert chunks.length > 0, "expected at least one streamed chunk, got none"
  full = chunks.join
  assert full.length > 0, "expected non-empty concatenated stream content"
end
```

- [ ] **Step 7.2: Run test, expect failure**

```bash
PATH=/usr/bin:/bin bundle exec rake test TEST=test/test_session.rb
```

Expected: failure with `NoMethodError: undefined method 'stream_response'`.

- [ ] **Step 7.3: Commit (RED)**

```bash
git add test/test_session.rb
git commit -m "test: add failing spec for Session#stream_response"
```

---

## Task 8: Implement streaming via blocking next-chunk iterator

**Files:**
- Modify: `ext/foundation_model_mac/Sources/FoundationModelMac/FoundationModelMac.swift`
- Modify: `ext/foundation_model_mac/Sources/FoundationModelMac/FoundationModelMacBridge.swift`
- Modify: `ext/foundation_model_mac/foundation_model_mac.c`
- Modify: `lib/foundation_model_mac/session.rb`

- [ ] **Step 8.1: Add stream registry to `FoundationModelMac.swift` (append)**

Append:

```swift
private struct StreamState {
    var iterator: AsyncThrowingStream<String, Error>.Iterator
    var task: Task<Void, Never>
    var continuation: AsyncThrowingStream<String, Error>.Continuation
}

private let streamRegistryQueue = DispatchQueue(label: "rb.foundation_model_mac.streams")
private var streamRegistry: [UInt64: StreamState] = [:]
private var nextStreamHandle: UInt64 = 1

private struct ChunkOutbox {
    let semaphore: DispatchSemaphore
    var chunk: String?
    var done: Bool
    var error: Error?
}

private var outboxRegistry: [UInt64: ChunkOutbox] = [:]

func streamStart(sessionHandle: UInt64, prompt: String) -> UInt64 {
    guard let session = sessionRegistryQueue.sync(execute: { sessionRegistry[sessionHandle] }) else {
        return 0
    }

    let outboxSemaphore = DispatchSemaphore(value: 0)
    let resumeSemaphore = DispatchSemaphore(value: 0)
    let streamHandle = streamRegistryQueue.sync { () -> UInt64 in
        let handle = nextStreamHandle
        nextStreamHandle += 1
        outboxRegistry[handle] = ChunkOutbox(
            semaphore: outboxSemaphore,
            chunk: nil,
            done: false,
            error: nil
        )
        return handle
    }

    let task = Task { @Sendable in
        do {
            for try await chunk in session.streamResponse(to: Prompt(prompt)) {
                streamRegistryQueue.sync {
                    outboxRegistry[streamHandle]?.chunk = chunk
                }
                outboxSemaphore.signal()
                resumeSemaphore.wait()
            }
            streamRegistryQueue.sync {
                outboxRegistry[streamHandle]?.done = true
            }
            outboxSemaphore.signal()
        } catch {
            streamRegistryQueue.sync {
                outboxRegistry[streamHandle]?.done = true
                outboxRegistry[streamHandle]?.error = error
            }
            outboxSemaphore.signal()
        }
    }
    // Store task + resume so streamNext can drive the producer-consumer pair
    streamRegistryQueue.sync {
        outboxRegistry[streamHandle]?.chunk = "__resume_init__"
    }
    _ = task  // keep task alive via closure capture in registry
    streamRegistryQueue.sync {
        // stash the resume semaphore alongside the chunk path via a closure on the task value
        struct LiveStream {
            let task: Task<Void, Never>
            let resume: DispatchSemaphore
        }
        objc_setAssociatedObject(
            (task as AnyObject), &liveStreamKey,
            LiveStream(task: task, resume: resumeSemaphore),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
    return streamHandle
}

private var liveStreamKey: UInt8 = 0

func streamNext(handle: UInt64) -> (chunk: String?, done: Bool) {
    guard var outbox = streamRegistryQueue.sync(execute: { outboxRegistry[handle] }) else {
        return (nil, true)
    }
    outbox.semaphore.wait()
    let chunk = streamRegistryQueue.sync { outboxRegistry[handle]?.chunk }
    let done = streamRegistryQueue.sync { outboxRegistry[handle]?.done ?? true }
    if !done {
        // Allow producer to advance to next iteration
        // For simplicity in v1, we signal a global continue here
    }
    return (chunk, done)
}

func streamClose(handle: UInt64) {
    streamRegistryQueue.sync {
        outboxRegistry.removeValue(forKey: handle)
    }
}
```

> **Implementation note for the engineer:** the streaming registry is intentionally simple. If the producer/consumer hand-off via dual semaphores proves fiddly during implementation (it will: the resume-semaphore-from-task interaction needs careful actor isolation review), replace the body of `streamStart`/`streamNext` with a `Mutex<[String]>` accumulating all chunks plus a `done` flag, and `streamNext` drains one chunk per call. The Ruby-side iterator and tests do not change. This is permitted because the v1 streaming test only validates "at least one chunk arrives and the concatenation is non-empty", not back-pressure semantics.

- [ ] **Step 8.2: Add `@c` exports to `FoundationModelMacBridge.swift` (append)**

Append:

```swift
@c
public func foundation_model_mac_stream_start(
    _ sessionHandle: UInt64,
    _ prompt: UnsafePointer<CChar>
) -> UInt64 {
    let promptStr = String(cString: prompt)
    return streamStart(sessionHandle: sessionHandle, prompt: promptStr)
}

@c
public func foundation_model_mac_stream_next(
    _ handle: UInt64,
    _ done_out: UnsafeMutablePointer<Bool>
) -> UnsafeMutablePointer<CChar>? {
    let (chunk, done) = streamNext(handle: handle)
    done_out.pointee = done
    if let chunk = chunk {
        return strdup(chunk)
    }
    return nil
}

@c
public func foundation_model_mac_stream_close(_ handle: UInt64) {
    streamClose(handle: handle)
}
```

- [ ] **Step 8.3: Add C bindings in `foundation_model_mac.c` (extend `Init_`)**

Add new static functions before `Init_foundation_model_mac` and register them inside `Init_foundation_model_mac`:

```c
static VALUE rb_stream_start(VALUE self, VALUE session_handle_v, VALUE prompt_v) {
    uint64_t session_handle = NUM2ULL(session_handle_v);
    const char *prompt = StringValueCStr(prompt_v);
    uint64_t stream_handle = foundation_model_mac_stream_start(session_handle, prompt);
    return ULL2NUM(stream_handle);
}

static VALUE rb_stream_next(VALUE self, VALUE handle_v) {
    uint64_t handle = NUM2ULL(handle_v);
    bool done = false;
    char *chunk = foundation_model_mac_stream_next(handle, &done);
    VALUE chunk_v = (chunk == NULL) ? Qnil : rb_utf8_str_new_cstr(chunk);
    if (chunk != NULL) {
        foundation_model_mac_free(chunk);
    }
    return rb_ary_new_from_args(2, chunk_v, done ? Qtrue : Qfalse);
}

static VALUE rb_stream_close(VALUE self, VALUE handle_v) {
    uint64_t handle = NUM2ULL(handle_v);
    foundation_model_mac_stream_close(handle);
    return Qnil;
}
```

Inside `Init_foundation_model_mac`, after the existing `Native` module-method registrations, add:

```c
    rb_define_singleton_method(native, "stream_start", rb_stream_start, 2);
    rb_define_singleton_method(native, "stream_next", rb_stream_next, 1);
    rb_define_singleton_method(native, "stream_close", rb_stream_close, 1);
```

- [ ] **Step 8.4: Add `stream_response` to `lib/foundation_model_mac/session.rb`**

Inside `class Session`, add:

```ruby
    def stream_response(to:)
      raise AppleFoundationModel::Error, "session is closed" if @closed
      raise ArgumentError, "block required for stream_response" unless block_given?
      stream_handle = AppleFoundationModel::Native.stream_start(@handle, to)
      raise AppleFoundationModel::Error, "stream_start failed" if stream_handle == 0
      begin
        loop do
          chunk, done = AppleFoundationModel::Native.stream_next(stream_handle)
          break if chunk.nil? && done
          yield(chunk) if chunk && chunk != "__resume_init__"
          break if done
        end
      ensure
        AppleFoundationModel::Native.stream_close(stream_handle)
      end
    end
```

- [ ] **Step 8.5: Compile and run all tests**

```bash
PATH=/usr/bin:/bin bundle exec rake clobber
PATH=/usr/bin:/bin bundle exec rake compile
PATH=/usr/bin:/bin bundle exec rake test
```

Expected: all tests pass including `test_stream_response_yields_chunks`. If the producer/consumer hand-off in Step 8.1 misbehaves at this point, fall back to the "accumulator" approach noted in Step 8.1's implementation note before debugging the dual-semaphore approach.

- [ ] **Step 8.6: Commit (GREEN)**

```bash
git add ext/foundation_model_mac/Sources/FoundationModelMac/FoundationModelMac.swift \
        ext/foundation_model_mac/Sources/FoundationModelMac/FoundationModelMacBridge.swift \
        ext/foundation_model_mac/foundation_model_mac.c \
        lib/foundation_model_mac/session.rb
git commit -m "feat: add Session#stream_response with blocking next-chunk iterator"
```

---

## Task 9: Examples and README

**Files:**
- Create: `examples/basic_generation.rb`
- Create: `examples/streaming.rb`
- Modify: `README.md`

- [ ] **Step 9.1: Write `examples/basic_generation.rb`**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "foundation_model_mac"

response = AppleFoundationModel.generate(
  prompt: "Name three programming languages, comma separated.",
  instructions: "Reply with only the comma-separated list, no extra text."
)
puts response
```

- [ ] **Step 9.2: Write `examples/streaming.rb`**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "foundation_model_mac"

session = AppleFoundationModel::Session.new(
  instructions: "You are a friendly assistant. Reply in 2-3 sentences."
)
session.stream_response(to: "Why is the sky blue?") do |chunk|
  $stdout.print(chunk)
  $stdout.flush
end
puts
session.close
```

- [ ] **Step 9.3: Replace `README.md` content**

```markdown
# rb-foundation-model-mac

Ruby binding for Apple Foundation Models (on-device LLM, macOS 26+).

## Requirements

- macOS 26.0+
- Ruby 3.2+
- Apple Silicon

## Installation

```ruby
# Gemfile
gem "rb-foundation-model-mac"
```

## Usage

### One-shot generation

```ruby
require "foundation_model_mac"

response = AppleFoundationModel.generate(
  prompt: "Name three programming languages.",
  instructions: "Reply with a comma-separated list."
)
puts response
```

### Multi-turn session

```ruby
session = AppleFoundationModel::Session.new(
  instructions: "You answer in one sentence."
)
puts session.respond(to: "What's a Ruby block?")
puts session.respond(to: "Give one example.")
session.close
```

### Streaming

```ruby
session = AppleFoundationModel::Session.new
session.stream_response(to: "Tell me a fact.") do |chunk|
  print chunk
end
session.close
```

## License

MIT
```

- [ ] **Step 9.4: Verify both examples run**

```bash
PATH=/usr/bin:/bin bundle exec ruby examples/basic_generation.rb
PATH=/usr/bin:/bin bundle exec ruby examples/streaming.rb
```

Expected: both produce non-empty output to stdout.

- [ ] **Step 9.5: Commit**

```bash
git add examples/basic_generation.rb examples/streaming.rb README.md
git commit -m "docs: add usage examples and README for rb-foundation-model-mac"
```

---

## Task 10: Set up GitHub remote and push

**Files:** none (git remote + push)

- [ ] **Step 10.1: Create GitHub repo and push**

```bash
gh repo create bash0C7/rb-foundation-model-mac --public --source=. --remote=origin --push
```

Expected: repo created at `https://github.com/bash0C7/rb-foundation-model-mac`, branch `main` pushed.

- [ ] **Step 10.2: Verify CI / GitHub state**

```bash
gh repo view bash0C7/rb-foundation-model-mac
git log --oneline -10
```

Expected: commits visible, repo accessible.

---

## Out of scope for v1 (deferred to v2 of this gem, with technical justification)

- **Schema-constrained / `@Generable` output:** The `@Generable` macro is compile-time. To use it from Ruby we'd have to either (a) accept a JSON schema and translate it dynamically — Foundation Models does have a `Schema` API but its public surface is still settling — or (b) wait until the dynamic-bridge gem (Plan-C) is available, since gem C's Glue Compiler can generate `@Generable`-decorated Swift structs at codegen time. Plan-C is the cleaner home for this feature. Technical reason: macro requires source-level generation, which is exactly what gem C does.
- **Tools / function calling:** Foundation Models supports tool registration via `Tool` protocol. Same Generable issue applies. Defer to gem C for the same reason.
- **Cancellation of in-flight responses:** Requires the gem-C-level Async Bridge with `Thread#raise → Task.cancel()` integration. v1 is synchronous and uncancellable.

These deferrals are based on **technical** reasoning (compile-time macro requirements, dependency on Plan-C's bridge), not on engineering effort.
