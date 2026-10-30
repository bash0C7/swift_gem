# CLAUDE.md — swift_gem

## Position

A thin framework gem for Ruby ↔ Swift extensions. The Swift counterpart of `ruby-go-gem/go-gem-wrapper`, but the equivalent of `_tools/ruby_h_to_go` (auto-generated bindings) is **intentionally out of scope**. Stays as the minimum glue that connects CRuby native ext + Swift Package Manager + a C bridge through mkmf.

## Core design principles

1. Stay simple. The framework's only jobs are "an mkmf shim into SPM" and "a generator that emits a scaffold." Apple frameworks themselves get linked automatically when consumers `import Vision` etc. in their `Package.swift`; this gem stays out of the way.
2. builder DI. `create_swift_makefile`'s `builder:` lambda lets tests stub the swift toolchain. It returns `[lib_dir, header_dir]`. CI / unit tests don't need swift installed.
3. `source_dir:` is required. Addresses rake-compiler invoking extconf.rb from `tmp/<arch>/<gem>/<ver>/`. The contract is that the caller (extconf.rb) passes `source_dir: __dir__`.
4. Scaffold parity. The skeleton the generator emits matches both bundle gem 4.x conventions and the bash0C7 sibling-repo conventions (`vendor/bundle`, `.bundle/config`, gitignored `Gemfile.lock`). Verify against a real consumer (e.g. rb-vision-mac) by diffing — the only differences should be implementation body, `sig/` contents, example scripts, fixtures, tests, docs, gemspec summary and description, and build artifacts. Helper-subprocess gems (`rb-translation-mac`, `rb-speech-mac`) have no C extension and share only the toolchain conventions: Xcode 27 via `xcrun swift`, DocC, RBS.
5. rake-compiler is the consumer's responsibility. Dropping `Rake::ExtensionTask` into the Rakefile happens in the generated gem. The framework does not enforce it but does ship it in the scaffold.
6. Generated gems are self-contained. `lib/swift_gem/mkmf.rb` is vendored into each generated gem as `ext/<module_path>/swift_mkmf.rb`, and `extconf.rb` loads it with `require_relative`. Generated gems do not depend on swift_gem.

## Architecture

```
swift_gem (this gem)
├── lib/swift_gem/mkmf.rb        ─ create_swift_makefile(target, package:, source_dir:, builder:)
├── lib/swift_gem/generator.rb   ─ Generator.new(gem_name).call(dest_dir:)
├── lib/swift_gem/templates/     ─ templates listed in Generator::TEMPLATES
├── sig/swift_gem.rbs            ─ RBS for the public API
└── Rakefile                     ─ rake "new[gem_name,dest_dir]" wraps Generator; rake test runs rbs validate first

generated gem (e.g. rb-vision-ocrmac)
├── ext/<m>/extconf.rb           ─ require_relative "swift_mkmf" + create_swift_makefile
├── ext/<m>/swift_mkmf.rb        ─ vendored copy of lib/swift_gem/mkmf.rb
├── ext/<m>/Package.swift        ─ SPM .dynamic library (swift-tools-version 6.4, .macOS(.v27))
├── ext/<m>/Sources/<Mod>/*.swift ─ implementation + @c bridge (SE-0495)
├── ext/<m>/<m>.c                ─ CRuby ext (Init_<m>, rb_define_singleton_method)
└── sig/<m>.rbs                  ─ RBS for the generated module
```

`xcrun swift build` writes `<Mod>-Swift.h` under `ext/<m>/.build/out/Intermediates.noindex/GeneratedModuleMaps/`; the C ext includes it through `-I`. The library is linked from `ext/<m>/.build/release`.

## Module boundaries

| Module | Responsibility |
|---|---|
| `SwiftGem::Mkmf` | `create_swift_makefile` calls the builder (default: `xcrun swift build -c release --package-path <dir>`), adds `-I<header_dir>`, `-Wl,-rpath,<lib_dir>`, `-L<lib_dir>`, `-l<package>` (each `Shellwords.escape`d) to `$CFLAGS` / `$LDFLAGS`, then delegates to standard mkmf's `create_makefile` |
| `SwiftGem::Generator` | Naming transforms from gem name (`module_name` / `module_path`); renders ERB templates with `ERB#result_with_hash` into `dest_dir`; copies static templates; vendors `mkmf.rb` |
| `lib/swift_gem/templates/` | Static: `gitignore`, `bundle_config`, `LICENSE.txt`<br>ERB: `gemspec`, `Gemfile`, `Rakefile`, `README.md`, `lib_main.rb`, `lib_version.rb`, `sig_main.rbs`, `ext_Package.swift`, `ext_Sources.swift`, `ext_Bridge.swift`, `ext_main.c`, `ext_extconf.rb`, `examples_cli.swift`, `test_helper.rb`, `test_sample.rb` |
| `Rakefile` `task :new` | `rake "new[gem_name,dest_dir]"`. Wraps Generator; aborts if dest exists and is non-empty. No standalone CLI shipped — clone + `bundle install` + rake is the entry point |

## Naming transform rules

Derived names from the input gem name.

| Derived | Logic | Example (`rb-vision-ocrmac`) | Example (`my_swift_gem`) |
|---|---|---|---|
| `gem_name` | input as-is | `rb-vision-ocrmac` | `my_swift_gem` |
| `module_name` | strip `rb-` prefix + CamelCase the hyphen/underscore split | `VisionOcrmac` | `MySwiftGem` |
| `module_path` | strip `rb-` prefix + hyphen → underscore (snake_case) | `vision_ocrmac` | `my_swift_gem` |
| `c_symbol_prefix` | `module_path + "_"` (template variable) | `vision_ocrmac_` | `my_swift_gem_` |

Adopts the `rb-skypemac` / `rb-appscript` convention: hyphenated gem name + a single top-level Ruby module. Bundle gem's default of nested namespaces (`Rb::Vision::Ocrmac`) is **not adopted**. Generator output does not include `exe/`.

## TDD discipline

- t-wada style: fail first, RED → GREEN → REFACTOR each as an independent commit (per global CLAUDE.md)
- test-unit (not rspec). `bundle exec rake test` (runs `rbs -I sig validate` first)
- mkmf tests: inject a `builder:` stub, assert the resulting Makefile shape without needing swift toolchain
- generator tests: parameterised naming-transform check + asserts on emitted file list and key patterns inside the main files
- Smoke E2E: `bundle exec rake "new[<name>,<dir>]"` followed by `bundle install && bundle exec rake test` in the generated gem is the final acceptance test (run manually, not in CI)

## Related projects

- `~/dev/src/github.com/bash0C7/rb-vision-mac` — first consumer. The Apple Vision Ruby binding. Reference for scaffold-parity verification
- For reference: `ruby-go-gem/go-gem-wrapper` (the Go-side predecessor), `jakeoeding/swift-gem-poc` (the Swift POC; structural template for this gem)

## Environment requirements

- macOS 27+, Apple Silicon (arm64-darwin)
- Xcode 27 (Swift 6.4). Builds run `xcrun swift`; SwiftPM uses its default `swiftbuild` build system with `.dynamic` libraries and `@c` (SE-0495)
- Ruby 4.0+, bundler 4.x, rbs (dev dependency)
- `Gemfile.lock` is library-style: not git-tracked (in `.gitignore`)

## Prohibitions

- No Python source (per global CLAUDE.md)
- No code comments. Swift is documented with DocC (`///`, `- Parameter`, `- Returns`, ``` ``symbol`` ``` links to public symbols only); Ruby is documented with `#` comments above declarations in `sig/*.rbs`. History goes in commit messages
- Do not git-track `Gemfile.lock` (library; the consumer's lock wins)
- Do not reimplement rake-compiler in the framework; leave that to the consumer's Rakefile
- Do not reinvent Bundler's path: resolution; Bundler's stock behavior is enough
- No Swift binding code generation (the equivalent of `ruby_h_to_go`); intentionally out of scope, revisit when a third consumer exists
- Commit messages in English, conventional commits style (per global CLAUDE.md)
- `.claude/` is committed (per global CLAUDE.md)
