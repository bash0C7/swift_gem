# SwiftGem

Helpers for building Ruby native extensions whose implementation lives in Swift via Swift Package Manager. macOS / Apple Silicon only. Targets Apple platform frameworks (Vision, AVFoundation, NaturalLanguage, Speech, etc.) reachable from Swift.

## Requirements

- macOS 27+, Apple Silicon
- Xcode 27 (builds run `xcrun swift`)
- Ruby 4.0+, Bundler 4.x

## Tutorial: build `rb-hello-swift`

A walkthrough that builds a tiny gem whose `HelloSwift.perform("RUBY")` returns `"Hello, Swift! RUBY"`. The Swift side prefixes a greeting to whatever Ruby passed in, so the round trip is visible end to end.

### 1. Scaffold

Clone this repo, install dependencies, then generate the skeleton next to it:

```bash
git clone https://github.com/bash0C7/swift_gem
cd swift_gem
bundle install
bundle exec rake "new[rb-hello-swift,../rb-hello-swift]"
cd ../rb-hello-swift
```

See *Generated files* below for the skeleton layout.

### 2. Edit the Swift implementation

Open `ext/hello_swift/Sources/HelloSwift/HelloSwift.swift` and replace the body of `perform`:

```swift
/// Prefixes a greeting to the string received from Ruby.
///
/// - Parameter input: The string passed from Ruby.
/// - Returns: The greeting followed by `input`.
func perform(_ input: String) -> String { "Hello, Swift! \(input)" }
```

`HelloSwiftBridge.swift` and `hello_swift.c` already wire `perform` up as a `String -> String` singleton method on `HelloSwift`, so they need no changes here.

### 3. Update the test

Edit `test/hello_swift/sample_test.rb`:

```ruby
# frozen_string_literal: true

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

`rake test` runs `xcrun swift build -c release --package-path ext/hello_swift`, builds the C extension into `lib/hello_swift/hello_swift.bundle`, then runs the tests.

### 5. Use it from Ruby

```bash
bundle exec rake console
```

```ruby
HelloSwift.perform("RUBY")
# => "Hello, Swift! RUBY"
```

To add more functions, declare them in `HelloSwiftBridge.swift` with `@c(<name>)` and register them in `hello_swift.c` with `rb_define_singleton_method`.

## Generated files

`bundle exec rake "new[<gem-name>,<dest-dir>]"` writes the files below. Rows marked **EDIT** hold your gem's content; the rest is infrastructure.

| Path | Kind | Role |
|---|---|---|
| `<gem-name>.gemspec` | ERB | Gemspec with `extensions = ["ext/<module_path>/extconf.rb"]`, `required_ruby_version >= 4.0`, MIT license. **EDIT** summary and description before publishing |
| `Gemfile` | ERB | `gemspec` plus `rake`, `rake-compiler`, `test-unit`, `irb` |
| `Rakefile` | ERB | `Rake::ExtensionTask`, `task :swift`, `compile: :swift`, `test: :compile`, `console: :compile` |
| `README.md` | ERB | Scaffold. **EDIT** to describe your gem |
| `LICENSE.txt` | static | MIT |
| `.gitignore` | static | Build artifacts, `Gemfile.lock`, `vendor/bundle/` |
| `.bundle/config` | static | Pins `BUNDLE_PATH` to `vendor/bundle` |
| `lib/<module_path>.rb` | ERB | Requires the version and the compiled `.bundle`; declares `<ModuleName>::Error` |
| `lib/<module_path>/version.rb` | ERB | `VERSION = "0.1.0"` |
| `sig/<module_path>.rbs` | ERB | RBS for `VERSION`, `Error` and `perform` |
| `ext/<module_path>/Package.swift` | ERB | SPM `.dynamic` library, `swift-tools-version: 6.4`, `.macOS(.v27)` |
| `ext/<module_path>/Sources/<ModuleName>/<ModuleName>.swift` | ERB | **EDIT** Swift implementation `perform(_:)` |
| `ext/<module_path>/Sources/<ModuleName>/<ModuleName>Bridge.swift` | ERB | **EDIT** `@c` bridge `cPerform` / `cFree` |
| `ext/<module_path>/<module_path>.c` | ERB | **EDIT** CRuby ext: `Init_<module_path>`, `rb_define_singleton_method`, calls the bridge |
| `ext/<module_path>/extconf.rb` | ERB | Calls `SwiftGem::Mkmf.create_swift_makefile` with `source_dir: __dir__` |
| `ext/<module_path>/swift_mkmf.rb` | vendored | Copy of `lib/swift_gem/mkmf.rb`, loaded by `extconf.rb` with `require_relative` |
| `examples/<module_path>.swift` | ERB | Standalone Swift script, run with `xcrun swift examples/<module_path>.swift <input>` |
| `test/test_helper.rb` | ERB | Loads the gem from `lib/` and `test-unit` |
| `test/<module_path>/sample_test.rb` | ERB | **EDIT** smoke test asserting `<ModuleName>.perform("hello") == "hello"` |

## Memory model

- `perform` returns a Swift `String`.
- `cPerform` in `Bridge.swift` is exported to C as `<module_path>_perform` with `@c`. It calls `strdup`, so the caller owns a malloc'd C string.
- `<module_path>.c` copies that string into a Ruby UTF-8 String with `rb_utf8_str_new_cstr`, then calls `<module_path>_free` (`cFree`) to release the buffer.

## Build output

`xcrun swift build` writes `<ModuleName>-Swift.h` under `ext/<module_path>/.build/out/Intermediates.noindex/GeneratedModuleMaps/`, and the C extension compiles against it with `-I`. DocC comments (`///`) on `@c` functions are carried into the header. The library is linked from `ext/<module_path>/.build/release`.

The header lives in `.build`, which is gitignored, so it is not part of the published `.gem`. `gem install` runs `extconf.rb`, which runs `xcrun swift build` on the installing machine.

## Acknowledgments

- [@sue445](https://github.com/sue445)'s [go-gem-wrapper](https://github.com/ruby-go-gem/go-gem-wrapper/tree/main/_gem) (`go_gem`) and the [RubyKaigi 2025 talk](https://rubykaigi.org/2025/presentations/sue445.html). The mkmf shim and `Rake::ExtensionTask` flow are ports of `go_gem`'s pattern, with `xcrun swift build -c release --package-path` and an SPM `.dynamic` library in place of `go build -buildmode=c-shared`.
- [@sussan0416](https://github.com/sussan0416)'s [Tram LT (2026-04-25)](https://www.docswell.com/s/sussan0416/K7NG3W-2026-04-25-Tram-LT). The Swift-side recipe the scaffold ships: `@c` ([SE-0495](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0495-cdecl.md)), `strdup`, and a paired free function.
- [jakeoeding/swift-gem-poc](https://github.com/jakeoeding/swift-gem-poc). Layout reference for the hand-written C bridge.

## License

MIT.
