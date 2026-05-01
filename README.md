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

## Acknowledgments

The architecture of this gem is modeled after the work of [@sue445](https://github.com/sue445):

- ["Building Ruby native extensions in Go" (RubyKaigi 2025)](https://rubykaigi.org/2025/presentations/sue445.html) — the talk that demonstrated how to ship CRuby native extensions whose implementation lives in another language behind an `@_cdecl`-style C bridge.
- [ruby-go-gem/go-gem-wrapper](https://github.com/ruby-go-gem/go-gem-wrapper/tree/main/_gem) (`go_gem`) — `swift_gem` borrows directly from this framework's pattern: an mkmf shim that appends linker flags before delegating to `create_makefile`, and a `Rake::ExtensionTask`-based dev loop. The Swift version replaces `go build -buildmode=c-shared` with `swift build -c release --package-path` and an SPM `.dynamic` library.

`ruby_h_to_go`-style binding generation is intentionally **not** ported; consumers write the C bridge by hand, the same way `jakeoeding/swift-gem-poc` does.

## License

MIT.
