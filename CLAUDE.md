# CLAUDE.md — swift_gem

## Position

A thin framework gem for Ruby ↔ Swift extensions. The Swift counterpart of `ruby-go-gem/go-gem-wrapper`, but the equivalent of `_tools/ruby_h_to_go` (auto-generated bindings) is **intentionally out of scope**. Stays as the minimum glue that connects CRuby native ext + Swift Package Manager + a C bridge through mkmf.

## Core design principles

1. Stay simple. The framework's only jobs are "an mkmf shim into SPM" and "a generator that emits a scaffold." Apple frameworks themselves get linked automatically when consumers `import Vision` etc. in their `Package.swift`; this gem stays out of the way.
2. builder DI. `create_swift_makefile`'s `builder:` lambda lets tests stub the swift toolchain. CI / unit tests don't need swift installed.
3. `source_dir:` is required. Addresses rake-compiler invoking extconf.rb from `tmp/<arch>/<gem>/<ver>/`. The contract is that the caller (extconf.rb) passes `source_dir: __dir__`.
4. Scaffold parity. The skeleton the generator emits matches both bundle gem 4.x conventions and the bash0C7 sibling-repo conventions (`vendor/bundle`, `.bundle/config`, gitignored `Gemfile.lock`). Verify against a real consumer (e.g. rb-vision-ocrmac) by diffing — the only differences should be implementation body, fixtures, and build artifacts.
5. rake-compiler is the consumer's responsibility. Dropping `Rake::ExtensionTask` into the Rakefile happens in the generated gem. The framework does not enforce it but does ship it in the scaffold.

## Architecture

```
swift_gem (this gem)
├── lib/swift_gem/mkmf.rb        ─ create_swift_makefile(target, package:, source_dir:, builder:)
├── lib/swift_gem/generator.rb   ─ Generator(gem_name).call(dest_dir:)
├── lib/swift_gem/templates/     ─ 18 templates (3 static + 15 ERB)
└── Rakefile                      ─ rake new <gem_name> [dest_dir] wraps Generator

  ▲ depends on
  │
consumer gem (e.g. rb-vision-ocrmac)
├── ext/<name>/extconf.rb        ─ require "swift_gem/mkmf" + create_swift_makefile
├── ext/<name>/Package.swift     ─ SPM .dynamic library
├── ext/<name>/Sources/<Mod>/*.swift ─ implementation + @_cdecl Bridge
└── ext/<name>/<name>.{c,h}      ─ CRuby ext (Init_<name>, rb_define_singleton_method)
```

## Module boundaries

| Module | Responsibility |
|---|---|
| `SwiftGem::Mkmf` | `create_swift_makefile` runs `swift build --package-path <dir>` and injects `-Wl,-rpath,<dir>/.build/release` `-L<dir>/.build/release` `-l<package>` into $LDFLAGS, then delegates to standard mkmf's `create_makefile` |
| `SwiftGem::Generator` | Naming transforms from gem name (`module_name` / `module_path` / `exe_name`); expands ERB templates into `dest_dir` |
| `SwiftGem::Generator::Context` | Binding holder so ERB templates can call `<%= module_name %>` etc. as methods |
| `lib/swift_gem/templates/` | Static: `gitignore`, `bundle_config`, `LICENSE.txt`<br>ERB: `gemspec`, `Gemfile`, `Rakefile`, `README.md`, `lib_main.rb`, `lib_version.rb`, `ext_Package.swift`, `ext_Sources.swift`, `ext_Bridge.swift`, `ext_main.c`, `ext_main.h`, `ext_extconf.rb`, `examples_cli.swift`, `test_helper.rb`, `test_sample.rb` |
| `Rakefile` `task :new` | `rake new <gem_name> [dest_dir]` (positional args read directly from ARGV; each is stubbed as a no-op task so Rake doesn't try to invoke them). Wraps Generator; refuses if dest exists and is non-empty. No standalone CLI shipped — clone + `bundle install` + rake is the entry point |

## Naming transform rules

Four derived names from the input gem name.

| Derived | Logic | Example (`rb-vision-ocrmac`) | Example (`my_swift_gem`) |
|---|---|---|---|
| `gem_name` | input as-is | `rb-vision-ocrmac` | `my_swift_gem` |
| `module_name` | strip `rb-` prefix + CamelCase the hyphen/underscore split | `VisionOcrmac` | `MySwiftGem` |
| `module_path` | strip `rb-` prefix + hyphen → underscore (snake_case) | `vision_ocrmac` | `my_swift_gem` |
| `exe_name` | strip `rb-` prefix (hyphen kept) | `vision-ocrmac` | `my_swift_gem` |
| `c_symbol_prefix` | `module_path + "_"` | `vision_ocrmac_` | `my_swift_gem_` |

Adopts the `rb-skypemac` / `rb-appscript` convention: hyphenated gem name + a single top-level Ruby module. Bundle gem's default of nested namespaces (`Rb::Vision::Ocrmac`) is **not adopted**.

`exe_name` is preserved as a public utility for consumers who want to add a CLI by hand. Generator output itself does not include `exe/`.

## TDD discipline

- t-wada style: fail first, RED → GREEN → REFACTOR each as an independent commit (per global CLAUDE.md)
- test-unit (not rspec). `bundle exec rake test`
- mkmf tests: inject a `builder:` stub, assert the resulting Makefile shape without needing swift toolchain
- generator tests: parameterised naming-transform check + asserts on emitted file list and key patterns inside the main files
- Smoke E2E: `bundle exec rake new <name>` followed by `bundle install && bundle exec rake test` in the generated gem is the final acceptance test (run manually, not in CI)

## Related projects

- `~/dev/src/github.com/bash0C7/rb-vision-ocrmac` — first consumer. The Apple Vision OCR Ruby binding. Reference for scaffold-parity verification
- For reference: `ruby-go-gem/go-gem-wrapper` (the Go-side predecessor), `jakeoeding/swift-gem-poc` (the Swift POC; structural template for this gem)

## Environment requirements

- macOS 12+ (minimum for Vision/AVFoundation etc.), Apple Silicon (arm64-darwin) assumed
- Swift 6.0+ (SPM `.dynamic` library + `@_cdecl` ABI)
- Ruby 3.2+, bundler 4.x (`bundle gem --test=test-unit` convention)
- `Gemfile.lock` is library-style: not git-tracked (in `.gitignore`)

## Prohibitions

- No Python source (per global CLAUDE.md)
- Do not git-track `Gemfile.lock` (library; the consumer's lock wins)
- Do not reimplement rake-compiler in the framework; leave that to the consumer's Rakefile
- Do not reinvent Bundler's path: resolution; Bundler's stock behavior is enough
- No Swift binding code generation (the equivalent of `ruby_h_to_go`); intentionally out of scope, revisit when a third consumer exists
- Commit messages in English, conventional commits style (per global CLAUDE.md)
- `.claude/` is committed (per global CLAUDE.md)
