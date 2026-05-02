# SwiftGem

Helpers for building Ruby native extensions whose implementation lives in Swift via Swift Package Manager. macOS / Apple Silicon only. Targets Apple platform frameworks (Vision, AVFoundation, NaturalLanguage, Speech, etc.) reachable from Swift.

## Requirements

- macOS 12+, Apple Silicon
- Swift 6.3+ (SE-0495 `@c` attribute)
- Ruby 3.2+, Bundler 4.x

The recommended toolchain installer is [swiftly](https://www.swift.org/install/macos/). Xcode is *not* required — `brew install swiftly && swiftly install 6.3 && swiftly use 6.3` is enough. Coexists with any Xcode-bundled Swift via PATH.

`bundle exec rake check` verifies the active toolchain is 6.3+; it runs automatically before `rake test`.

## Installation

```bash
bundle add swift_gem
```

```bash
gem install swift_gem
```

## Tutorial: build `rb-hello-swift`

A walkthrough that builds a tiny gem whose `HelloSwift.perform("RUBY")` returns `"Hello, Swift! RUBY"` — the Swift side prefixes a greeting and echoes whatever Ruby passed in, so the round-trip is visible end-to-end. About three edits.

### 1. Scaffold

Clone this repo, install deps, then generate the skeleton next to it (so the generated `Gemfile`'s `path: "../swift_gem"` resolves):

```bash
git clone https://github.com/bash0C7/swift_gem
cd swift_gem
bundle install
bundle exec rake new rb-hello-swift ../rb-hello-swift
cd ../rb-hello-swift
```

You now have an 18-file skeleton (see *Generated files* below for the full list).

### 2. Edit the Swift implementation

Open `ext/hello_swift/Sources/HelloSwift/HelloSwift.swift` and replace the body of the default `hello_swift_perform`:

```swift
import Foundation

func hello_swift_perform(_ input: String) -> String {
    return "Hello, Swift! \(input)"
}
```

The companion `ext/hello_swift/Sources/HelloSwift/HelloSwiftBridge.swift` and `ext/hello_swift/hello_swift.c` already wire up a single `String -> String` method called `perform`, so for this tutorial you don't need to touch them. The C header `HelloSwift-Swift.h` is generated automatically by `swift build` (SE-0495) and gitignored.

### 3. Update the test fixture

Edit `test/hello_swift/sample_test.rb` so it pins the new contract:

```ruby
require "test_helper"

class HelloSwiftSampleTest < Test::Unit::TestCase
  test "perform greets with the input echoed back" do
    assert_equal("Hello, Swift! RUBY", HelloSwift.perform("RUBY"))
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
HelloSwift.perform("RUBY")
# => "Hello, Swift! RUBY"
```

That's the full loop. To grow the gem, add more `@c` functions in `Bridge.swift` (the matching C declarations are generated automatically by `swift build` into `HelloSwift-Swift.h`), and expose them via `rb_define_singleton_method` in `hello_swift.c`.

## Generated files

`bundle exec rake new <gem-name> [dest_dir]` writes 17 files. Edit the rows marked **EDIT** to flesh out your gem; the rest is infrastructure.

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
| `ext/<module_path>/Sources/<ModuleName>/<ModuleName>Bridge.swift` | ERB | **EDIT** — `@c` bridge with `strdup` + paired `_free` |
| `ext/<module_path>/<module_path>.c` | ERB | **EDIT** — CRuby ext: `Init_<name>`, `rb_define_singleton_method`, includes the auto-generated `<ModuleName>-Swift.h`, calls the Swift bridge, copies the result, frees the Swift buffer |
| `ext/<module_path>/extconf.rb` | ERB | `SwiftGem::Mkmf.create_swift_makefile(...)` with `source_dir: __dir__` |
| `examples/<module_path>.swift` | ERB | Pure-Swift sample script for verifying behavior without Ruby |
| `test/test_helper.rb` | ERB | Loads the gem from `lib/`, requires `test-unit` |
| `test/<module_path>/sample_test.rb` | ERB | **EDIT** — smoke spec; default asserts `<ModuleName>.perform("hello") == "hello"` |

## Memory model

- Swift returns a Swift `String`.
- `Bridge.swift`'s `@c` calls `strdup(result)` so the caller owns a malloc'd C string. The C declaration the ext consumes is auto-generated by `swift build -emit-clang-header-path` into `<ModuleName>-Swift.h` (SE-0495 compatibility header).
- `<gem>.c` copies that into a Ruby UTF-8 String via `rb_utf8_str_new_cstr`, then calls the paired `*_free` to release the Swift-allocated buffer before returning.
- Ruby owns the GC'd String; the Swift heap allocation is gone.

The free happens inside the C ext call rather than at GC time.

### Distribution: why the auto-generated header isn't shipped

`<ModuleName>-Swift.h` is a build artifact, not a source file. It is gitignored, and `spec.files` (driven by `git ls-files`) excludes it from the published `.gem` package. This is fine because `swift_gem`-based gems are source-distributed: when the end user runs `gem install <gem>`, RubyGems invokes `extconf.rb` (registered as `spec.extensions`), which calls `SwiftGem::Mkmf.create_swift_makefile`, which in turn runs `swift build -emit-clang-header-path` and regenerates the header on the user's machine. The Makefile then compiles `<gem>.c` against the freshly emitted header. End users therefore need Swift 6.3+ installed (the same Requirements section above); `SwiftGem::SwiftVersionCheck` aborts the install with a friendly message if the toolchain is missing or too old.

This pattern would change for a pre-compiled native gem (e.g. shipping a built `.bundle` for `arm64-darwin`), but `swift_gem` does not currently scaffold that path.

## Why no Swift-binding generator

`go-gem-wrapper` ships `_tools/ruby_h_to_go` to auto-generate Go bindings for `ruby.h`. `swift_gem` does not port it: per-gem the Swift surface is small (~30 lines combined for `Bridge.swift` + `<gem>.c`), and there is no Go-runtime / C-runtime friction that auto-generation would need to absorb. Reconsider when a third consumer needs a noticeably wider Swift surface.

## Acknowledgments

- [@sue445](https://github.com/sue445)'s [go-gem-wrapper](https://github.com/ruby-go-gem/go-gem-wrapper/tree/main/_gem) (`go_gem`) and the [RubyKaigi 2025 talk](https://rubykaigi.org/2025/presentations/sue445.html). The mkmf shim and `Rake::ExtensionTask` flow are ports of `go_gem`'s pattern, with `swift build -c release --package-path` + an SPM `.dynamic` library in place of `go build -buildmode=c-shared`.
- [@sussan0416](https://github.com/sussan0416)'s [Tram LT (2026-04-25)](https://www.docswell.com/s/sussan0416/K7NG3W-2026-04-25-Tram-LT). The Swift-side recipe the scaffold ships — `@_cdecl` (now `@c` per [SE-0495](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0495-cdecl.md)) + `strdup` + a paired `*_free`.
- [jakeoeding/swift-gem-poc](https://github.com/jakeoeding/swift-gem-poc). Concrete layout reference for the hand-written C bridge.

## License

MIT.
