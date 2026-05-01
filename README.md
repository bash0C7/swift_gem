# SwiftGem

Helpers for building Ruby native extensions whose implementation lives in Swift via Swift Package Manager. macOS / Apple Silicon only. Targets Apple platform frameworks (Vision, AVFoundation, NaturalLanguage, Speech, etc.) reachable from Swift.

## Installation

```bash
bundle add swift_gem
```

```bash
gem install swift_gem
```

## Usage

### Scaffold a new Swift-extension gem

Clone this repo, `bundle install`, then:

```bash
bundle exec rake "new[rb-foo-mac]"
```

Or specify a destination directory:

```bash
bundle exec rake "new[rb-foo-mac,/path/to/dest]"
```

Creates a complete swift-gem skeleton at `./rb-foo-mac/` (or the given destination): gemspec, Gemfile, Rakefile, lib/, ext/, examples/, test/. Naming transforms strip a leading `rb-` and produce a single top-level `FooMac` module (per the `rb-skypemac` convention).

### Wire up extconf.rb in your gem

```ruby
# ext/foo_mac/extconf.rb
require "swift_gem/mkmf"

SwiftGem::Mkmf.create_swift_makefile(
  "foo_mac/foo_mac",
  package: "FooMac",
  source_dir: __dir__
)
```

`source_dir: __dir__` is required so that `swift build --package-path` resolves correctly when rake-compiler invokes extconf.rb from `tmp/<arch>/<gem>/<ver>/`.

### Wire up Rakefile

```ruby
require "rake/extensiontask"

Rake::ExtensionTask.new("foo_mac") do |ext|
  ext.lib_dir = "lib/foo_mac"
end

task test: :compile
```

`bundle exec rake test` then runs swift build, links the C bridge, and runs the spec in one shot.

## Development

```bash
bundle install
bundle exec rake test
```

`bundle exec rake console` starts an IRB session with `SwiftGem::Mkmf` and `SwiftGem::Generator` preloaded.

## Generated files

`bundle exec rake "new[<gem-name>]"` writes 18 files under the destination. Edit the rows marked **EDIT** to flesh out your gem; the rest is infrastructure you usually leave alone.

| Path | Kind | Role |
|---|---|---|
| `<gem-name>.gemspec` | ERB | gemspec with `swift_gem` runtime dep, `extensions = ['ext/<name>/extconf.rb']`, MIT license; **EDIT** summary / description before publishing |
| `Gemfile` | ERB | Pulls `swift_gem` via `path: "../swift_gem"` for local development; declares rake-compiler dev dep |
| `Rakefile` | ERB | `Rake::ExtensionTask`, `task test: :compile`, `task console: :compile` so a single command builds + tests + opens IRB |
| `README.md` | ERB | TODO scaffold; **EDIT** to describe your gem |
| `LICENSE.txt` | static | MIT |
| `.gitignore` | static | Build artifacts (`ext/**/.build/`, `lib/**/*.bundle`), `Gemfile.lock`, vendor/, etc. |
| `.bundle/config` | static | Pins `BUNDLE_PATH` to `vendor/bundle` |
| `lib/<module_path>.rb` | ERB | Module entry: requires version + the compiled `.bundle`; declares `module <ModuleName>; class Error < StandardError; end; end` |
| `lib/<module_path>/version.rb` | ERB | `VERSION = "0.1.0"` |
| `ext/<module_path>/Package.swift` | ERB | SPM `.dynamic` library targeting macOS 12+ |
| `ext/<module_path>/Sources/<ModuleName>/<ModuleName>.swift` | ERB | **EDIT** — the actual Swift implementation. Default body just echoes the input string. Add `import Vision` / `import AVFoundation` / `import NaturalLanguage` / etc. and write the real function here |
| `ext/<module_path>/Sources/<ModuleName>/<ModuleName>Bridge.swift` | ERB | **EDIT** — `@_cdecl` bridge with `strdup` + a paired `_free`. Adjust the function signatures to match what the implementation file exposes. Memory rule: alloc with `strdup` here, free in the matching `_free` |
| `ext/<module_path>/<module_path>.c` | ERB | **EDIT** — the CRuby ext: `Init_<name>`, `rb_define_singleton_method`, calls the Swift bridge, copies the result into a Ruby UTF-8 String, then calls the paired `*_free` to release the Swift-allocated buffer |
| `ext/<module_path>/<module_path>.h` | ERB | **EDIT** — C prototypes mirroring `Bridge.swift` |
| `ext/<module_path>/extconf.rb` | ERB | `SwiftGem::Mkmf.create_swift_makefile(...)` with `source_dir: __dir__` (required by rake-compiler) |
| `examples/<module_path>.swift` | ERB | Pure-Swift sample script for verifying Vision / AVFoundation / etc. behavior without going through Ruby; **EDIT** as needed |
| `test/test_helper.rb` | ERB | Loads the gem from `lib/`, requires `test-unit` |
| `test/<module_path>/sample_test.rb` | ERB | Smoke spec asserting `<ModuleName>.perform("hello") == "hello"` (matches the default echo); **EDIT** when you change the API |

## Memory model

The scaffold ships an end-to-end leak-free path for handing strings across the Ruby ⇄ Swift boundary, matching the recipe from [the Tram LT](https://www.docswell.com/s/sussan0416/K7NG3W-2026-04-25-Tram-LT) listed in *Acknowledgments* below:

1. The Swift implementation returns a Swift `String`.
2. `Bridge.swift`'s `@_cdecl` function calls `strdup(result)` to hand the caller a malloc'd C string.
3. The C ext (`<gem>.c`) calls the Swift function, **immediately** copies the C string into a Ruby UTF-8 String via `rb_utf8_str_new_cstr`, then calls the paired `*_free` (which is just `free(ptr)`) to release the Swift-allocated buffer before returning to Ruby.
4. Ruby owns the resulting String under its own GC; the Swift heap allocation is gone.

This is stricter than the LT's `FFI` + `FFI::AutoPointer` pattern (which frees lazily at GC time): we free deterministically inside the C-ext call, so memory is reclaimed before control returns to Ruby. Same Swift-side contract, tighter Ruby-side ownership.

## Why no Swift-binding generator?

`go-gem-wrapper` ships a `_tools/ruby_h_to_go` that auto-generates Go bindings for `ruby.h`. `swift_gem` intentionally **does not** port this. Reasons:

- The Swift side only needs a tiny hand-written surface: an `@_cdecl` bridge per exported function, plus a CRuby ext that calls `rb_define_singleton_method`, `StringValueCStr`, and `rb_utf8_str_new_cstr` — typically ~30 lines combined for a single-method gem.
- There is no Swift equivalent of cgo's Go-runtime ↔ C-runtime friction that `ruby_h_to_go` is built to absorb. `@_cdecl` already gives Swift a stable C ABI symbol; once that exists, the rest is plain ANSI C against `ruby.h`.
- Auto-generating that small a surface would cost more in template / generator maintenance than it would save in keystrokes per gem.

The current trade-off is: the scaffold gives you a working `Bridge.swift` + `<gem>.c` template you edit by hand, exactly like [`jakeoeding/swift-gem-poc`](https://github.com/jakeoeding/swift-gem-poc). If a third consumer of `swift_gem` ever needs a noticeably wider Swift surface, the decision will be revisited.

## Acknowledgments

The architecture of this gem is the union of three pieces of prior work.

### [@sue445](https://github.com/sue445) — Ruby × native-extension framework

- ["Building Ruby native extensions in Go" (RubyKaigi 2025)](https://rubykaigi.org/2025/presentations/sue445.html)
- [ruby-go-gem/go-gem-wrapper](https://github.com/ruby-go-gem/go-gem-wrapper/tree/main/_gem) (`go_gem`)

The mkmf-shim shape (`create_swift_makefile` appends linker flags, then delegates to standard `create_makefile`) and the `Rake::ExtensionTask`-driven dev loop are direct ports of `go_gem`'s patterns. The Swift version swaps `go build -buildmode=c-shared` for `swift build -c release --package-path` plus an SPM `.dynamic` library.

### [@sussan0416](https://github.com/sussan0416) — Ruby × Swift bridge

- ["RubyからSwiftを呼ぶ" Tram LT, 2026-04-25](https://www.docswell.com/s/sussan0416/K7NG3W-2026-04-25-Tram-LT)

This LT walked through the Swift-side recipe that the scaffold encodes:

- `@_cdecl("…")` to expose a Swift function with a stable C ABI symbol
- `strdup(…)` on the Swift side to return a heap-allocated C string the caller owns
- a paired `*_free` function so the caller can release that buffer deterministically

`swift_gem` exists because hearing this LT made it obvious that sue445's mkmf framework on the Ruby side and sussan0416's `@_cdecl` + `strdup`/`free` pair on the Swift side could be combined into one scaffold. The LT itself uses `FFI` + `FFI::AutoPointer` on the Ruby side; this gem reuses the Swift half but routes through a CRuby native ext for tighter memory ownership (see *Memory model* above).

### Structural reference

- [jakeoeding/swift-gem-poc](https://github.com/jakeoeding/swift-gem-poc) — concrete reference layout for the by-hand `Bridge.swift` + `<gem>.c` pair the scaffold emits.

## License

MIT.
