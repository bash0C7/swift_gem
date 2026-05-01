# SwiftGem

Helpers for building Ruby native extensions whose implementation lives in Swift via Swift Package Manager. macOS / Apple Silicon only. Targets Apple platform frameworks (Vision, AVFoundation, NaturalLanguage, Speech, etc.) reachable from Swift.

## Installation

```bash
bundle add swift_gem
```

```bash
gem install swift_gem
```

## Tutorial: build `rb-hello-swift`

A walkthrough that builds a tiny gem whose `HelloSwift.perform` always returns `"Hello, Swift!"` from a Swift function. About three edits.

### 1. Scaffold

Clone this repo, install deps, then generate the skeleton next to it (so the generated `Gemfile`'s `path: "../swift_gem"` resolves):

```bash
git clone https://github.com/bash0C7/swift_gem
cd swift_gem
bundle install
bundle exec rake "new[rb-hello-swift]"
cd ../rb-hello-swift
```

You now have an 18-file skeleton (see *Generated files* below for the full list).

### 2. Edit the Swift implementation

Open `ext/hello_swift/Sources/HelloSwift/HelloSwift.swift` and replace the body of the default `hello_swift_perform`:

```swift
import Foundation

func hello_swift_perform(_ input: String) -> String {
    return "Hello, Swift!"
}
```

The companion `ext/hello_swift/Sources/HelloSwift/HelloSwiftBridge.swift`, `ext/hello_swift/hello_swift.c`, and `ext/hello_swift/hello_swift.h` already wire up a single `String -> String` method called `perform`, so for this tutorial you don't need to touch them.

### 3. Update the test fixture

Edit `test/hello_swift/sample_test.rb` so it pins the new contract:

```ruby
require "test_helper"

class HelloSwiftSampleTest < Test::Unit::TestCase
  test "perform returns the canned greeting" do
    assert_equal("Hello, Swift!", HelloSwift.perform("anything"))
  end
end
```

### 4. Build and test

```bash
bundle install
bundle exec rake test
```

`rake test` chains through `Rake::ExtensionTask`: it runs `swift build -c release --package-path ext/hello_swift`, links the C bridge into `lib/hello_swift/hello_swift.bundle`, then runs the spec. Expect a single passing test.

### 5. Use it from Ruby

```bash
bundle exec rake console
```

```ruby
HelloSwift.perform("anything")
# => "Hello, Swift!"
```

That's the full loop. To grow the gem, add more `@_cdecl` functions in `Bridge.swift`, mirror them in `hello_swift.h`, and expose them via `rb_define_singleton_method` in `hello_swift.c`.

## Generated files

`bundle exec rake "new[<gem-name>]"` writes 18 files. Edit the rows marked **EDIT** to flesh out your gem; the rest is infrastructure.

| Path | Kind | Role |
|---|---|---|
| `<gem-name>.gemspec` | ERB | Gemspec with `swift_gem` runtime dep, `extensions = ['ext/<name>/extconf.rb']`, MIT license. **EDIT** summary / description before publishing |
| `Gemfile` | ERB | `path: "../swift_gem"` for local dev; rake-compiler dev dep |
| `Rakefile` | ERB | `Rake::ExtensionTask`, `task test: :compile`, `task console: :compile` |
| `README.md` | ERB | TODO scaffold. **EDIT** to describe your gem |
| `LICENSE.txt` | static | MIT |
| `.gitignore` | static | Build artifacts, `Gemfile.lock`, vendor/ |
| `.bundle/config` | static | Pins `BUNDLE_PATH` to `vendor/bundle` |
| `lib/<module_path>.rb` | ERB | Module entry: requires version + the compiled `.bundle`; declares `module <ModuleName>; class Error < StandardError; end; end` |
| `lib/<module_path>/version.rb` | ERB | `VERSION = "0.1.0"` |
| `ext/<module_path>/Package.swift` | ERB | SPM `.dynamic` library targeting macOS 12+ |
| `ext/<module_path>/Sources/<ModuleName>/<ModuleName>.swift` | ERB | **EDIT** — your Swift implementation. Default echoes the input |
| `ext/<module_path>/Sources/<ModuleName>/<ModuleName>Bridge.swift` | ERB | **EDIT** — `@_cdecl` bridge with `strdup` + paired `_free` |
| `ext/<module_path>/<module_path>.c` | ERB | **EDIT** — CRuby ext: `Init_<name>`, `rb_define_singleton_method`, calls the Swift bridge, copies the result, frees the Swift buffer |
| `ext/<module_path>/<module_path>.h` | ERB | **EDIT** — C prototypes mirroring `Bridge.swift` |
| `ext/<module_path>/extconf.rb` | ERB | `SwiftGem::Mkmf.create_swift_makefile(...)` with `source_dir: __dir__` |
| `examples/<module_path>.swift` | ERB | Pure-Swift sample script for verifying behavior without Ruby |
| `test/test_helper.rb` | ERB | Loads the gem from `lib/`, requires `test-unit` |
| `test/<module_path>/sample_test.rb` | ERB | **EDIT** — smoke spec; default asserts `<ModuleName>.perform("hello") == "hello"` |

## Memory model

- Swift returns a Swift `String`.
- `Bridge.swift`'s `@_cdecl` calls `strdup(result)` so the caller owns a malloc'd C string.
- `<gem>.c` copies that into a Ruby UTF-8 String via `rb_utf8_str_new_cstr`, then calls the paired `*_free` to release the Swift-allocated buffer before returning.
- Ruby owns the GC'd String; the Swift heap allocation is gone.

The free happens inside the C ext call rather than at GC time, which is tighter than the LT's `FFI` + `FFI::AutoPointer` pattern.

## Why no Swift-binding generator

`go-gem-wrapper` ships `_tools/ruby_h_to_go` to auto-generate Go bindings for `ruby.h`. `swift_gem` does not port it: per-gem the Swift surface is small (~30 lines combined for `Bridge.swift` + `<gem>.c`), and there is no Go-runtime / C-runtime friction that auto-generation would need to absorb. Reconsider when a third consumer needs a noticeably wider Swift surface.

## Acknowledgments

- [@sue445](https://github.com/sue445)'s [go-gem-wrapper](https://github.com/ruby-go-gem/go-gem-wrapper/tree/main/_gem) (`go_gem`) and the [RubyKaigi 2025 talk](https://rubykaigi.org/2025/presentations/sue445.html). The mkmf shim and `Rake::ExtensionTask` flow are ports of `go_gem`'s pattern, with `swift build -c release --package-path` + an SPM `.dynamic` library in place of `go build -buildmode=c-shared`.
- [@sussan0416](https://github.com/sussan0416)'s [Tram LT (2026-04-25)](https://www.docswell.com/s/sussan0416/K7NG3W-2026-04-25-Tram-LT). The Swift-side recipe the scaffold ships — `@_cdecl` + `strdup` + a paired `*_free`.
- [jakeoeding/swift-gem-poc](https://github.com/jakeoeding/swift-gem-poc). Concrete layout reference for the hand-written C bridge.

## License

MIT.
