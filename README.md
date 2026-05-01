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

```bash
swift_gem new rb-foo-mac
```

Creates `./rb-foo-mac/` with a complete swift-gem skeleton (gemspec, Gemfile, Rakefile, lib/, ext/, examples/, test/). Naming transforms strip a leading `rb-` and produce a single top-level `FooMac` module (per the `rb-skypemac` convention).

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

## License

MIT.
