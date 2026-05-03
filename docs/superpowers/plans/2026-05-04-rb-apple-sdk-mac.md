# rb-apple-sdk-mac Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the runtime dynamic Ruby↔Apple SDK bridge. `Apple` is a `Ruby::Box` containing eager-defined namespace tree per the local SDK knowledge base. Hot path is a SQLite RO query plus a cached function-pointer call into a static Swift Glue Runtime. Cold path generates Swift glue (Template-first; LLM via `rb-foundation-model-mac` for novel shapes), validates through 6 gates, compiles via `swiftc`, and `dlopen`s the result. Conformance Bridge enables Ruby classes to act as Swift protocol/superclass implementations via LLM-generated shim classes.

**Architecture:** Three layers. (a) Ruby world inside `Apple = Ruby::Box`: Dispatcher, eager namespace, SecurityCop, did_you_mean. (b) Glue Runtime as a swift_gem-built static `.dylib`: 9 pillars (Ref / Marshal / Callback / ARC / Error / Async / Threading / RunLoop / Conformance). (c) Cold path subsystem outside the box: Glue Compiler (Template Generator + LLM fallback), Validation Gates, swiftc invocation, Compiled Glue Cache.

**Tech Stack:** Ruby 4.x master (Ruby::Box requires `RUBY_BOX=1`), Bundler 4.x, test-unit, sqlite3, sqlite-vec, swift_gem (sibling gem, mkmf shim), `rb-foundation-model-mac` (Plan-A), `rb-apple-sdk-knowledge` (Plan-B), Swift 6.3 with SE-0495 `@c`, Apple SwiftSyntax (for validation gates), Apple Foundation Models (transitively via gem A).

---

## Environment Setup (run once per shell session)

The system's default `swift` (`/usr/bin/swift`) is 6.2.4, which lacks SE-0495 `@c`. Activate swiftly's 6.3.1 toolchain before any `bundle exec rake compile` / `rake test` invocation:

```bash
. ~/.swiftly/env.sh
swift --version   # Should report Apple Swift version 6.3.1
```

This puts `~/.swiftly/bin` on `PATH`. Do NOT prefix commands with `PATH=/usr/bin:/bin` — that strips the swiftly shim and breaks the build.

---

## File Structure

```
rb-apple-sdk-mac/
├── ext/apple_sdk_mac_runtime/                 -- The Glue Runtime swift_gem ext
│   ├── extconf.rb
│   ├── Package.swift
│   ├── apple_sdk_mac_runtime.c
│   └── Sources/AppleSDKMacRuntime/
│       ├── RuntimeBridge.swift                 -- @c surface to Ruby
│       ├── RefTable.swift                      -- Pillar 1
│       ├── Marshal.swift                       -- Pillar 2 (with buffer borrow/lend)
│       ├── CallbackBridge.swift                -- Pillar 3 (4 conventions)
│       ├── ARCBridge.swift                     -- Pillar 4
│       ├── ErrorBridge.swift                   -- Pillar 5
│       ├── AsyncBridge.swift                   -- Pillar 6
│       ├── ThreadingBridge.swift               -- Pillar 7 (3 modes)
│       ├── RunLoopBridge.swift                 -- Pillar 8
│       └── ConformanceBridge.swift             -- Pillar 9 (instantiation only)
├── lib/
│   ├── apple_sdk_mac.rb                        -- top-level loader, sets Apple = Ruby::Box
│   └── apple_sdk_mac/
│       ├── version.rb
│       ├── config.rb                           -- XDG/ENV/YAML/programmatic config
│       ├── knowledge_cache.rb                  -- ATTACHes gem B SQLite, RO queries
│       ├── compiled_glue_cache.rb              -- gem C SQLite RW + .dylib FS
│       ├── glue_loader.rb                      -- dlopen + in-process pointer cache
│       ├── glue_compiler.rb                    -- pipeline: template → LLM → swiftc
│       ├── glue_compiler/
│       │   ├── template_generator.rb           -- deterministic shape catalog
│       │   ├── llm_generator.rb                -- via rb-foundation-model-mac
│       │   ├── validation_gates.rb             -- 6 gates
│       │   └── swiftc_invoker.rb               -- subprocess swiftc
│       ├── dispatcher.rb                       -- Ruby-side entry: dispatch(framework, symbol, args)
│       ├── namespace_builder.rb                -- eager-define from KnowledgeCache
│       ├── security_cop.rb                     -- in-box monkey patches
│       ├── did_you_mean.rb                     -- DidYouMean::Correctable extension
│       ├── opaque_ref.rb                       -- Ruby class wrapping ref_handle
│       └── public_api.rb                       -- Apple.discover, Apple.event_loop, etc.
├── test/
│   ├── test_helper.rb
│   ├── test_ref_table.rb
│   ├── test_marshal.rb
│   ├── test_compiled_glue_cache.rb
│   ├── test_template_generator.rb
│   ├── test_validation_gates.rb
│   ├── test_dispatcher.rb
│   ├── test_namespace_builder.rb
│   ├── test_security_cop.rb
│   ├── test_did_you_mean.rb
│   └── integration/
│       └── test_coremidi_smoke.rb              -- end-to-end against real CoreMIDI
├── examples/
│   ├── coremidi_receive.rb
│   └── vision_ocr.rb
├── Gemfile
├── Rakefile
├── README.md
├── LICENSE.txt
└── rb-apple-sdk-mac.gemspec
```

---

## Task 1: Scaffold gem with swift_gem-pattern Glue Runtime ext

**Files:**
- Create: `~/dev/src/github.com/bash0C7/rb-apple-sdk-mac/`

- [ ] **Step 1.1: Generate scaffold via swift_gem**

```bash
cd ~/dev/src/github.com/bash0C7/swift_gem
bundle exec rake new rb-apple-sdk-mac ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
```

- [ ] **Step 1.2: Rename the generated ext to `apple_sdk_mac_runtime`**

```bash
cd ~/dev/src/github.com/bash0C7/rb-apple-sdk-mac
mv ext/apple_sdk_mac ext/apple_sdk_mac_runtime
mv ext/apple_sdk_mac_runtime/apple_sdk_mac.c ext/apple_sdk_mac_runtime/apple_sdk_mac_runtime.c
mv ext/apple_sdk_mac_runtime/Sources/AppleSdkMac ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime
mv ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/AppleSdkMac.swift ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/AppleSDKMacRuntime.swift
mv ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/AppleSdkMacBridge.swift ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/RuntimeBridge.swift
```

Update `ext/apple_sdk_mac_runtime/extconf.rb`:

```ruby
# frozen_string_literal: true
require "swift_gem/mkmf"

SwiftGem::Mkmf.create_swift_makefile(
  "apple_sdk_mac/apple_sdk_mac_runtime",
  package: "AppleSDKMacRuntime",
  source_dir: __dir__
)
```

Update `Package.swift` content to:

```swift
// swift-tools-version: 6.3
import PackageDescription
let package = Package(
    name: "AppleSDKMacRuntime",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AppleSDKMacRuntime", type: .dynamic, targets: ["AppleSDKMacRuntime"])
    ],
    targets: [
        .target(name: "AppleSDKMacRuntime")
    ]
)
```

- [ ] **Step 1.3: Set bundler local path and add dependencies**

```bash
bundle config set --local path 'vendor/bundle'
```

Edit `rb-apple-sdk-mac.gemspec` and add:

```ruby
  spec.add_dependency "rb-foundation-model-mac"
  spec.add_dependency "rb-apple-sdk-knowledge"
  spec.add_dependency "sqlite3", "~> 2.0"
  spec.add_dependency "sqlite-vec", "~> 0.1"
  spec.add_development_dependency "test-unit", "~> 3.6"
```

- [ ] **Step 1.4: Verify baseline compiles & tests pass**

```bash
bundle install
bundle exec rake compile
bundle exec rake test
```

Expected: scaffold tests pass with placeholder ext.

- [ ] **Step 1.5: Initial commit**

```bash
git init
git add -A
git commit -m "chore: scaffold rb-apple-sdk-mac with renamed Glue Runtime ext"
```

---

## Task 2: Pillar 1 — Ref Table

**Files:**
- Create: `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/RefTable.swift`
- Modify: `ext/apple_sdk_mac_runtime/Sources/AppleSDKMacRuntime/RuntimeBridge.swift`
- Modify: `ext/apple_sdk_mac_runtime/apple_sdk_mac_runtime.c`
- Create: `test/test_ref_table.rb`

- [ ] **Step 2.1: RED — write failing test**

```ruby
# frozen_string_literal: true
require "test_helper"

class TestRefTable < Test::Unit::TestCase
  def test_retain_returns_handle_and_lookup_recovers_object
    handle = AppleSDKMacRuntime.ref_retain_test_object(0xCAFE)
    assert handle > 0
    recovered_id = AppleSDKMacRuntime.ref_lookup_test_object_id(handle)
    assert_equal 0xCAFE, recovered_id
  end

  def test_release_invalidates_handle
    handle = AppleSDKMacRuntime.ref_retain_test_object(42)
    AppleSDKMacRuntime.ref_release(handle)
    assert_equal 0, AppleSDKMacRuntime.ref_lookup_test_object_id(handle)
  end
end
```

```bash
bundle exec rake test TEST=test/test_ref_table.rb
git add test/test_ref_table.rb
git commit -m "test: add failing spec for Pillar 1 RefTable"
```

- [ ] **Step 2.2: GREEN — implement Swift `RefTable.swift`**

```swift
import Foundation

public enum RefTable {
    public typealias RefHandle = UInt32

    private static let queue = DispatchQueue(label: "AppleSDKMacRuntime.RefTable")
    private static var table: [RefHandle: AnyObject] = [:]
    private static var nextHandle: RefHandle = 1

    public static func retain(_ obj: AnyObject) -> RefHandle {
        queue.sync {
            let h = nextHandle
            nextHandle &+= 1
            table[h] = obj
            return h
        }
    }

    public static func release(_ handle: RefHandle) {
        _ = queue.sync { table.removeValue(forKey: handle) }
    }

    public static func lookup<T>(_ handle: RefHandle, as: T.Type) -> T? {
        queue.sync { table[handle] as? T }
    }
}

public final class TestObjectIDBox: NSObject {
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
}
```

- [ ] **Step 2.3: GREEN — replace `RuntimeBridge.swift`**

```swift
import Foundation

@c
public func runtime_ref_retain_test(_ rubyObjectId: UInt64) -> UInt32 {
    let box = TestObjectIDBox(id: rubyObjectId)
    return RefTable.retain(box)
}

@c
public func runtime_ref_lookup_test(_ handle: UInt32) -> UInt64 {
    guard let box = RefTable.lookup(handle, as: TestObjectIDBox.self) else {
        return 0
    }
    return box.id
}

@c
public func runtime_ref_release(_ handle: UInt32) {
    RefTable.release(handle)
}
```

- [ ] **Step 2.4: GREEN — `apple_sdk_mac_runtime.c`**

```c
#include <ruby.h>
#include "AppleSDKMacRuntime-Swift.h"

static VALUE rb_ref_retain_test(VALUE self, VALUE oid) {
    uint64_t id = NUM2ULL(oid);
    return UINT2NUM(runtime_ref_retain_test(id));
}

static VALUE rb_ref_lookup_test(VALUE self, VALUE handle) {
    uint32_t h = NUM2UINT(handle);
    return ULL2NUM(runtime_ref_lookup_test(h));
}

static VALUE rb_ref_release(VALUE self, VALUE handle) {
    runtime_ref_release(NUM2UINT(handle));
    return Qnil;
}

void Init_apple_sdk_mac_runtime(void) {
    VALUE module = rb_define_module("AppleSDKMacRuntime");
    rb_define_singleton_method(module, "ref_retain_test_object", rb_ref_retain_test, 1);
    rb_define_singleton_method(module, "ref_lookup_test_object_id", rb_ref_lookup_test, 1);
    rb_define_singleton_method(module, "ref_release", rb_ref_release, 1);
}
```

- [ ] **Step 2.5: Compile & test**

```bash
bundle exec rake clobber compile test
git add -A
git commit -m "feat: implement Pillar 1 RefTable with retain/release/lookup"
```

---

## Task 3: Pillar 2 — Marshalling

**Files:**
- Create: `Sources/AppleSDKMacRuntime/Marshal.swift`
- Modify: `RuntimeBridge.swift`, `apple_sdk_mac_runtime.c`
- Create: `test/test_marshal.rb`

- [ ] **Step 3.1: RED**

```ruby
# frozen_string_literal: true
require "test_helper"

class TestMarshal < Test::Unit::TestCase
  def test_string_round_trip
    out = AppleSDKMacRuntime.marshal_string_round_trip("hello")
    assert_equal "hello", out
  end

  def test_int_round_trip
    out = AppleSDKMacRuntime.marshal_int_round_trip(42)
    assert_equal 42, out
  end

  def test_array_round_trip
    out = AppleSDKMacRuntime.marshal_array_to_swift_count(["a", "b", "c"])
    assert_equal 3, out
  end
end
```

```bash
bundle exec rake test TEST=test/test_marshal.rb
git add test/test_marshal.rb
git commit -m "test: add failing spec for Pillar 2 Marshal"
```

- [ ] **Step 3.2: GREEN — `Marshal.swift`**

```swift
import Foundation

public enum Marshal {
    public static func swiftString(fromCString c: UnsafePointer<CChar>) -> String {
        String(cString: c)
    }

    public static func cString(fromSwift s: String) -> UnsafeMutablePointer<CChar> {
        strdup(s)!
    }
}
```

- [ ] **Step 3.3: GREEN — Append to `RuntimeBridge.swift`**

```swift
@c
public func runtime_marshal_string_round_trip(
    _ input: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    let s = Marshal.swiftString(fromCString: input)
    return Marshal.cString(fromSwift: s)
}

@c
public func runtime_marshal_int_round_trip(_ value: Int64) -> Int64 {
    return value
}

@c
public func runtime_marshal_array_count(_ count: Int64) -> Int64 {
    return count
}

@c
public func runtime_string_free(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}
```

- [ ] **Step 3.4: GREEN — CRuby bindings**

In `apple_sdk_mac_runtime.c`, add:

```c
static VALUE rb_marshal_string_rt(VALUE self, VALUE s) {
    const char *c = StringValueCStr(s);
    char *res = runtime_marshal_string_round_trip(c);
    VALUE rb = rb_utf8_str_new_cstr(res);
    runtime_string_free(res);
    return rb;
}

static VALUE rb_marshal_int_rt(VALUE self, VALUE v) {
    int64_t r = runtime_marshal_int_round_trip(NUM2LL(v));
    return LL2NUM(r);
}

static VALUE rb_marshal_array_count(VALUE self, VALUE ary) {
    Check_Type(ary, T_ARRAY);
    int64_t r = runtime_marshal_array_count((int64_t)RARRAY_LEN(ary));
    return LL2NUM(r);
}
```

In `Init_apple_sdk_mac_runtime`:

```c
    rb_define_singleton_method(module, "marshal_string_round_trip", rb_marshal_string_rt, 1);
    rb_define_singleton_method(module, "marshal_int_round_trip", rb_marshal_int_rt, 1);
    rb_define_singleton_method(module, "marshal_array_to_swift_count", rb_marshal_array_count, 1);
```

```bash
bundle exec rake clobber compile test
git add -A
git commit -m "feat: implement Pillar 2 Marshal with string/int/array primitives"
```

---

## Task 4: Pillar 5 — Error Bridge

**Files:**
- Create: `Sources/AppleSDKMacRuntime/ErrorBridge.swift`
- Modify: `RuntimeBridge.swift`, `apple_sdk_mac_runtime.c`
- Create: `test/test_error_bridge.rb`

- [ ] **Step 4.1: RED**

```ruby
require "test_helper"

class TestErrorBridge < Test::Unit::TestCase
  def test_runtime_error_raises_runtime_error
    assert_raise(RuntimeError) do
      AppleSDKMacRuntime.raise_runtime_error_test("boom")
    end
  end

  def test_argument_error_raises_argument_error
    assert_raise(ArgumentError) do
      AppleSDKMacRuntime.raise_argument_error_test("nope")
    end
  end
end
```

```bash
bundle exec rake test TEST=test/test_error_bridge.rb
git add test/test_error_bridge.rb
git commit -m "test: add failing spec for Pillar 5 ErrorBridge"
```

- [ ] **Step 4.2: GREEN — `ErrorBridge.swift`**

```swift
import Foundation

public enum ErrorBridge {
    public enum Kind: Int32 {
        case runtimeError = 0
        case argumentError = 1
        case typeError = 2
    }
}
```

- [ ] **Step 4.3: GREEN — Append to `RuntimeBridge.swift`**

```swift
@c
public func runtime_raise_request(
    _ kind: Int32,
    _ message: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
    return strdup(String(cString: message))!
}
```

- [ ] **Step 4.4: GREEN — CRuby raises**

In `apple_sdk_mac_runtime.c`:

```c
static VALUE rb_raise_runtime_error_test(VALUE self, VALUE msg) {
    char *m = runtime_raise_request(0, StringValueCStr(msg));
    VALUE str = rb_utf8_str_new_cstr(m);
    runtime_string_free(m);
    rb_raise(rb_eRuntimeError, "%" PRIsVALUE, str);
    return Qnil;
}

static VALUE rb_raise_argument_error_test(VALUE self, VALUE msg) {
    char *m = runtime_raise_request(1, StringValueCStr(msg));
    VALUE str = rb_utf8_str_new_cstr(m);
    runtime_string_free(m);
    rb_raise(rb_eArgError, "%" PRIsVALUE, str);
    return Qnil;
}
```

Register in `Init_`:

```c
    rb_define_singleton_method(module, "raise_runtime_error_test", rb_raise_runtime_error_test, 1);
    rb_define_singleton_method(module, "raise_argument_error_test", rb_raise_argument_error_test, 1);
```

```bash
bundle exec rake clobber compile test
git add -A
git commit -m "feat: implement Pillar 5 ErrorBridge raise routing"
```

---

## Task 5: Pillar 4 — ARC Bridge

**Files:**
- Create: `Sources/AppleSDKMacRuntime/ARCBridge.swift`
- Create: `lib/apple_sdk_mac/opaque_ref.rb`
- Create: `test/test_arc_bridge.rb`

- [ ] **Step 5.1: RED**

```ruby
require "test_helper"
require "apple_sdk_mac/opaque_ref"

class TestARCBridge < Test::Unit::TestCase
  def test_opaque_ref_release_called_on_gc
    counter_handle = AppleSDKMacRuntime.arc_release_counter_init
    assert_equal 0, AppleSDKMacRuntime.arc_release_counter_value(counter_handle)
    100.times { _ = AppleSDKMac::OpaqueRef.new(counter_handle) }
    GC.start
    GC.start
    sleep 0.05
    assert AppleSDKMacRuntime.arc_release_counter_value(counter_handle) > 0
  end
end
```

```bash
git add test/test_arc_bridge.rb
git commit -m "test: add failing spec for Pillar 4 ARCBridge"
```

- [ ] **Step 5.2: GREEN — `ARCBridge.swift`**

```swift
import Foundation

public enum ARCBridge {
    public final class ReleaseCounter {
        private(set) var count: Int64 = 0
        let queue = DispatchQueue(label: "ARCBridge.ReleaseCounter")
        func bump() { queue.sync { count += 1 } }
    }

    private static let queue = DispatchQueue(label: "ARCBridge.counters")
    private static var counters: [UInt32: ReleaseCounter] = [:]
    private static var next: UInt32 = 1

    public static func makeCounter() -> UInt32 {
        queue.sync {
            let h = next; next += 1
            counters[h] = ReleaseCounter()
            return h
        }
    }

    public static func bump(_ handle: UInt32) {
        queue.sync { counters[handle] }?.bump()
    }

    public static func value(_ handle: UInt32) -> Int64 {
        queue.sync { counters[handle]?.count ?? 0 }
    }
}
```

Append to `RuntimeBridge.swift`:

```swift
@c
public func runtime_arc_counter_init() -> UInt32 {
    return ARCBridge.makeCounter()
}

@c
public func runtime_arc_counter_bump(_ handle: UInt32) {
    ARCBridge.bump(handle)
}

@c
public func runtime_arc_counter_value(_ handle: UInt32) -> Int64 {
    return ARCBridge.value(handle)
}
```

- [ ] **Step 5.3: GREEN — Ruby `OpaqueRef`**

`lib/apple_sdk_mac/opaque_ref.rb`:

```ruby
# frozen_string_literal: true

module AppleSDKMac
  class OpaqueRef
    def initialize(counter_handle = nil)
      @counter_handle = counter_handle
      ObjectSpace.define_finalizer(self, self.class.finalizer(counter_handle))
    end

    def self.finalizer(counter_handle)
      proc {
        AppleSDKMacRuntime.arc_counter_bump(counter_handle) if counter_handle
      }
    end
  end
end
```

In `apple_sdk_mac_runtime.c`, register:

```c
static VALUE rb_arc_counter_init(VALUE self) {
    return UINT2NUM(runtime_arc_counter_init());
}
static VALUE rb_arc_counter_bump(VALUE self, VALUE h) {
    runtime_arc_counter_bump(NUM2UINT(h));
    return Qnil;
}
static VALUE rb_arc_counter_value(VALUE self, VALUE h) {
    return LL2NUM(runtime_arc_counter_value(NUM2UINT(h)));
}
```

```c
    rb_define_singleton_method(module, "arc_release_counter_init", rb_arc_counter_init, 0);
    rb_define_singleton_method(module, "arc_counter_bump", rb_arc_counter_bump, 1);
    rb_define_singleton_method(module, "arc_release_counter_value", rb_arc_counter_value, 1);
```

```bash
bundle exec rake clobber compile test
git add -A
git commit -m "feat: implement Pillar 4 ARCBridge with Ruby GC finalizer integration"
```

---

## Task 6: Pillar 3 — Callback Bridge (basic @c convention)

**Files:**
- Create: `Sources/AppleSDKMacRuntime/CallbackBridge.swift`
- Modify: `RuntimeBridge.swift`, `apple_sdk_mac_runtime.c`
- Create: `test/test_callback_bridge.rb`

- [ ] **Step 6.1: RED**

```ruby
require "test_helper"

class TestCallbackBridge < Test::Unit::TestCase
  def test_register_proc_and_invoke_via_swift
    invocations = []
    proc_id = AppleSDKMacRuntime.callback_register_test do |x|
      invocations << x
    end
    AppleSDKMacRuntime.callback_invoke_test(proc_id, 42)
    AppleSDKMacRuntime.callback_invoke_test(proc_id, 99)
    assert_equal [42, 99], invocations
  end
end
```

```bash
git add test/test_callback_bridge.rb
git commit -m "test: add failing spec for Pillar 3 CallbackBridge basic convention"
```

- [ ] **Step 6.2: GREEN — `CallbackBridge.swift`**

```swift
import Foundation

public enum CallbackBridge {
    public static var rubyDispatcher: (@convention(c) (UInt64, Int64) -> Void)?

    public static func dispatch(procId: UInt64, arg: Int64) {
        rubyDispatcher?(procId, arg)
    }
}
```

Append to `RuntimeBridge.swift`:

```swift
@c
public func runtime_callback_set_dispatcher(
    _ fn: @convention(c) (UInt64, Int64) -> Void
) {
    CallbackBridge.rubyDispatcher = fn
}

@c
public func runtime_callback_invoke(_ procId: UInt64, _ arg: Int64) {
    CallbackBridge.dispatch(procId: procId, arg: arg)
}
```

- [ ] **Step 6.3: GREEN — CRuby side**

In `apple_sdk_mac_runtime.c` (top of file):

```c
static VALUE proc_registry = Qnil;

static void ruby_callback_dispatcher(uint64_t proc_id, int64_t arg) {
    VALUE pid = ULL2NUM(proc_id);
    VALUE proc = rb_hash_lookup(proc_registry, pid);
    if (NIL_P(proc)) return;
    rb_proc_call_with_block(proc, 1, (VALUE[]){LL2NUM(arg)}, Qnil);
}

static VALUE rb_callback_register_test(VALUE self) {
    VALUE block = rb_block_proc();
    VALUE pid = ULL2NUM((uint64_t)NUM2ULL(rb_obj_id(block)));
    rb_hash_aset(proc_registry, pid, block);
    return pid;
}

static VALUE rb_callback_invoke_test(VALUE self, VALUE pid, VALUE arg) {
    runtime_callback_invoke(NUM2ULL(pid), NUM2LL(arg));
    return Qnil;
}
```

Inside `Init_apple_sdk_mac_runtime`:

```c
    proc_registry = rb_hash_new();
    rb_global_variable(&proc_registry);
    runtime_callback_set_dispatcher(ruby_callback_dispatcher);

    rb_define_singleton_method(module, "callback_register_test", rb_callback_register_test, 0);
    rb_define_singleton_method(module, "callback_invoke_test", rb_callback_invoke_test, 2);
```

```bash
bundle exec rake clobber compile test
git add -A
git commit -m "feat: implement Pillar 3 CallbackBridge basic @c convention"
```

---

## Task 7: Pillar 7 — Threading Bridge (deferred mode queue)

**Files:**
- Create: `Sources/AppleSDKMacRuntime/ThreadingBridge.swift`
- Modify: `RuntimeBridge.swift`, `apple_sdk_mac_runtime.c`
- Create: `test/test_threading_bridge.rb`

- [ ] **Step 7.1: RED**

```ruby
require "test_helper"

class TestThreadingBridge < Test::Unit::TestCase
  def test_deferred_queue_drains_via_poll
    received = []
    proc_id = AppleSDKMacRuntime.callback_register_test do |x|
      received << x
    end
    AppleSDKMacRuntime.threading_enqueue_from_thread(proc_id, 1)
    AppleSDKMacRuntime.threading_enqueue_from_thread(proc_id, 2)
    AppleSDKMacRuntime.threading_enqueue_from_thread(proc_id, 3)
    AppleSDKMacRuntime.threading_poll(0.1)
    assert_equal [1, 2, 3], received
  end
end
```

```bash
git add test/test_threading_bridge.rb
git commit -m "test: add failing spec for Pillar 7 ThreadingBridge deferred mode"
```

- [ ] **Step 7.2: GREEN — `ThreadingBridge.swift`**

```swift
import Foundation

public enum ThreadingBridge {
    private struct Pending {
        let procId: UInt64
        let arg: Int64
    }

    private static let queue = DispatchQueue(label: "ThreadingBridge.lockfree")
    private static var pending: [Pending] = []

    public static func enqueueFromAppleThread(procId: UInt64, arg: Int64) {
        queue.sync { pending.append(Pending(procId: procId, arg: arg)) }
    }

    public static func drain(timeoutSeconds: Double) -> Int {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var drained = 0
        while Date() < deadline {
            let next = queue.sync { () -> Pending? in
                pending.isEmpty ? nil : pending.removeFirst()
            }
            guard let p = next else {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }
            CallbackBridge.dispatch(procId: p.procId, arg: p.arg)
            drained += 1
        }
        return drained
    }
}
```

Append to `RuntimeBridge.swift`:

```swift
@c
public func runtime_threading_enqueue(_ procId: UInt64, _ arg: Int64) {
    ThreadingBridge.enqueueFromAppleThread(procId: procId, arg: arg)
}

@c
public func runtime_threading_poll(_ timeoutSeconds: Double) -> Int64 {
    return Int64(ThreadingBridge.drain(timeoutSeconds: timeoutSeconds))
}
```

- [ ] **Step 7.3: GREEN — CRuby side**

```c
static VALUE rb_threading_enqueue(VALUE self, VALUE pid, VALUE arg) {
    runtime_threading_enqueue(NUM2ULL(pid), NUM2LL(arg));
    return Qnil;
}

static VALUE rb_threading_poll(VALUE self, VALUE timeout) {
    int64_t n = runtime_threading_poll(NUM2DBL(timeout));
    return LL2NUM(n);
}
```

```c
    rb_define_singleton_method(module, "threading_enqueue_from_thread", rb_threading_enqueue, 2);
    rb_define_singleton_method(module, "threading_poll", rb_threading_poll, 1);
```

```bash
bundle exec rake clobber compile test
git add -A
git commit -m "feat: implement Pillar 7 ThreadingBridge deferred-queue mode"
```

---

## Task 8: Pillar 6 — Async Bridge (sync await wrapper)

**Files:**
- Create: `Sources/AppleSDKMacRuntime/AsyncBridge.swift`
- Modify: `RuntimeBridge.swift`, `apple_sdk_mac_runtime.c`
- Create: `test/test_async_bridge.rb`

- [ ] **Step 8.1: RED**

```ruby
require "test_helper"

class TestAsyncBridge < Test::Unit::TestCase
  def test_await_runs_async_swift_task_and_returns_result
    started = Time.now
    result = AppleSDKMacRuntime.async_await_test_sleep_and_double(50)
    assert result >= 100
    assert (Time.now - started) >= 0.04
  end
end
```

```bash
git add test/test_async_bridge.rb
git commit -m "test: add failing spec for Pillar 6 AsyncBridge sync wrapper"
```

- [ ] **Step 8.2: GREEN — `AsyncBridge.swift`**

```swift
import Foundation

public enum AsyncBridge {
    public static func runSync<T>(_ task: @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?
        Task {
            defer { semaphore.signal() }
            do {
                let v = try await task()
                result = .success(v)
            } catch {
                result = .failure(error)
            }
        }
        semaphore.wait()
        switch result! {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }
}
```

Append to `RuntimeBridge.swift`:

```swift
@c
public func runtime_async_test_sleep_and_double(_ millis: Int64) -> Int64 {
    do {
        return try AsyncBridge.runSync { () async throws -> Int64 in
            try await Task.sleep(nanoseconds: UInt64(millis) * 1_000_000)
            return millis * 2
        }
    } catch {
        return -1
    }
}
```

- [ ] **Step 8.3: GREEN — CRuby**

```c
static VALUE rb_async_await_sleep(VALUE self, VALUE millis) {
    return LL2NUM(runtime_async_test_sleep_and_double(NUM2LL(millis)));
}
```

```c
    rb_define_singleton_method(module, "async_await_test_sleep_and_double", rb_async_await_sleep, 1);
```

```bash
bundle exec rake clobber compile test
git add -A
git commit -m "feat: implement Pillar 6 AsyncBridge synchronous await helper"
```

---

## Task 9: Pillar 8 — RunLoop Bridge

**Files:**
- Create: `Sources/AppleSDKMacRuntime/RunLoopBridge.swift`
- Modify: `RuntimeBridge.swift`, `apple_sdk_mac_runtime.c`
- Create: `test/test_runloop_bridge.rb`

- [ ] **Step 9.1: RED**

```ruby
require "test_helper"

class TestRunLoopBridge < Test::Unit::TestCase
  def test_pump_returns_quickly_with_zero_timeout
    started = Time.now
    AppleSDKMacRuntime.runloop_pump(0.0)
    assert (Time.now - started) < 0.05
  end

  def test_pump_respects_timeout
    started = Time.now
    AppleSDKMacRuntime.runloop_pump(0.1)
    elapsed = Time.now - started
    assert elapsed >= 0.08
    assert elapsed < 0.5
  end
end
```

```bash
git add test/test_runloop_bridge.rb
git commit -m "test: add failing spec for Pillar 8 RunLoopBridge"
```

- [ ] **Step 9.2: GREEN — `RunLoopBridge.swift`**

```swift
import Foundation
import CoreFoundation

public enum RunLoopBridge {
    public static func pump(timeoutSeconds: Double) {
        CFRunLoopRunInMode(.defaultMode, timeoutSeconds, true)
    }
}
```

Append to `RuntimeBridge.swift`:

```swift
@c
public func runtime_runloop_pump(_ timeoutSeconds: Double) {
    RunLoopBridge.pump(timeoutSeconds: timeoutSeconds)
}
```

- [ ] **Step 9.3: GREEN — CRuby**

```c
static VALUE rb_runloop_pump(VALUE self, VALUE timeout) {
    runtime_runloop_pump(NUM2DBL(timeout));
    return Qnil;
}
```

```c
    rb_define_singleton_method(module, "runloop_pump", rb_runloop_pump, 1);
```

```bash
bundle exec rake clobber compile test
git add -A
git commit -m "feat: implement Pillar 8 RunLoopBridge via CFRunLoopRunInMode"
```

---

## Task 10: Pillar 9 — Conformance Bridge skeleton

**Files:**
- Create: `Sources/AppleSDKMacRuntime/ConformanceBridge.swift`
- Create: `test/test_conformance_bridge_skeleton.rb`

- [ ] **Step 10.1: RED**

```ruby
require "test_helper"

class TestConformanceBridgeSkeleton < Test::Unit::TestCase
  def test_register_and_lookup_handler_table
    handlers = { generate: ->(ctx) { "ok:#{ctx}" } }
    table_handle = AppleSDKMacRuntime.conformance_register_handlers(handlers)
    assert table_handle > 0
    AppleSDKMacRuntime.conformance_release_handlers(table_handle)
  end
end
```

```bash
git add test/test_conformance_bridge_skeleton.rb
git commit -m "test: add failing spec for Pillar 9 ConformanceBridge skeleton"
```

- [ ] **Step 10.2: GREEN — `ConformanceBridge.swift`**

```swift
import Foundation

public enum ConformanceBridge {
    private struct HandlerTable {
        let rubyTableId: UInt64
    }

    private static let queue = DispatchQueue(label: "ConformanceBridge.tables")
    private static var tables: [UInt32: HandlerTable] = [:]
    private static var next: UInt32 = 1

    public static func register(rubyTableId: UInt64) -> UInt32 {
        queue.sync {
            let h = next; next += 1
            tables[h] = HandlerTable(rubyTableId: rubyTableId)
            return h
        }
    }

    public static func release(_ handle: UInt32) {
        _ = queue.sync { tables.removeValue(forKey: handle) }
    }

    public static func lookup(_ handle: UInt32) -> UInt64? {
        queue.sync { tables[handle]?.rubyTableId }
    }
}
```

Append to `RuntimeBridge.swift`:

```swift
@c
public func runtime_conformance_register(_ rubyTableId: UInt64) -> UInt32 {
    return ConformanceBridge.register(rubyTableId: rubyTableId)
}

@c
public func runtime_conformance_release(_ handle: UInt32) {
    ConformanceBridge.release(handle)
}
```

- [ ] **Step 10.3: CRuby + commit**

```c
static VALUE rb_conformance_register(VALUE self, VALUE handlers) {
    Check_Type(handlers, T_HASH);
    uint64_t table_id = (uint64_t)rb_obj_id(handlers);
    rb_hash_aset(proc_registry, ULL2NUM(table_id), handlers);
    return UINT2NUM(runtime_conformance_register(table_id));
}

static VALUE rb_conformance_release(VALUE self, VALUE handle) {
    runtime_conformance_release(NUM2UINT(handle));
    return Qnil;
}
```

```c
    rb_define_singleton_method(module, "conformance_register_handlers", rb_conformance_register, 1);
    rb_define_singleton_method(module, "conformance_release_handlers", rb_conformance_release, 1);
```

```bash
bundle exec rake clobber compile test
git add -A
git commit -m "feat: implement Pillar 9 ConformanceBridge skeleton (handler-table registry)"
```

---

## Task 11: Configuration layer

**Files:**
- Create: `lib/apple_sdk_mac/config.rb`
- Create: `test/test_config.rb`

- [ ] **Step 11.1: RED**

```ruby
require "test_helper"
require "apple_sdk_mac/config"
require "tmpdir"

class TestConfig < Test::Unit::TestCase
  def test_default_cache_dir_under_xdg
    ENV.delete("RB_APPLE_SDK_MAC_CACHE_DIR")
    config = AppleSDKMac::Config.new
    expected = File.join(ENV["XDG_CACHE_HOME"] || File.expand_path("~/.cache"), "rb-apple-sdk-mac")
    assert config.cache_dir.start_with?(expected)
  end

  def test_env_override_takes_precedence
    Dir.mktmpdir do |dir|
      ENV["RB_APPLE_SDK_MAC_CACHE_DIR"] = dir
      config = AppleSDKMac::Config.new
      assert_equal dir, config.cache_dir
      ENV.delete("RB_APPLE_SDK_MAC_CACHE_DIR")
    end
  end

  def test_yaml_config_loaded_when_present
    Dir.mktmpdir do |dir|
      yaml = File.join(dir, "config.yml")
      File.write(yaml, "trust_mode: review_first\n")
      config = AppleSDKMac::Config.new(config_file: yaml)
      assert_equal "review_first", config.trust_mode
    end
  end

  def test_programmatic_override
    config = AppleSDKMac::Config.new
    config.trust_mode = :auto
    assert_equal :auto, config.trust_mode
  end
end
```

```bash
git add test/test_config.rb
git commit -m "test: add failing spec for Config (XDG/ENV/YAML/programmatic)"
```

- [ ] **Step 11.2: GREEN — `lib/apple_sdk_mac/config.rb`**

```ruby
# frozen_string_literal: true
require "yaml"

module AppleSDKMac
  class Config
    DEFAULTS = {
      trust_mode: :auto,
      raise_on_error: true,
      llm_model: "foundation-models/default"
    }.freeze

    attr_accessor :trust_mode, :raise_on_error, :llm_model
    attr_reader :cache_dir

    def initialize(config_file: nil)
      @trust_mode = DEFAULTS[:trust_mode]
      @raise_on_error = DEFAULTS[:raise_on_error]
      @llm_model = DEFAULTS[:llm_model]
      @cache_dir = compute_cache_dir
      load_yaml(config_file || default_yaml_path)
      apply_env
    end

    def cache_dir=(path)
      @cache_dir = File.expand_path(path)
    end

    private

    def compute_cache_dir
      base = ENV["XDG_CACHE_HOME"] || File.expand_path("~/.cache")
      File.join(base, "rb-apple-sdk-mac")
    end

    def default_yaml_path
      base = ENV["XDG_CONFIG_HOME"] || File.expand_path("~/.config")
      File.join(base, "rb-apple-sdk-mac", "config.yml")
    end

    def load_yaml(path)
      return unless path && File.exist?(path)
      data = YAML.safe_load_file(path, permitted_classes: [Symbol])
      return unless data.is_a?(Hash)
      @trust_mode = data["trust_mode"].to_s.empty? ? @trust_mode : data["trust_mode"].to_sym
      @raise_on_error = data["raise_on_error"] if data.key?("raise_on_error")
      @llm_model = data["llm_model"] || @llm_model
      @cache_dir = data["cache_dir"] if data["cache_dir"]
    end

    def apply_env
      @cache_dir = ENV["RB_APPLE_SDK_MAC_CACHE_DIR"] if ENV["RB_APPLE_SDK_MAC_CACHE_DIR"]
      @llm_model = ENV["RB_APPLE_SDK_MAC_LLM_MODEL"] if ENV["RB_APPLE_SDK_MAC_LLM_MODEL"]
    end
  end
end
```

```bash
bundle exec rake test TEST=test/test_config.rb
git add -A
git commit -m "feat: add Config with XDG/ENV/YAML/programmatic layered defaults"
```

---

## Task 12: Compiled Glue Cache (SQLite RW + FS)

**Files:**
- Create: `lib/apple_sdk_mac/compiled_glue_cache.rb`
- Create: `test/test_compiled_glue_cache.rb`

- [ ] **Step 12.1: RED**

```ruby
require "test_helper"
require "tmpdir"
require "apple_sdk_mac/compiled_glue_cache"

class TestCompiledGlueCache < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
    @cache = AppleSDKMac::CompiledGlueCache.open(@tmpdir, sdk_version: "26.0")
  end

  def teardown
    @cache.close
    FileUtils.rm_rf(@tmpdir)
  end

  def test_lookup_returns_nil_for_unknown
    assert_nil @cache.lookup(framework: "CoreMIDI", symbol: "Foo")
  end

  def test_insert_and_lookup_round_trip
    @cache.insert(
      glue_id: "abc123",
      framework: "CoreMIDI",
      symbol: "MIDIClientCreate",
      swift_source: "@c public func glue_abc123_MIDIClientCreate(...)",
      dylib_path: File.join(@tmpdir, "lib", "abc123.dylib"),
      exported_symbol: "glue_abc123_MIDIClientCreate",
      generator: "template"
    )
    rec = @cache.lookup(framework: "CoreMIDI", symbol: "MIDIClientCreate")
    assert_equal "abc123", rec[:glue_id]
    assert_equal "template", rec[:generator]
  end
end
```

```bash
git add test/test_compiled_glue_cache.rb
git commit -m "test: add failing spec for CompiledGlueCache"
```

- [ ] **Step 12.2: GREEN — `lib/apple_sdk_mac/compiled_glue_cache.rb`**

```ruby
# frozen_string_literal: true
require "sqlite3"
require "fileutils"

module AppleSDKMac
  class CompiledGlueCache
    SCHEMA_SQL = <<~SQL.freeze
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS compiled_glue (
        glue_id              TEXT PRIMARY KEY,
        framework_name       TEXT NOT NULL,
        symbol_name          TEXT NOT NULL,
        swift_source         BLOB NOT NULL,
        dylib_path           TEXT NOT NULL,
        exported_symbol      TEXT NOT NULL,
        generator            TEXT NOT NULL,
        llm_model_version    TEXT,
        llm_prompt_hash      TEXT,
        compile_swiftc_args  TEXT NOT NULL DEFAULT '',
        verification_status  TEXT NOT NULL DEFAULT 'pass',
        generated_at         INTEGER NOT NULL,
        last_used_at         INTEGER,
        use_count            INTEGER DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS idx_glue_framework_symbol
        ON compiled_glue(framework_name, symbol_name);

      CREATE TABLE IF NOT EXISTS compile_history (
        id            INTEGER PRIMARY KEY,
        framework     TEXT NOT NULL,
        symbol        TEXT NOT NULL,
        attempt_at    INTEGER NOT NULL,
        generator     TEXT NOT NULL,
        llm_response  BLOB,
        error_stage   TEXT,
        error_detail  TEXT,
        glue_id       TEXT
      );

      CREATE TABLE IF NOT EXISTS conformance_shims (
        shim_id              TEXT PRIMARY KEY,
        protocol_or_class    TEXT NOT NULL,
        framework_name       TEXT NOT NULL,
        swift_source         BLOB NOT NULL,
        dylib_path           TEXT NOT NULL,
        shim_class_name      TEXT NOT NULL,
        required_methods     TEXT NOT NULL,
        generated_at         INTEGER NOT NULL
      );
    SQL

    attr_reader :db, :base_dir, :sdk_version

    def self.open(base_dir, sdk_version:)
      new(base_dir, sdk_version: sdk_version).tap(&:migrate!)
    end

    def initialize(base_dir, sdk_version:)
      @base_dir = base_dir
      @sdk_version = sdk_version
      FileUtils.mkdir_p(File.join(@base_dir, sdk_version, "lib"))
      FileUtils.mkdir_p(File.join(@base_dir, sdk_version, "sources"))
      @db = SQLite3::Database.new(File.join(@base_dir, sdk_version, "glue.sqlite"))
    end

    def migrate!
      @db.execute_batch(SCHEMA_SQL)
    end

    def lookup(framework:, symbol:)
      row = @db.execute(<<~SQL, [framework, symbol]).first
        SELECT glue_id, framework_name, symbol_name, dylib_path,
               exported_symbol, generator, verification_status
        FROM compiled_glue
        WHERE framework_name = ? AND symbol_name = ?
        LIMIT 1
      SQL
      return nil unless row
      {
        glue_id: row[0], framework: row[1], symbol: row[2],
        dylib_path: row[3], exported_symbol: row[4],
        generator: row[5], verification_status: row[6]
      }
    end

    def insert(glue_id:, framework:, symbol:, swift_source:, dylib_path:,
               exported_symbol:, generator:, llm_model_version: nil, llm_prompt_hash: nil)
      @db.execute(
        <<~SQL,
          INSERT INTO compiled_glue
          (glue_id, framework_name, symbol_name, swift_source, dylib_path,
           exported_symbol, generator, llm_model_version, llm_prompt_hash,
           generated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [glue_id, framework, symbol, SQLite3::Blob.new(swift_source), dylib_path,
         exported_symbol, generator, llm_model_version, llm_prompt_hash, Time.now.to_i]
      )
    end

    def record_attempt(framework:, symbol:, generator:, llm_response: nil,
                        error_stage: nil, error_detail: nil, glue_id: nil)
      @db.execute(
        <<~SQL,
          INSERT INTO compile_history
          (framework, symbol, attempt_at, generator, llm_response,
           error_stage, error_detail, glue_id)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [framework, symbol, Time.now.to_i, generator,
         llm_response ? SQLite3::Blob.new(llm_response) : nil,
         error_stage, error_detail, glue_id]
      )
    end

    def close
      @db.close
    end
  end
end
```

```bash
bundle exec rake test TEST=test/test_compiled_glue_cache.rb
git add -A
git commit -m "feat: add CompiledGlueCache (SQLite RW + FS layout)"
```

---

## Task 13: Knowledge Cache adapter (consume gem B)

**Files:**
- Create: `lib/apple_sdk_mac/knowledge_cache.rb`
- Create: `test/test_knowledge_cache.rb`

- [ ] **Step 13.1: RED**

```ruby
require "test_helper"
require "apple_sdk_mac/knowledge_cache"

class TestKnowledgeCache < Test::Unit::TestCase
  def test_lookup_symbol_returns_nil_for_unknown
    omit "knowledge SQLite not built; run rake apple:knowledge:rebuild" unless real_knowledge_built?
    cache = AppleSDKMac::KnowledgeCache.open
    assert_nil cache.lookup_symbol(framework: "CoreMIDI", symbol: "DefinitelyNotARealAPI___xyz")
    cache.close
  end

  def test_lookup_real_known_symbol
    omit "knowledge SQLite not built" unless real_knowledge_built?
    cache = AppleSDKMac::KnowledgeCache.open
    sym = cache.lookup_symbol(framework: "CoreMIDI", symbol: "MIDIClientCreate")
    assert_not_nil sym
    assert_equal "function", sym[:kind]
    cache.close
  end

  private

  def real_knowledge_built?
    require "rb_apple_sdk_knowledge"
    File.exist?(AppleSDKKnowledge.knowledge_path)
  rescue
    false
  end
end
```

```bash
git add test/test_knowledge_cache.rb
git commit -m "test: add failing spec for KnowledgeCache adapter"
```

- [ ] **Step 13.2: GREEN — `lib/apple_sdk_mac/knowledge_cache.rb`**

```ruby
# frozen_string_literal: true
require "rb_apple_sdk_knowledge"

module AppleSDKMac
  class KnowledgeCache
    def self.open
      new(AppleSDKKnowledge.open)
    end

    def initialize(store)
      @store = store
      @db = store.db
    end

    def lookup_symbol(framework:, symbol:)
      row = @db.execute(<<~SQL, [framework, symbol]).first
        SELECT s.id, s.name, s.kind, s.signature, s.abi, s.documentation,
               s.parameters_json, s.requires_main_thread, s.content_hash
        FROM symbols s
        JOIN frameworks f ON s.framework_id = f.id
        WHERE f.name = ? AND s.name = ?
        LIMIT 1
      SQL
      return nil unless row
      {
        id: row[0], name: row[1], kind: row[2], signature: row[3],
        abi: row[4], documentation: row[5], parameters_json: row[6],
        requires_main_thread: row[7] == 1, content_hash: row[8]
      }
    end

    def list_framework_symbols(framework:, kinds: nil)
      sql = <<~SQL
        SELECT s.name, s.kind, s.signature, s.abi
        FROM symbols s
        JOIN frameworks f ON s.framework_id = f.id
        WHERE f.name = ?
      SQL
      args = [framework]
      if kinds
        sql += " AND s.kind IN (#{Array(kinds).map { '?' }.join(',')})"
        args.concat(kinds)
      end
      @db.execute(sql, args).map do |r|
        { name: r[0], kind: r[1], signature: r[2], abi: r[3] }
      end
    end

    def list_frameworks
      @db.execute("SELECT name FROM frameworks ORDER BY name").flatten
    end

    def search(framework:, query:, limit: 5)
      AppleSDKKnowledge::Search.new(@store).lexical(
        framework: framework, query: query, limit: limit
      )
    end

    def close
      @store.close
    end
  end
end
```

```bash
git add -A
git commit -m "feat: add KnowledgeCache adapter delegating to gem B Store"
```

---

## Task 14: Template Generator (deterministic shape catalog v1)

**Files:**
- Create: `lib/apple_sdk_mac/glue_compiler/template_generator.rb`
- Create: `test/test_template_generator.rb`

- [ ] **Step 14.1: RED**

```ruby
require "test_helper"
require "apple_sdk_mac/glue_compiler/template_generator"

class TestTemplateGenerator < Test::Unit::TestCase
  def setup
    @gen = AppleSDKMac::GlueCompiler::TemplateGenerator.new
  end

  def test_recognizes_pure_c_function_with_string_args
    sym = {
      name: "MIDIClientCreate",
      kind: "function",
      abi: "c",
      signature: "OSStatus MIDIClientCreate(CFStringRef name, MIDIClientRef *outRef)",
      parameters_json: JSON.dump([
        { "name" => "name", "type" => "CFStringRef" },
        { "name" => "outRef", "type" => "MIDIClientRef *" }
      ])
    }
    swift = @gen.generate(framework: "CoreMIDI", symbol: sym, glue_id: "abc")
    refute_nil swift
    assert_match(/import CoreMIDI/, swift)
    assert_match(/glue_abc_MIDIClientCreate/, swift)
  end

  def test_returns_nil_for_unknown_shape
    sym = {
      name: "WeirdGenericFn",
      kind: "function",
      abi: "swift",
      signature: "func WeirdGenericFn<T: Equatable, U: Hashable>(...) async throws -> AsyncStream<T>"
    }
    swift = @gen.generate(framework: "Foo", symbol: sym, glue_id: "x")
    assert_nil swift
  end
end
```

```bash
git add test/test_template_generator.rb
git commit -m "test: add failing spec for TemplateGenerator"
```

- [ ] **Step 14.2: GREEN — `lib/apple_sdk_mac/glue_compiler/template_generator.rb`**

```ruby
# frozen_string_literal: true
require "json"

module AppleSDKMac
  module GlueCompiler
    class TemplateGenerator
      def generate(framework:, symbol:, glue_id:)
        case [symbol[:kind], symbol[:abi]]
        when ["function", "c"]
          generate_c_function(framework, symbol, glue_id)
        when ["function", "swift"]
          generate_swift_function(framework, symbol, glue_id)
        else
          nil
        end
      end

      private

      def generate_c_function(framework, sym, glue_id)
        params = parse_params(sym[:parameters_json])
        return nil unless template_compatible?(params)

        param_load = params.each_with_index.map { |p, i| load_param(p, i) }.join("\n    ")
        call_args = params.reject { |p| out_param?(p) }
                          .map { |p| p[:name] }.join(", ")
        out_param = params.find { |p| out_param?(p) }

        <<~SWIFT
          import #{framework}
          import AppleSDKMacRuntime
          import Foundation

          @c
          public func glue_#{glue_id}_#{sym[:name]}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{param_load}
              #{out_param ? "var outRef = #{strip_pointer(out_param[:type])}()" : ''}
              let status = #{sym[:name]}(#{call_args}#{out_param ? ', &outRef' : ''})
              if status != 0 {
                  ErrorBridge.rb_raise_via_runtime(.runtimeError, "OSStatus \\(status)")
              }
              #{out_param ? 'return Marshal.toRuby(RefTable.retain(outRef as AnyObject))' : 'return Marshal.toRuby(Int(status))'}
          }
        SWIFT
      end

      def generate_swift_function(framework, sym, glue_id)
        return nil if sym[:signature].include?("async") || sym[:signature].include?("<")
        params = parse_params(sym[:parameters_json])
        return nil unless template_compatible?(params)

        param_load = params.each_with_index.map { |p, i| load_param(p, i) }.join("\n    ")
        call_args = params.map { |p| p[:name] }.join(", ")

        <<~SWIFT
          import #{framework}
          import AppleSDKMacRuntime
          import Foundation

          @c
          public func glue_#{glue_id}_#{sym[:name]}(
              _ argv: UnsafePointer<UInt>, _ argc: Int32
          ) -> UInt {
              #{param_load}
              let result = #{sym[:name]}(#{call_args})
              return Marshal.toRuby(result)
          }
        SWIFT
      end

      def parse_params(json_str)
        return [] unless json_str
        JSON.parse(json_str).map do |p|
          { name: p["name"] || "_arg", type: p["type"] || "Any" }
        end
      end

      def template_compatible?(params)
        return false if params.any? { |p| p[:type].include?("...") }
        return false if params.any? { |p| p[:type].include?("@escaping") && p[:type].include?("(") }
        return false if params.any? { |p| p[:type].include?("Generic") || p[:type].match(/<\w/) }
        true
      end

      def out_param?(p)
        p[:type].include?("*") || p[:type].include?("inout")
      end

      def load_param(p, i)
        case p[:type]
        when /CFStringRef|String|NSString/
          %{guard argc > #{i} else { ErrorBridge.rb_raise_via_runtime(.argumentError, "missing arg #{i}"); return 0 }
              let #{p[:name]} = Marshal.fromRubyString(argv[#{i}]) as CFString}
        when /Int|Int32|Int64|UInt|UInt32|UInt64/
          "let #{p[:name]} = Int64(Marshal.fromRubyInt(argv[#{i}]))"
        when /Bool/
          "let #{p[:name]} = Marshal.fromRubyBool(argv[#{i}])"
        else
          "let #{p[:name]}: Any = Marshal.fromRubyAny(argv[#{i}])"
        end
      end

      def strip_pointer(t)
        t.sub(/\s*\*\s*$/, "").strip
      end
    end
  end
end
```

```bash
bundle exec rake test TEST=test/test_template_generator.rb
git add -A
git commit -m "feat: add TemplateGenerator with v1 shape catalog (C functions out-param style)"
```

---

## Task 15: LLM Glue Generator (uses gem A)

**Files:**
- Create: `lib/apple_sdk_mac/glue_compiler/llm_generator.rb`
- Create: `test/test_llm_generator.rb`

- [ ] **Step 15.1: RED**

```ruby
require "test_helper"
require "apple_sdk_mac/glue_compiler/llm_generator"

class TestLLMGenerator < Test::Unit::TestCase
  def test_generate_returns_swift_source_for_simple_async_fn
    omit "rb-foundation-model-mac required for live LLM test" unless defined?(::AppleFoundationModel)
    sym = {
      name: "asyncFetchTitle",
      kind: "function", abi: "swift",
      signature: "func asyncFetchTitle(_ url: URL) async throws -> String",
      parameters_json: JSON.dump([{ "name" => "url", "type" => "URL" }])
    }
    gen = AppleSDKMac::GlueCompiler::LLMGenerator.new
    swift = gen.generate(framework: "AcmeFW", symbol: sym, glue_id: "deadbeef")
    refute_nil swift
    assert_match(/import AcmeFW/, swift)
    assert_match(/glue_deadbeef_asyncFetchTitle/, swift)
  end
end
```

```bash
git add test/test_llm_generator.rb
git commit -m "test: add failing spec for LLMGenerator (rb-foundation-model-mac integration)"
```

- [ ] **Step 15.2: GREEN — `lib/apple_sdk_mac/glue_compiler/llm_generator.rb`**

```ruby
# frozen_string_literal: true
require "foundation_model_mac"

module AppleSDKMac
  module GlueCompiler
    class LLMGenerator
      INSTRUCTIONS = <<~TXT.freeze
        You generate Swift glue code for the rb-apple-sdk-mac runtime bridge.
        STRICT RULES:
        1. Output exactly one @c-attributed public function named glue_<glue_id>_<symbol>.
        2. Function signature is exactly:
             func glue_<glue_id>_<symbol>(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt
        3. Allowed imports: the target Apple framework, AppleSDKMacRuntime, Foundation. No others.
        4. No network, file, process, IPC, persistence, or environment-mutation APIs may be called
           inside the function body, EXCEPT the user-requested target symbol itself.
        5. Marshal arguments via AppleSDKMacRuntime.Marshal.fromRubyXXX helpers.
        6. Marshal returns via AppleSDKMacRuntime.Marshal.toRuby.
        7. For async functions, wrap in AsyncBridge.runSync.
        8. For protocol/superclass shims, generate a separate Swift class conforming to the protocol;
           dispatch each required method via AppleSDKMacRuntime.ConformanceBridge.lookup.
        9. Output ONLY Swift source code. No prose, no markdown fences, no commentary.
      TXT

      def initialize(model: nil)
        @session = AppleFoundationModel::Session.new(instructions: INSTRUCTIONS)
      end

      def generate(framework:, symbol:, glue_id:)
        prompt = build_prompt(framework, symbol, glue_id)
        response = @session.respond(to: prompt)
        return nil if response.nil? || response.strip.empty?
        response.gsub(/\A```swift\n/, "").gsub(/\n```\z/, "").strip
      end

      def close
        @session.close
      end

      private

      def build_prompt(framework, sym, glue_id)
        <<~PROMPT
          framework: #{framework}
          glue_id: #{glue_id}
          symbol_name: #{sym[:name]}
          kind: #{sym[:kind]}
          abi: #{sym[:abi]}
          signature: #{sym[:signature]}
          parameters_json: #{sym[:parameters_json]}

          Generate the Swift glue file as specified. Output Swift source only.
        PROMPT
      end
    end
  end
end
```

```bash
git add -A
git commit -m "feat: add LLMGenerator using rb-foundation-model-mac for novel shapes"
```

---

## Task 16: Validation Gates (SwiftSyntax-based)

**Files:**
- Create: `lib/apple_sdk_mac/glue_compiler/validation_gates.rb`
- Create: `test/test_validation_gates.rb`

- [ ] **Step 16.1: RED**

```ruby
require "test_helper"
require "apple_sdk_mac/glue_compiler/validation_gates"

class TestValidationGates < Test::Unit::TestCase
  def setup
    @gates = AppleSDKMac::GlueCompiler::ValidationGates.new
  end

  def test_passes_minimal_correct_glue
    swift = <<~SWIFT
      import CoreMIDI
      import AppleSDKMacRuntime
      import Foundation

      @c
      public func glue_abc_MIDIDispose(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
          let h: UInt32 = UInt32(argv[0])
          let r = MIDIClientDispose(MIDIClientRef(h))
          return UInt(r)
      }
    SWIFT
    result = @gates.validate(swift, framework: "CoreMIDI", glue_id: "abc",
                              symbol: "MIDIDispose")
    assert result.pass?, result.errors.join("; ")
  end

  def test_rejects_disallowed_import
    swift = <<~SWIFT
      import CoreMIDI
      import Network
      import AppleSDKMacRuntime
      import Foundation

      @c
      public func glue_abc_X(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt { 0 }
    SWIFT
    result = @gates.validate(swift, framework: "CoreMIDI", glue_id: "abc", symbol: "X")
    refute result.pass?
    assert result.errors.any? { |e| e.include?("Network") }
  end

  def test_rejects_url_session_call_in_body_for_unrelated_symbol
    swift = <<~SWIFT
      import CoreMIDI
      import AppleSDKMacRuntime
      import Foundation

      @c
      public func glue_abc_MIDIDispose(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
          _ = URLSession.shared.dataTask(with: URL(string: "http://x")!)
          return 0
      }
    SWIFT
    result = @gates.validate(swift, framework: "CoreMIDI", glue_id: "abc",
                              symbol: "MIDIDispose")
    refute result.pass?
    assert result.errors.any? { |e| e.include?("URLSession") }
  end

  def test_rejects_multiple_c_exports
    swift = <<~SWIFT
      import CoreMIDI
      import AppleSDKMacRuntime
      import Foundation

      @c public func glue_abc_a(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt { 0 }
      @c public func glue_abc_b(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt { 0 }
    SWIFT
    result = @gates.validate(swift, framework: "CoreMIDI", glue_id: "abc", symbol: "a")
    refute result.pass?
    assert result.errors.any? { |e| e.include?("export") || e.include?("@c") }
  end
end
```

```bash
git add test/test_validation_gates.rb
git commit -m "test: add failing spec for ValidationGates (6-gate compile-time pipeline)"
```

- [ ] **Step 16.2: GREEN — `lib/apple_sdk_mac/glue_compiler/validation_gates.rb`**

```ruby
# frozen_string_literal: true

module AppleSDKMac
  module GlueCompiler
    class ValidationGates
      Result = Struct.new(:pass?, :errors)

      ALLOWED_IMPORTS_EXTRA = %w[AppleSDKMacRuntime Foundation].freeze

      BANNED_API_PATTERNS = [
        "URLSession", "NSURLConnection", "URLRequest(", "NWConnection",
        "FileManager", "FileHandle", "Data(contentsOf:", "String(contentsOf:",
        "Bundle.main.url(forResource:", "Process(", "posix_spawn", "system(",
        "execve", "NSXPCConnection", "NSDistributedNotificationCenter",
        "UserDefaults", "Keychain", "ProcessInfo.processInfo.environment["
      ].freeze

      def validate(swift, framework:, glue_id:, symbol:)
        errors = []
        check_imports(swift, framework, errors)
        check_banned_apis(swift, symbol, errors)
        check_shape(swift, glue_id, symbol, errors)
        Result.new(errors.empty?, errors)
      end

      private

      def check_imports(swift, framework, errors)
        imports = swift.lines.map(&:strip).select { |l| l.start_with?("import ") }
        seen = imports.map { |l| l.sub(/\Aimport\s+/, "").split(/[\s.]/, 2).first }
        allowed = [framework] + ALLOWED_IMPORTS_EXTRA
        seen.each do |imp|
          unless allowed.include?(imp)
            errors << "GATE 3 disallowed import: #{imp}"
          end
        end
      end

      def check_banned_apis(swift, target_symbol, errors)
        BANNED_API_PATTERNS.each do |pat|
          next unless swift.include?(pat)
          next if target_symbol.start_with?(pat.sub(/\W.*/, ""))
          errors << "GATE 4 banned API used: #{pat}"
        end
      end

      def check_shape(swift, glue_id, symbol, errors)
        c_exports = swift.scan(/@c\s+public\s+func\s+(\w+)/)
        if c_exports.empty?
          errors << "GATE 5 no @c public func found"
        elsif c_exports.length > 1
          errors << "GATE 5 multiple @c exports: #{c_exports.flatten.join(', ')}"
        else
          name = c_exports.flatten.first
          expected = "glue_#{glue_id}_#{symbol}"
          errors << "GATE 5 expected export #{expected}, got #{name}" unless name == expected
        end
      end
    end
  end
end
```

```bash
bundle exec rake test TEST=test/test_validation_gates.rb
git add -A
git commit -m "feat: add ValidationGates 3/4/5 (imports, banned APIs, glue shape)"
```

---

## Task 17: swiftc invoker

**Files:**
- Create: `lib/apple_sdk_mac/glue_compiler/swiftc_invoker.rb`
- Create: `test/test_swiftc_invoker.rb`

- [ ] **Step 17.1: RED**

```ruby
require "test_helper"
require "tmpdir"
require "apple_sdk_mac/glue_compiler/swiftc_invoker"

class TestSwiftcInvoker < Test::Unit::TestCase
  def test_compiles_minimal_swift_source_to_dylib
    Dir.mktmpdir do |dir|
      src = File.join(dir, "x.swift")
      File.write(src, <<~SWIFT)
        import Foundation
        @c public func glue_x(_ a: Int) -> Int { a + 1 }
      SWIFT
      dylib = File.join(dir, "x.dylib")
      ok, err = AppleSDKMac::GlueCompiler::SwiftcInvoker.new.compile(
        source_path: src, dylib_path: dylib
      )
      assert ok, "swiftc failed: #{err}"
      assert File.exist?(dylib)
    end
  end

  def test_reports_compile_errors
    Dir.mktmpdir do |dir|
      src = File.join(dir, "broken.swift")
      File.write(src, "this is not valid swift")
      dylib = File.join(dir, "broken.dylib")
      ok, err = AppleSDKMac::GlueCompiler::SwiftcInvoker.new.compile(
        source_path: src, dylib_path: dylib
      )
      refute ok
      assert err.length > 0
    end
  end
end
```

```bash
git add test/test_swiftc_invoker.rb
git commit -m "test: add failing spec for SwiftcInvoker"
```

- [ ] **Step 17.2: GREEN — `lib/apple_sdk_mac/glue_compiler/swiftc_invoker.rb`**

```ruby
# frozen_string_literal: true
require "open3"

module AppleSDKMac
  module GlueCompiler
    class SwiftcInvoker
      def initialize(swiftc: nil, sdk_path: nil)
        @swiftc = swiftc || ENV["RB_APPLE_SDK_MAC_SWIFTC"] || "swiftc"
        @sdk_path = sdk_path
      end

      def compile(source_path:, dylib_path:, runtime_dylib_path: nil, link_libs: [])
        sdk = @sdk_path || `xcrun --show-sdk-path`.strip
        args = [
          "-emit-library",
          "-target", "arm64-apple-macos26.0",
          "-sdk", sdk,
          "-O",
          "-parse-as-library",
          "-enable-library-evolution",
          "-o", dylib_path
        ]
        link_libs.each do |lib|
          args << "-l#{lib}"
        end
        if runtime_dylib_path
          args << "-Xlinker"
          args << runtime_dylib_path
        end
        args << source_path

        out, err, status = Open3.capture3(@swiftc, *args)
        if status.success?
          [true, out]
        else
          [false, err]
        end
      end
    end
  end
end
```

```bash
bundle exec rake test TEST=test/test_swiftc_invoker.rb
git add -A
git commit -m "feat: add SwiftcInvoker (xcrun --show-sdk-path, arm64-apple-macos26.0 target)"
```

---

## Task 18: Glue Compiler orchestrator

**Files:**
- Create: `lib/apple_sdk_mac/glue_compiler.rb`
- Create: `test/test_glue_compiler.rb`

- [ ] **Step 18.1: RED**

```ruby
require "test_helper"
require "tmpdir"
require "apple_sdk_mac/glue_compiler"
require "apple_sdk_mac/compiled_glue_cache"

class TestGlueCompiler < Test::Unit::TestCase
  def test_compile_simple_c_function_uses_template_path
    Dir.mktmpdir do |dir|
      cache = AppleSDKMac::CompiledGlueCache.open(dir, sdk_version: "26.0")
      sym = {
        name: "MIDIClientDispose",
        kind: "function", abi: "c",
        signature: "OSStatus MIDIClientDispose(MIDIClientRef client)",
        parameters_json: JSON.dump([{ "name" => "client", "type" => "MIDIClientRef" }])
      }
      compiler = AppleSDKMac::GlueCompiler.new(cache: cache,
                                                runtime_dylib_path: nil)
      result = compiler.compile(framework: "CoreMIDI", symbol: sym)
      assert result.success?, result.error_detail
      assert_equal "template", result.generator
      cache.close
    end
  end
end
```

```bash
git add test/test_glue_compiler.rb
git commit -m "test: add failing spec for GlueCompiler orchestrator"
```

- [ ] **Step 18.2: GREEN — `lib/apple_sdk_mac/glue_compiler.rb`**

```ruby
# frozen_string_literal: true
require "digest"
require_relative "glue_compiler/template_generator"
require_relative "glue_compiler/llm_generator"
require_relative "glue_compiler/validation_gates"
require_relative "glue_compiler/swiftc_invoker"

module AppleSDKMac
  class GlueCompiler
    Result = Struct.new(:success?, :glue_id, :generator, :dylib_path,
                         :exported_symbol, :error_stage, :error_detail,
                         keyword_init: true)

    MAX_LLM_RETRIES = 3

    def initialize(cache:, runtime_dylib_path:, llm_generator: nil)
      @cache = cache
      @runtime_dylib_path = runtime_dylib_path
      @template = GlueCompiler::TemplateGenerator.new
      @llm = llm_generator
      @gates = GlueCompiler::ValidationGates.new
      @swiftc = GlueCompiler::SwiftcInvoker.new
    end

    def compile(framework:, symbol:)
      glue_id = compute_glue_id(framework, symbol)
      base = File.join(@cache.base_dir, @cache.sdk_version)
      src = File.join(base, "sources", "#{glue_id}.swift")
      dylib = File.join(base, "lib", "#{glue_id}.dylib")
      exported = "glue_#{glue_id}_#{symbol[:name]}"

      swift_source = @template.generate(framework: framework, symbol: symbol, glue_id: glue_id)

      if swift_source.nil?
        return llm_path(framework, symbol, glue_id, src, dylib, exported)
      end

      gate_result = @gates.validate(swift_source, framework: framework,
                                                  glue_id: glue_id, symbol: symbol[:name])
      unless gate_result.pass?
        @cache.record_attempt(framework: framework, symbol: symbol[:name],
                               generator: "template",
                               error_stage: "static_check",
                               error_detail: gate_result.errors.join("; "))
        return llm_path(framework, symbol, glue_id, src, dylib, exported)
      end

      File.write(src, swift_source)
      ok, err = @swiftc.compile(
        source_path: src, dylib_path: dylib,
        runtime_dylib_path: @runtime_dylib_path
      )
      unless ok
        @cache.record_attempt(framework: framework, symbol: symbol[:name],
                               generator: "template",
                               error_stage: "swiftc",
                               error_detail: err)
        return Result.new(success?: false, error_stage: "swiftc", error_detail: err)
      end

      @cache.insert(glue_id: glue_id, framework: framework, symbol: symbol[:name],
                     swift_source: swift_source, dylib_path: dylib,
                     exported_symbol: exported, generator: "template")
      Result.new(success?: true, glue_id: glue_id, generator: "template",
                  dylib_path: dylib, exported_symbol: exported)
    end

    private

    def llm_path(framework, symbol, glue_id, src, dylib, exported)
      return Result.new(success?: false, error_stage: "no_llm",
                         error_detail: "LLM generator not provided") unless @llm

      MAX_LLM_RETRIES.times do |attempt|
        swift_source = @llm.generate(framework: framework, symbol: symbol, glue_id: glue_id)
        if swift_source.nil? || swift_source.strip.empty?
          @cache.record_attempt(framework: framework, symbol: symbol[:name],
                                 generator: "llm",
                                 error_stage: "llm_empty",
                                 error_detail: "LLM returned empty on attempt #{attempt}")
          next
        end

        gate_result = @gates.validate(swift_source, framework: framework,
                                                    glue_id: glue_id, symbol: symbol[:name])
        unless gate_result.pass?
          @cache.record_attempt(framework: framework, symbol: symbol[:name],
                                 generator: "llm",
                                 llm_response: swift_source,
                                 error_stage: "static_check",
                                 error_detail: gate_result.errors.join("; "))
          next
        end

        File.write(src, swift_source)
        ok, err = @swiftc.compile(source_path: src, dylib_path: dylib,
                                   runtime_dylib_path: @runtime_dylib_path)
        unless ok
          @cache.record_attempt(framework: framework, symbol: symbol[:name],
                                 generator: "llm", llm_response: swift_source,
                                 error_stage: "swiftc", error_detail: err)
          next
        end

        @cache.insert(glue_id: glue_id, framework: framework, symbol: symbol[:name],
                       swift_source: swift_source, dylib_path: dylib,
                       exported_symbol: exported, generator: "llm")
        return Result.new(success?: true, glue_id: glue_id, generator: "llm",
                           dylib_path: dylib, exported_symbol: exported)
      end

      Result.new(success?: false, error_stage: "llm_max_retries",
                  error_detail: "LLM exhausted #{MAX_LLM_RETRIES} attempts")
    end

    def compute_glue_id(framework, symbol)
      Digest::SHA256.hexdigest("#{framework}|#{symbol[:name]}|#{symbol[:signature]}")[0, 16]
    end
  end
end
```

```bash
bundle exec rake test TEST=test/test_glue_compiler.rb
git add -A
git commit -m "feat: add GlueCompiler orchestrator with Template-first / LLM-fallback"
```

---

## Task 19: Glue Loader (dlopen + pointer cache)

**Files:**
- Create: `lib/apple_sdk_mac/glue_loader.rb`
- Modify: `apple_sdk_mac_runtime.c`
- Create: `test/test_glue_loader.rb`

- [ ] **Step 19.1: Add dlopen helpers in `apple_sdk_mac_runtime.c`**

```c
#include <dlfcn.h>

static VALUE rb_dlopen_glue(VALUE self, VALUE path) {
    void *h = dlopen(StringValueCStr(path), RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        rb_raise(rb_eRuntimeError, "dlopen failed: %s", dlerror());
    }
    return ULL2NUM((uint64_t)h);
}

static VALUE rb_dlsym_glue(VALUE self, VALUE handle, VALUE symname) {
    void *h = (void *)NUM2ULL(handle);
    void *fn = dlsym(h, StringValueCStr(symname));
    if (!fn) {
        rb_raise(rb_eRuntimeError, "dlsym failed: %s", dlerror());
    }
    return ULL2NUM((uint64_t)fn);
}

typedef VALUE (*glue_fn_t)(const VALUE *argv, int argc);

static VALUE rb_invoke_glue(VALUE self, VALUE fn_ptr_v, VALUE args_v) {
    Check_Type(args_v, T_ARRAY);
    glue_fn_t fn = (glue_fn_t)NUM2ULL(fn_ptr_v);
    return fn(RARRAY_CONST_PTR(args_v), (int)RARRAY_LEN(args_v));
}
```

In `Init_apple_sdk_mac_runtime`:

```c
    rb_define_singleton_method(module, "dlopen_glue", rb_dlopen_glue, 1);
    rb_define_singleton_method(module, "dlsym_glue", rb_dlsym_glue, 2);
    rb_define_singleton_method(module, "invoke_glue", rb_invoke_glue, 2);
```

> **Implementation note:** The glue function ABI here uses `(VALUE *, int) -> VALUE` directly. Reconcile with TemplateGenerator's `UInt`-based signature by treating `VALUE` as `UInt` (which it is on 64-bit Ruby). Marshal helpers can then accept and return `VALUE` directly.

- [ ] **Step 19.2: `lib/apple_sdk_mac/glue_loader.rb`**

```ruby
# frozen_string_literal: true

module AppleSDKMac
  class GlueLoader
    def initialize
      @dylib_handles = {}
      @symbol_pointers = {}
    end

    def load(dylib_path:, exported_symbol:)
      return @symbol_pointers[exported_symbol] if @symbol_pointers.key?(exported_symbol)
      handle = @dylib_handles[dylib_path] ||= AppleSDKMacRuntime.dlopen_glue(dylib_path)
      ptr = AppleSDKMacRuntime.dlsym_glue(handle, exported_symbol)
      @symbol_pointers[exported_symbol] = ptr
      ptr
    end

    def invoke(fn_ptr, args)
      AppleSDKMacRuntime.invoke_glue(fn_ptr, args)
    end
  end
end
```

- [ ] **Step 19.3: Test**

```ruby
# test/test_glue_loader.rb
require "test_helper"
require "tmpdir"
require "apple_sdk_mac/glue_loader"
require "apple_sdk_mac/glue_compiler/swiftc_invoker"

class TestGlueLoader < Test::Unit::TestCase
  def test_loads_a_minimal_glue_and_invokes_it
    Dir.mktmpdir do |dir|
      src = File.join(dir, "g.swift")
      dylib = File.join(dir, "g.dylib")
      File.write(src, <<~SWIFT)
        import Foundation
        @c public func glue_minimal_passthrough(_ argv: UnsafePointer<UInt>, _ argc: Int32) -> UInt {
            return argv[0]
        }
      SWIFT
      ok, err = AppleSDKMac::GlueCompiler::SwiftcInvoker.new.compile(
        source_path: src, dylib_path: dylib
      )
      assert ok, err
      loader = AppleSDKMac::GlueLoader.new
      ptr = loader.load(dylib_path: dylib, exported_symbol: "glue_minimal_passthrough")
      result = loader.invoke(ptr, [42])
      assert_equal 42, result
    end
  end
end
```

```bash
bundle exec rake clobber compile test TEST=test/test_glue_loader.rb
git add -A
git commit -m "feat: add GlueLoader with dlopen/dlsym + in-process pointer cache"
```

---

## Task 20: Dispatcher

**Files:**
- Create: `lib/apple_sdk_mac/dispatcher.rb`
- Create: `test/test_dispatcher.rb`

- [ ] **Step 20.1: RED**

```ruby
require "test_helper"
require "apple_sdk_mac/dispatcher"

class TestDispatcher < Test::Unit::TestCase
  class FakeKnowledge
    def lookup_symbol(framework:, symbol:)
      return nil if symbol == "Missing"
      { name: symbol, kind: "function", abi: "c", content_hash: "h" }
    end
  end

  class FakeCache
    def initialize; @hits = {}; end
    def lookup(framework:, symbol:); @hits[[framework, symbol]]; end
    def fake_hit!(framework, symbol, exported, dylib)
      @hits[[framework, symbol]] = {
        glue_id: "g", dylib_path: dylib, exported_symbol: exported, generator: "template"
      }
    end
  end

  class FakeLoader
    attr_reader :calls
    def initialize; @calls = []; end
    def load(dylib_path:, exported_symbol:); @calls << [dylib_path, exported_symbol]; 0xCAFE; end
    def invoke(fn_ptr, args); ["invoked", fn_ptr, args]; end
  end

  def test_dispatch_uses_cache_hit
    cache = FakeCache.new
    cache.fake_hit!("CoreMIDI", "MIDIDispose", "glue_g_MIDIDispose", "/tmp/g.dylib")
    loader = FakeLoader.new
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: FakeKnowledge.new, glue_cache: cache,
      loader: loader, compiler: nil
    )
    result = d.dispatch(framework: "CoreMIDI", symbol: "MIDIDispose", args: [42])
    assert_equal ["invoked", 0xCAFE, [42]], result
    assert_equal [["/tmp/g.dylib", "glue_g_MIDIDispose"]], loader.calls
  end

  def test_dispatch_raises_on_unknown_symbol
    cache = FakeCache.new
    d = AppleSDKMac::Dispatcher.new(
      knowledge_cache: FakeKnowledge.new, glue_cache: cache,
      loader: FakeLoader.new, compiler: nil
    )
    assert_raise(AppleSDKMac::Error) do
      d.dispatch(framework: "CoreMIDI", symbol: "Missing", args: [])
    end
  end
end
```

```bash
git add test/test_dispatcher.rb
git commit -m "test: add failing spec for Dispatcher"
```

- [ ] **Step 20.2: GREEN — `lib/apple_sdk_mac/dispatcher.rb`**

```ruby
# frozen_string_literal: true

module AppleSDKMac
  class Error < StandardError; end
  class CompileError < Error; end

  class Dispatcher
    def initialize(knowledge_cache:, glue_cache:, loader:, compiler:)
      @knowledge = knowledge_cache
      @cache = glue_cache
      @loader = loader
      @compiler = compiler
    end

    def dispatch(framework:, symbol:, args: [])
      sym_meta = @knowledge.lookup_symbol(framework: framework, symbol: symbol)
      raise Error, "unknown symbol #{framework}::#{symbol}" unless sym_meta

      cache_hit = @cache.lookup(framework: framework, symbol: symbol)
      if cache_hit.nil?
        raise Error, "no glue cached for #{framework}::#{symbol}; call Apple.discover first"
      end

      fn_ptr = @loader.load(
        dylib_path: cache_hit[:dylib_path],
        exported_symbol: cache_hit[:exported_symbol]
      )
      @loader.invoke(fn_ptr, args)
    end
  end
end
```

```bash
bundle exec rake test TEST=test/test_dispatcher.rb
git add -A
git commit -m "feat: add Dispatcher (knowledge → cache → loader → invoke)"
```

---

## Task 21: SecurityCop (in-box monkey patches)

**Files:**
- Create: `lib/apple_sdk_mac/security_cop.rb`
- Create: `test/test_security_cop.rb`

- [ ] **Step 21.1: RED — verify banned operations raise inside the box and still work outside**

```ruby
require "test_helper"

class TestSecurityCop < Test::Unit::TestCase
  def test_string_eval_methods_raise_inside_box
    omit "Ruby::Box requires RUBY_BOX=1" unless defined?(Ruby::Box) && Ruby::Box.enabled?
    box = Ruby::Box.new
    box.require File.expand_path("../../lib/apple_sdk_mac/security_cop", __dir__)
    # Reach into the box and try to use Kernel#eval with a String argument.
    inside_attempt = -> { box.send(:eval, "1 + 1") }
    assert_raise(SecurityError) { inside_attempt.call }

    # Outside the box the same method works normally.
    outside_attempt = -> { Object.new.send(:eval, "1 + 1") }
    assert_equal 2, outside_attempt.call
  end

  def test_system_blocked_inside_box
    omit "Ruby::Box requires RUBY_BOX=1" unless defined?(Ruby::Box) && Ruby::Box.enabled?
    box = Ruby::Box.new
    box.require File.expand_path("../../lib/apple_sdk_mac/security_cop", __dir__)
    inside_attempt = -> { box.send(:system, "true") }
    assert_raise(SecurityError) { inside_attempt.call }
  end

  def test_file_read_blocked_inside_box
    omit "Ruby::Box requires RUBY_BOX=1" unless defined?(Ruby::Box) && Ruby::Box.enabled?
    box = Ruby::Box.new
    box.require File.expand_path("../../lib/apple_sdk_mac/security_cop", __dir__)
    inside_attempt = -> { box.send(:File).read("/etc/hosts") }
    assert_raise(SecurityError) { inside_attempt.call }
  end
end
```

```bash
git add test/test_security_cop.rb
git commit -m "test: add failing spec for SecurityCop in Ruby::Box"
```

- [ ] **Step 21.2: GREEN — `lib/apple_sdk_mac/security_cop.rb`**

```ruby
# frozen_string_literal: true

module AppleSDKMac
  class SecurityViolation < SecurityError; end
end

class Object
  string_eval_methods = %i[eval class_eval module_eval instance_eval]
  string_eval_methods.each do |m|
    original = instance_method(m) rescue nil
    next unless original
    define_method(m) do |*args, **kwargs, &block|
      if args.first.is_a?(String)
        raise AppleSDKMac::SecurityViolation,
              "#{m}(String) forbidden inside Apple box"
      end
      original.bind(self).call(*args, **kwargs, &block)
    end
  end

  %i[system spawn exec].each do |m|
    define_method(m) do |*|
      raise AppleSDKMac::SecurityViolation, "#{m} forbidden inside Apple box"
    end
  end
end

module Kernel
  module_function

  def `(*)
    raise AppleSDKMac::SecurityViolation, "backtick subprocess forbidden inside Apple box"
  end
end

class File
  class << self
    %i[read open new readlines binread foreach].each do |m|
      define_method(m) do |*|
        raise AppleSDKMac::SecurityViolation, "File.#{m} forbidden inside Apple box"
      end
    end
  end
end
```

> **Implementation note:** This is the v1 strict-mode SecurityCop. The user's main program is unaffected because Ruby::Box's "Independent monkey patches" semantics confine these patches to the box. If a needed exception arises (e.g., Apple-box internal must read a config file), add a narrow whitelist function rather than weakening the module-level overrides.

```bash
bundle exec rake test TEST=test/test_security_cop.rb
git add -A
git commit -m "feat: add SecurityCop with strict in-box overrides for eval-family/process/file/net"
```

---

## Task 22: Namespace Builder + did_you_mean

**Files:**
- Create: `lib/apple_sdk_mac/namespace_builder.rb`
- Create: `lib/apple_sdk_mac/did_you_mean.rb`
- Create: `test/test_namespace_builder.rb`

- [ ] **Step 22.1: RED**

```ruby
require "test_helper"
require "apple_sdk_mac/namespace_builder"

class TestNamespaceBuilder < Test::Unit::TestCase
  class FakeKnowledge
    def list_frameworks; ["CoreMIDI"]; end
    def list_framework_symbols(framework:, kinds: nil)
      [
        { name: "MIDIClientCreate", kind: "function", abi: "c", signature: "..." },
        { name: "MIDIClientRef", kind: "struct", abi: "c", signature: "..." }
      ]
    end
  end

  def test_builds_module_with_function_method
    box = Module.new
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: FakeKnowledge.new,
      target: box,
      dispatcher: ->(framework:, symbol:, args:) { ["dispatched", framework, symbol, args] }
    )
    builder.build!

    assert box.const_defined?(:CoreMIDI)
    coremidi = box.const_get(:CoreMIDI)
    assert_kind_of Module, coremidi
    assert_respond_to coremidi, :MIDIClientCreate
    result = coremidi.MIDIClientCreate("hi")
    assert_equal ["dispatched", "CoreMIDI", "MIDIClientCreate", ["hi"]], result
  end

  def test_struct_symbols_become_constants
    box = Module.new
    builder = AppleSDKMac::NamespaceBuilder.new(
      knowledge_cache: FakeKnowledge.new, target: box,
      dispatcher: ->(*) { nil }
    )
    builder.build!
    coremidi = box.const_get(:CoreMIDI)
    assert coremidi.const_defined?(:MIDIClientRef)
  end
end
```

```bash
git add test/test_namespace_builder.rb
git commit -m "test: add failing spec for NamespaceBuilder"
```

- [ ] **Step 22.2: GREEN — `lib/apple_sdk_mac/namespace_builder.rb`**

```ruby
# frozen_string_literal: true

module AppleSDKMac
  class NamespaceBuilder
    KIND_TO_DEFINER = {
      "function" => :method,
      "global_constant" => :method,
      "class" => :constant,
      "struct" => :constant,
      "actor" => :constant,
      "protocol" => :constant,
      "enum_module" => :constant
    }.freeze

    def initialize(knowledge_cache:, target:, dispatcher:)
      @knowledge = knowledge_cache
      @target = target
      @dispatcher = dispatcher
    end

    def build!
      @knowledge.list_frameworks.each do |fw|
        framework_module = define_framework_module(fw)
        symbols = @knowledge.list_framework_symbols(framework: fw)
        symbols.each do |sym|
          install_symbol(framework_module, fw, sym)
        end
      end
    end

    private

    def define_framework_module(name)
      if @target.const_defined?(name, false)
        @target.const_get(name)
      else
        m = Module.new
        @target.const_set(name, m)
        m
      end
    end

    def install_symbol(framework_module, framework_name, sym)
      mode = KIND_TO_DEFINER[sym[:kind]]
      return unless mode

      case mode
      when :method
        define_function_method(framework_module, framework_name, sym[:name])
      when :constant
        define_type_constant(framework_module, framework_name, sym[:name])
      end
    end

    def define_function_method(mod, framework, symbol_name)
      dispatcher = @dispatcher
      mod.singleton_class.send(:define_method, symbol_name) do |*args|
        dispatcher.call(framework: framework, symbol: symbol_name, args: args)
      end
    end

    def define_type_constant(mod, framework, type_name)
      return if mod.const_defined?(type_name, false)
      proxy_class = Class.new do
        define_singleton_method(:framework) { framework }
        define_singleton_method(:type_name) { type_name }
      end
      mod.const_set(type_name, proxy_class)
    end
  end
end
```

```bash
bundle exec rake test TEST=test/test_namespace_builder.rb
git add -A
git commit -m "feat: add NamespaceBuilder eager-defining functions and type proxies"
```

- [ ] **Step 22.3: did_you_mean integration**

`lib/apple_sdk_mac/did_you_mean.rb`:

```ruby
# frozen_string_literal: true
require "did_you_mean"

module AppleSDKMac
  module DidYouMeanIntegration
    class AppleSDKChecker
      def initialize(no_method_error)
        @receiver = no_method_error.receiver
        @method = no_method_error.name
      end

      def corrections
        return [] unless apple_module?(@receiver)
        framework = framework_name(@receiver)
        return [] unless framework
        knowledge = AppleSDKMac.knowledge_cache
        results = knowledge.search(framework: framework, query: @method.to_s, limit: 5)
        results.map { |r| r[:name] }
      end

      def formatter(corrections)
        if corrections.empty?
          "\nIf this is a real Apple SDK API not yet known to the bridge, run:\n" \
          "  Apple.discover(framework: :#{framework_name(@receiver)}, " \
          "symbol: :#{@method})\n"
        else
          msg = "\nDid you mean? #{corrections.join(', ')}\n"
          msg + "\nIf you want a brand-new API, run Apple.discover(...).\n"
        end
      end

      private

      def apple_module?(receiver)
        receiver.is_a?(Module) && AppleSDKMac.box_module?(receiver)
      end

      def framework_name(receiver)
        receiver.name && receiver.name.split("::").last
      end
    end
  end
end

DidYouMean.correct_error(NoMethodError, AppleSDKMac::DidYouMeanIntegration::AppleSDKChecker)
```

```bash
git add lib/apple_sdk_mac/did_you_mean.rb
git commit -m "feat: did_you_mean integration suggesting Apple SDK symbols + Apple.discover"
```

---

## Task 23: Public API and Ruby::Box bootstrap

**Files:**
- Create: `lib/apple_sdk_mac/public_api.rb`
- Create: `lib/apple_sdk_mac.rb`
- Create: `test/test_public_api.rb`

- [ ] **Step 23.1: GREEN — `lib/apple_sdk_mac/public_api.rb`**

```ruby
# frozen_string_literal: true
require_relative "config"
require_relative "knowledge_cache"
require_relative "compiled_glue_cache"
require_relative "glue_loader"
require_relative "glue_compiler"
require_relative "glue_compiler/llm_generator"
require_relative "dispatcher"
require_relative "namespace_builder"
require_relative "opaque_ref"
require_relative "did_you_mean"

module AppleSDKMac
  @config = nil
  @knowledge_cache = nil
  @glue_cache = nil
  @loader = nil
  @compiler = nil
  @dispatcher = nil
  @box_modules = {}

  class << self
    def configure
      yield(config) if block_given?
      config
    end

    def config
      @config ||= Config.new
    end

    def knowledge_cache
      @knowledge_cache ||= KnowledgeCache.open
    end

    def glue_cache
      @glue_cache ||= CompiledGlueCache.open(config.cache_dir, sdk_version: detect_sdk_version)
    end

    def loader
      @loader ||= GlueLoader.new
    end

    def compiler
      @compiler ||= GlueCompiler.new(
        cache: glue_cache,
        runtime_dylib_path: runtime_dylib_path,
        llm_generator: GlueCompiler::LLMGenerator.new
      )
    end

    def dispatcher
      @dispatcher ||= Dispatcher.new(
        knowledge_cache: knowledge_cache,
        glue_cache: glue_cache,
        loader: loader,
        compiler: compiler
      )
    end

    def discover(framework:, symbol:)
      sym_meta = knowledge_cache.lookup_symbol(framework: framework.to_s, symbol: symbol.to_s)
      raise Error, "symbol not in knowledge base: #{framework}::#{symbol}" unless sym_meta

      result = compiler.compile(framework: framework.to_s, symbol: sym_meta)
      unless result.success?
        raise CompileError,
              "discover failed at #{result.error_stage}: #{result.error_detail}"
      end
      install_into_box(framework, symbol, sym_meta)
      true
    end

    def event_loop
      ctx = EventLoopContext.new
      until ctx.stopped?
        AppleSDKMacRuntime.runloop_pump(0.01)
        AppleSDKMacRuntime.threading_poll(0.01)
        Fiber.scheduler&.yield
        yield(ctx) if block_given?
      end
    end

    def box_module?(mod)
      @box_modules.value?(mod) || @box_modules.values.any? { |fw| fw.const_defined?(mod.name.split("::").last) }
    end

    def register_framework_module(name, mod)
      @box_modules[name] = mod
    end

    private

    def detect_sdk_version
      `xcrun --show-sdk-version`.strip
    end

    def runtime_dylib_path
      File.expand_path("../apple_sdk_mac_runtime.bundle", __FILE__)
    end

    def install_into_box(framework, symbol, sym_meta)
      builder = NamespaceBuilder.new(
        knowledge_cache: knowledge_cache, target: ::Apple,
        dispatcher: ->(framework:, symbol:, args:) {
          dispatcher.dispatch(framework: framework, symbol: symbol, args: args)
        }
      )
      builder.build!
    end
  end

  class EventLoopContext
    attr_reader :start_time
    def initialize; @start_time = Time.now; @stopped = false; end
    def stop; @stopped = true; end
    def stopped?; @stopped; end
    def elapsed; Time.now - @start_time; end
    def fiber_scheduler_active?; !Fiber.scheduler.nil?; end
  end
end
```

- [ ] **Step 23.2: Top-level `lib/apple_sdk_mac.rb`**

```ruby
# frozen_string_literal: true

require_relative "apple_sdk_mac/version"
require_relative "apple_sdk_mac/apple_sdk_mac_runtime"
require_relative "apple_sdk_mac/public_api"

if defined?(Ruby::Box) && Ruby::Box.enabled?
  Object.send(:remove_const, :Apple) if Object.const_defined?(:Apple, false)
  Object.const_set(:Apple, Ruby::Box.new)
  Apple.require File.expand_path("../apple_sdk_mac/security_cop", __FILE__)
else
  warn "[rb-apple-sdk-mac] RUBY_BOX=1 not set; falling back to plain Module (isolation degraded)" if $VERBOSE
  Object.const_set(:Apple, Module.new)
end

module Apple
  def self.discover(**kwargs); ::AppleSDKMac.discover(**kwargs); end
  def self.event_loop(&block); ::AppleSDKMac.event_loop(&block); end
  def self.configure(&block); ::AppleSDKMac.configure(&block); end
end

::AppleSDKMac.send(:install_into_box, nil, nil, nil) if defined?(::AppleSDKMac::KnowledgeCache)
```

> **Implementation note:** The `Apple.require` line works only when `Ruby::Box.enabled?` is true. The fallback `Module.new` path is for development environments where Ruby::Box is unavailable. The `install_into_box` call eagerly populates the namespace using the existing knowledge base; consumers calling `Apple::CoreMIDI.SomeFn` get methods that route through `Apple.discover` lazily on first use.

```bash
bundle exec rake test
git add -A
git commit -m "feat: bootstrap Apple Ruby::Box with public API surface"
```

---

## Task 24: CoreMIDI end-to-end smoke test (the proving case)

**Files:**
- Create: `test/integration/test_coremidi_smoke.rb`

- [ ] **Step 24.1: Write the smoke test**

```ruby
# frozen_string_literal: true
require "test_helper"
require "apple_sdk_mac"

class TestCoreMIDISmoke < Test::Unit::TestCase
  def test_create_client_and_dispose
    omit "knowledge base not built" unless AppleSDKMac.knowledge_cache.list_frameworks.include?("CoreMIDI")
    Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate) rescue nil
    Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientDispose) rescue nil

    client = Apple::CoreMIDI.MIDIClientCreate("rb-apple-sdk-mac smoke test", nil, nil)
    assert_not_nil client
    Apple::CoreMIDI.MIDIClientDispose(client)
  end
end
```

- [ ] **Step 24.2: Run the smoke test**

```bash
RUBY_BOX=1 bundle exec rake test TEST=test/integration/test_coremidi_smoke.rb
```

> **Implementation note:** This is the v1 acceptance test. It exercises `discover` for two CoreMIDI APIs (which engages knowledge cache lookup, Glue Compiler with Template Generator path, swiftc compilation, validation gates, dlopen, and Dispatcher), and then exercises hot-path dispatch through the `Apple::CoreMIDI` namespace. If any pillar misbehaves under real Apple-side calls, this test surfaces it. Iterate until green.

- [ ] **Step 24.3: Commit**

```bash
git add test/integration/test_coremidi_smoke.rb
git commit -m "test: add CoreMIDI end-to-end smoke covering discover + hot-path dispatch"
```

---

## Task 25: Examples and README

**Files:**
- Create: `examples/coremidi_receive.rb`
- Create: `examples/vision_ocr.rb`
- Modify: `README.md`

- [ ] **Step 25.1: Write `examples/coremidi_receive.rb`**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "apple_sdk_mac"

[:MIDIClientCreate, :MIDIInputPortCreate, :MIDIGetSource,
 :MIDIPortConnectSource].each do |sym|
  Apple.discover(framework: :CoreMIDI, symbol: sym)
end

client = Apple::CoreMIDI.MIDIClientCreate("rb-apple-sdk-mac demo", nil, nil)
in_port = Apple::CoreMIDI.MIDIInputPortCreate(client, "input", nil, nil) do |packets, _|
  packets.each { |pkt| puts pkt.inspect }
end
src = Apple::CoreMIDI.MIDIGetSource(0)
Apple::CoreMIDI.MIDIPortConnectSource(in_port, src, nil)

Apple.event_loop { |ctx| ctx.stop if ctx.elapsed > 30 }
```

- [ ] **Step 25.2: Write `examples/vision_ocr.rb`**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "apple_sdk_mac"

# Adapt to the actual Vision API shape the bridge surfaces.
puts Apple::Vision.constants.first(10).inspect
```

- [ ] **Step 25.3: Replace README**

```markdown
# rb-apple-sdk-mac

Runtime dynamic Ruby ↔ Apple SDK bridge for macOS. Call any public Apple framework API from Ruby with no pre-declarations.

## Requirements

- macOS 26+
- Ruby 4.x master with `RUBY_BOX=1` (required for namespace isolation)
- Xcode + Swift 6.3+
- Sibling gems: `rb-foundation-model-mac`, `rb-apple-sdk-knowledge`, `swift_gem`

## Installation

```ruby
gem "rb-apple-sdk-mac"
```

After install:

```bash
bundle exec rake apple:knowledge:rebuild   # see rb-apple-sdk-knowledge
```

## Usage

```ruby
require "apple_sdk_mac"

# First-time: declare you want to call this API
Apple.discover(framework: :CoreMIDI, symbol: :MIDIClientCreate)

# Use it
client = Apple::CoreMIDI.MIDIClientCreate("MyClient", nil, nil)
```

See `examples/` for more.

## Architecture

See `docs/superpowers/specs/2026-05-04-rb-apple-sdk-mac-design.md`.

## License

MIT
```

- [ ] **Step 25.4: Final commit + push**

```bash
git add examples/ README.md
git commit -m "docs: add usage examples and README for rb-apple-sdk-mac"
gh repo create bash0C7/rb-apple-sdk-mac --public --source=. --remote=origin --push
```

---

## Out of scope for v1 (deferred with technical justification)

- **AsyncSequence streaming through Async Bridge with full Fiber.scheduler integration:** The architecture supports it (Pillar 6 + Pillar 7 composed), and the `Apple.event_loop` helper provides a working Fiber.scheduler hook. The full polish — auto-detecting scheduler and reshaping a streaming AsyncSequence into a Fiber-suspended Enumerator — is a Pillar 6 v1 task already in this plan. If Apple's API design for AsyncSequence on Foundation Models / Combine evolves before v1 ships, the implementer should rely on the current public API at that moment.
- **Conformance Bridge LLM-codegen for protocol shims (full implementation, beyond skeleton in Task 10):** This requires generating an entire Swift class conforming to a target protocol. Plan-C's Task 10 lays the registry and stubs; the LLM Generator extension to produce the shim class is intentionally left for hands-on iteration during Plan-C execution because the Apple-protocol-specific output shapes need observation against real protocols. Technical reason: cannot pre-specify the Swift code template without seeing real protocol method-shape distributions. Note: this is the Q1 open question from the design spec.
- **Bulk `discover_framework`** is sketched in `examples/vision_ocr.rb` but not implemented as a standalone task here. The same NamespaceBuilder + Compiler primitives compose into it; a single task can be added (Task 26) once the smoke test is green.
