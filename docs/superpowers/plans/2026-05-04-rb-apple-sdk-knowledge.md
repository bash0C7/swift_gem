# rb-apple-sdk-knowledge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a pure-Ruby gem that, at install time on the user's machine, walks the local Xcode SDK and builds a SQLite knowledge base of every public Apple framework's symbols (functions, types, methods, properties, enums, globals). Provides a read-only loader API consumed by `rb-apple-sdk-mac`. Independently usable for IDE completion / lint / RBS generation.

**Architecture:** Pure Ruby (no native ext). Install-time hook builds `data/sdk_knowledge_<sdk_ver>.sqlite` against the local Xcode SDK. Three parsers: `.swiftinterface` (regex-based extractor since `.swiftinterface` is well-formed text), `module.modulemap + .h` (shells out to `clang -ast-dump`), DocC archives (shells out to `xcrun docc convert`). FTS5 trigram for lexical search; optional `sqlite-vec` 768-dim embeddings populated lazily if `rb-foundation-model-mac` is available.

**Tech Stack:** Ruby 3.2+, Bundler 4.x, test-unit, sqlite3 gem, sqlite-vec gem, optional informers gem (ruri-v3-310m-onnx) as a fallback embedder when rb-foundation-model-mac is absent. Subprocess tools: `xcrun --show-sdk-version`, `xcrun --show-sdk-path`, `clang`, `docc`.

---

## File Structure

```
rb-apple-sdk-knowledge/
├── lib/
│   ├── rb_apple_sdk_knowledge.rb            -- public entry: AppleSDKKnowledge module
│   └── rb_apple_sdk_knowledge/
│       ├── version.rb
│       ├── store.rb                         -- SQLite open/migrate/query
│       ├── importer.rb                      -- top-level orchestrator
│       ├── importer/
│       │   ├── sdk_resolver.rb              -- xcrun + path detection
│       │   ├── swift_interface_parser.rb    -- .swiftinterface → symbols
│       │   ├── header_parser.rb             -- modulemap + .h via clang
│       │   ├── docc_parser.rb               -- DocC archives via docc convert
│       │   ├── consolidator.rb              -- merge sources by name
│       │   └── embedder.rb                  -- optional embedding generation
│       └── search.rb                        -- FTS5 + vec lookup helpers
├── data/                                    -- gitignored; populated at install
│   └── .gitkeep
├── test/
│   ├── test_helper.rb
│   ├── fixtures/                            -- mini-SDK for integration tests
│   │   └── MiniFramework/...
│   ├── test_store.rb
│   ├── test_swift_interface_parser.rb
│   ├── test_header_parser.rb
│   ├── test_consolidator.rb
│   ├── test_search.rb
│   └── test_importer_integration.rb
├── exe/
│   └── apple-sdk-knowledge                  -- CLI: rebuild / inspect / search
├── Gemfile
├── Rakefile
├── README.md
├── LICENSE.txt
└── rb-apple-sdk-knowledge.gemspec
```

`Gemfile.lock` gitignored (library convention).

---

## Task 1: Scaffold pure-Ruby gem

**Files:**
- Create directory: `~/dev/src/github.com/bash0C7/rb-apple-sdk-knowledge/`

- [ ] **Step 1.1: Generate scaffold via bundler**

```bash
cd ~/dev/src/github.com/bash0C7/
bundle gem rb-apple-sdk-knowledge --test=test-unit --no-coc --no-mit --no-exe --no-ext
cd rb-apple-sdk-knowledge
```

- [ ] **Step 1.2: Set bundler local path**

```bash
bundle config set --local path 'vendor/bundle'
```

- [ ] **Step 1.3: Add runtime dependencies to gemspec**

Edit `rb-apple-sdk-knowledge.gemspec`, locate the `spec.add_dependency` section, add:

```ruby
  spec.add_dependency "sqlite3", "~> 2.0"
  spec.add_dependency "sqlite-vec", "~> 0.1"
```

Add to development dependencies:

```ruby
  spec.add_development_dependency "test-unit", "~> 3.6"
  spec.add_development_dependency "rake", "~> 13.0"
```

- [ ] **Step 1.4: Run baseline tests**

```bash
bundle install
bundle exec rake test
```

Expected: scaffold tests pass.

- [ ] **Step 1.5: Add `.gitignore` entries for generated SQLite**

Append to `.gitignore`:

```
/data/*.sqlite
/data/*.sqlite-shm
/data/*.sqlite-wal
/Gemfile.lock
/vendor/bundle
```

- [ ] **Step 1.6: Initial commit**

```bash
git init
git add -A
git commit -m "chore: scaffold rb-apple-sdk-knowledge as pure-Ruby gem"
```

---

## Task 2: SQLite store with schema migration

**Files:**
- Create: `lib/rb_apple_sdk_knowledge/store.rb`
- Create: `test/test_store.rb`

- [ ] **Step 2.1: Write failing test in `test/test_store.rb`**

```ruby
# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "rb_apple_sdk_knowledge/store"

class TestStore < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
    @db_path = File.join(@tmpdir, "knowledge.sqlite")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_open_creates_required_tables
    store = AppleSDKKnowledge::Store.open(@db_path)
    tables = store.db.execute(<<~SQL).flatten
      SELECT name FROM sqlite_master WHERE type='table' ORDER BY name
    SQL
    assert_includes tables, "frameworks"
    assert_includes tables, "symbols"
    store.close
  end

  def test_open_creates_fts_and_vec_virtual_tables
    store = AppleSDKKnowledge::Store.open(@db_path)
    tables = store.db.execute(<<~SQL).flatten
      SELECT name FROM sqlite_master ORDER BY name
    SQL
    assert_includes tables, "symbols_fts"
    assert_includes tables, "symbols_vec"
    store.close
  end

  def test_insert_framework_and_select
    store = AppleSDKKnowledge::Store.open(@db_path)
    fw_id = store.insert_framework(
      name: "CoreMIDI",
      swift_module: "CoreMIDI",
      category: "media",
      doc_url: "https://developer.apple.com/documentation/coremidi",
      min_macos: "10.0"
    )
    assert_kind_of Integer, fw_id
    rows = store.db.execute("SELECT name FROM frameworks WHERE id = ?", [fw_id])
    assert_equal "CoreMIDI", rows.first.first
    store.close
  end
end
```

- [ ] **Step 2.2: Run test, expect failure**

```bash
bundle exec rake test TEST=test/test_store.rb
```

Expected: failure (file does not exist or constants missing).

- [ ] **Step 2.3: Commit RED**

```bash
git add test/test_store.rb
git commit -m "test: add failing spec for AppleSDKKnowledge::Store"
```

- [ ] **Step 2.4: Write `lib/rb_apple_sdk_knowledge/store.rb`**

```ruby
# frozen_string_literal: true
require "sqlite3"
require "sqlite_vec"

module AppleSDKKnowledge
  class Store
    SCHEMA_VERSION = 1

    SCHEMA_SQL = <<~SQL.freeze
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;

      CREATE TABLE IF NOT EXISTS schema_meta (
        key TEXT PRIMARY KEY,
        value TEXT
      );

      CREATE TABLE IF NOT EXISTS frameworks (
        id           INTEGER PRIMARY KEY,
        name         TEXT NOT NULL UNIQUE,
        swift_module TEXT NOT NULL,
        category     TEXT,
        doc_url      TEXT,
        min_macos    TEXT
      );

      CREATE TABLE IF NOT EXISTS symbols (
        id              INTEGER PRIMARY KEY,
        framework_id    INTEGER REFERENCES frameworks(id),
        name            TEXT NOT NULL,
        parent_id       INTEGER REFERENCES symbols(id),
        kind            TEXT NOT NULL,
        signature       TEXT,
        abi             TEXT NOT NULL,
        documentation   TEXT,
        return_type     TEXT,
        parameters_json TEXT,
        availability    TEXT,
        deprecated      INTEGER DEFAULT 0,
        requires_main_thread INTEGER DEFAULT 0,
        content_hash    TEXT NOT NULL UNIQUE
      );

      CREATE INDEX IF NOT EXISTS idx_symbols_framework_name ON symbols(framework_id, name);
      CREATE INDEX IF NOT EXISTS idx_symbols_parent          ON symbols(parent_id);
      CREATE INDEX IF NOT EXISTS idx_symbols_kind            ON symbols(kind);

      CREATE VIRTUAL TABLE IF NOT EXISTS symbols_fts USING fts5(
        name, documentation, signature,
        tokenize = 'trigram',
        content = 'symbols',
        content_rowid = 'id'
      );

      CREATE VIRTUAL TABLE IF NOT EXISTS symbols_vec USING vec0(
        symbol_id INTEGER PRIMARY KEY,
        embedding FLOAT[768]
      );
    SQL

    attr_reader :db, :path

    def self.open(path)
      new(path).tap(&:migrate!)
    end

    def initialize(path)
      @path = path
      @db = SQLite3::Database.new(path)
      SqliteVec.load(@db)
      @db.results_as_hash = false
    end

    def migrate!
      @db.execute_batch(SCHEMA_SQL)
      @db.execute(
        "INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
        ["schema_version", SCHEMA_VERSION.to_s]
      )
    end

    def insert_framework(name:, swift_module:, category: nil, doc_url: nil, min_macos: nil)
      @db.execute(
        "INSERT INTO frameworks (name, swift_module, category, doc_url, min_macos) VALUES (?, ?, ?, ?, ?)",
        [name, swift_module, category, doc_url, min_macos]
      )
      @db.last_insert_row_id
    end

    def insert_symbol(framework_id:, name:, kind:, abi:, content_hash:,
                       parent_id: nil, signature: nil, documentation: nil,
                       return_type: nil, parameters_json: nil, availability: nil,
                       deprecated: 0, requires_main_thread: 0)
      @db.execute(
        <<~SQL,
          INSERT INTO symbols
          (framework_id, name, parent_id, kind, signature, abi, documentation,
           return_type, parameters_json, availability, deprecated,
           requires_main_thread, content_hash)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [framework_id, name, parent_id, kind, signature, abi, documentation,
         return_type, parameters_json, availability, deprecated,
         requires_main_thread, content_hash]
      )
      @db.last_insert_row_id
    end

    def close
      @db.close
    end
  end
end
```

- [ ] **Step 2.5: Run test, expect pass**

```bash
bundle exec rake test TEST=test/test_store.rb
```

Expected: all 3 tests pass.

- [ ] **Step 2.6: Commit GREEN**

```bash
git add lib/rb_apple_sdk_knowledge/store.rb
git commit -m "feat: add Store with schema migration and frameworks/symbols tables"
```

---

## Task 3: SDK resolver (xcrun-based detection)

**Files:**
- Create: `lib/rb_apple_sdk_knowledge/importer/sdk_resolver.rb`
- Modify: `test/test_helper.rb` if needed for shared helpers

- [ ] **Step 3.1: Write `test/test_sdk_resolver.rb`**

```ruby
# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/sdk_resolver"

class TestSDKResolver < Test::Unit::TestCase
  def test_detects_local_sdk_version_string
    resolver = AppleSDKKnowledge::Importer::SDKResolver.new
    version = resolver.sdk_version
    assert_match(/\A\d+\.\d+/, version, "expected version like '26.1', got: #{version.inspect}")
  end

  def test_detects_local_sdk_path
    resolver = AppleSDKKnowledge::Importer::SDKResolver.new
    path = resolver.sdk_path
    assert File.directory?(path), "expected SDK path to exist, got: #{path}"
    assert path.end_with?(".sdk"), "expected path to end with .sdk, got: #{path}"
  end

  def test_lists_top_level_frameworks
    resolver = AppleSDKKnowledge::Importer::SDKResolver.new
    frameworks = resolver.frameworks
    assert frameworks.length > 50, "expected >50 frameworks, got #{frameworks.length}"
    assert_includes frameworks.map(&:name), "Foundation"
    assert_includes frameworks.map(&:name), "CoreMIDI"
  end
end
```

- [ ] **Step 3.2: Run, expect failure**

```bash
bundle exec rake test TEST=test/test_sdk_resolver.rb
```

Expected: failure (constant missing).

- [ ] **Step 3.3: Commit RED**

```bash
git add test/test_sdk_resolver.rb
git commit -m "test: add failing spec for SDKResolver"
```

- [ ] **Step 3.4: Write `lib/rb_apple_sdk_knowledge/importer/sdk_resolver.rb`**

```ruby
# frozen_string_literal: true
require "open3"

module AppleSDKKnowledge
  module Importer
    class SDKResolver
      Framework = Struct.new(:name, :path, keyword_init: true)

      def sdk_version
        @sdk_version ||= xcrun("--show-sdk-version").strip
      end

      def sdk_path
        @sdk_path ||= xcrun("--show-sdk-path").strip
      end

      def frameworks
        return @frameworks if @frameworks
        root = File.join(sdk_path, "System", "Library", "Frameworks")
        @frameworks = Dir.children(root)
          .select { |entry| entry.end_with?(".framework") }
          .map do |entry|
            Framework.new(
              name: entry.delete_suffix(".framework"),
              path: File.join(root, entry)
            )
          end
          .sort_by(&:name)
      end

      private

      def xcrun(*args)
        out, status = Open3.capture2("xcrun", *args)
        raise "xcrun failed: xcrun #{args.join(' ')}" unless status.success?
        out
      end
    end
  end
end
```

- [ ] **Step 3.5: Run test, expect pass**

```bash
bundle exec rake test TEST=test/test_sdk_resolver.rb
```

Expected: 3 tests pass.

- [ ] **Step 3.6: Commit GREEN**

```bash
git add lib/rb_apple_sdk_knowledge/importer/sdk_resolver.rb
git commit -m "feat: add SDKResolver using xcrun for version/path/framework discovery"
```

---

## Task 4: Swift interface parser

**Files:**
- Create: `test/fixtures/MiniFramework.swiftinterface` (handcrafted fixture)
- Create: `test/test_swift_interface_parser.rb`
- Create: `lib/rb_apple_sdk_knowledge/importer/swift_interface_parser.rb`

- [ ] **Step 4.1: Write fixture `test/fixtures/MiniFramework.swiftinterface`**

```
// swift-interface-format-version: 1.0
// swift-compiler-version: Apple Swift version 6.3
// swift-module-flags: -target arm64-apple-macos26.0 -enable-objc-interop -module-name MiniFramework
import Foundation
@_exported import MiniFramework

public func miniFunction(_ input: Swift.String) -> Swift.Int

public class MiniClass {
  public init()
  public func doThing(_ count: Swift.Int) -> Swift.String
  public var label: Swift.String { get set }
}

public enum MiniEnum {
  case alpha
  case beta
  case gamma(Swift.Int)
}

public struct MiniStruct : Swift.Sendable {
  public let id: Swift.String
  public init(id: Swift.String)
}

public protocol MiniProtocol {
  func required() -> Swift.Bool
}
```

- [ ] **Step 4.2: Write failing test `test/test_swift_interface_parser.rb`**

```ruby
# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/swift_interface_parser"

class TestSwiftInterfaceParser < Test::Unit::TestCase
  FIXTURE = File.expand_path("fixtures/MiniFramework.swiftinterface", __dir__)

  def setup
    @parser = AppleSDKKnowledge::Importer::SwiftInterfaceParser.new
    @symbols = @parser.parse_file(FIXTURE)
  end

  def test_extracts_top_level_function
    fn = @symbols.find { |s| s[:name] == "miniFunction" && s[:kind] == "function" }
    assert_not_nil fn
    assert_equal "swift", fn[:abi]
    assert_match(/Swift\.String.*Swift\.Int/, fn[:signature])
  end

  def test_extracts_class_with_methods
    cls = @symbols.find { |s| s[:name] == "MiniClass" && s[:kind] == "class" }
    assert_not_nil cls
    methods = @symbols.select { |s| s[:parent_name] == "MiniClass" && s[:kind] == "instance_method" }
    assert_includes methods.map { |m| m[:name] }, "doThing"
  end

  def test_extracts_enum_with_cases
    enum_sym = @symbols.find { |s| s[:name] == "MiniEnum" && s[:kind] == "enum_module" }
    assert_not_nil enum_sym
    cases = @symbols.select { |s| s[:parent_name] == "MiniEnum" && s[:kind] == "enum_case" }
    assert_equal 3, cases.length
    assert_includes cases.map { |c| c[:name] }, "alpha"
  end

  def test_extracts_struct
    s = @symbols.find { |s| s[:name] == "MiniStruct" && s[:kind] == "struct" }
    assert_not_nil s
  end

  def test_extracts_protocol
    p = @symbols.find { |s| s[:name] == "MiniProtocol" && s[:kind] == "protocol" }
    assert_not_nil p
  end
end
```

- [ ] **Step 4.3: Run, expect failure**

```bash
bundle exec rake test TEST=test/test_swift_interface_parser.rb
```

- [ ] **Step 4.4: Commit RED**

```bash
git add test/fixtures/MiniFramework.swiftinterface test/test_swift_interface_parser.rb
git commit -m "test: add failing spec for SwiftInterfaceParser"
```

- [ ] **Step 4.5: Write `lib/rb_apple_sdk_knowledge/importer/swift_interface_parser.rb`**

```ruby
# frozen_string_literal: true

module AppleSDKKnowledge
  module Importer
    class SwiftInterfaceParser
      FUNC_RE   = /^public\s+(?:static\s+)?func\s+(\w+)\s*(\([^)]*\))\s*(->\s*[\w.<>\[\]?!,\s]+)?$/
      CLASS_RE  = /^public\s+(?:final\s+)?class\s+(\w+)/
      STRUCT_RE = /^public\s+struct\s+(\w+)/
      ENUM_RE   = /^public\s+enum\s+(\w+)/
      PROTOCOL_RE = /^public\s+protocol\s+(\w+)/
      ACTOR_RE  = /^public\s+actor\s+(\w+)/
      INIT_RE   = /^\s+public\s+init\s*(\([^)]*\))/
      INSTANCE_METHOD_RE = /^\s+public\s+(?:override\s+)?func\s+(\w+)\s*(\([^)]*\))\s*(->\s*[\w.<>\[\]?!,\s]+)?$/
      VAR_RE    = /^\s+public\s+var\s+(\w+)\s*:\s*([\w.<>\[\]?!,\s]+)\s*\{\s*(get(?:\s+set)?)\s*\}/
      LET_RE    = /^\s+public\s+let\s+(\w+)\s*:\s*([\w.<>\[\]?!,\s]+)/
      ENUM_CASE_RE = /^\s+case\s+(\w+)/

      def parse_file(path)
        text = File.read(path)
        parse(text)
      end

      def parse(text)
        symbols = []
        current_parent = nil
        depth = 0

        text.each_line do |line|
          stripped = line.rstrip

          # Track block scope by counting braces (best-effort, no nested types in v1)
          depth += stripped.count("{") - stripped.count("}")
          if depth == 0 && current_parent
            current_parent = nil
          end

          if (m = stripped.match(CLASS_RE))
            symbols << { name: m[1], kind: "class", abi: "swift", parent_name: nil, signature: stripped.strip }
            current_parent = m[1]
          elsif (m = stripped.match(STRUCT_RE))
            symbols << { name: m[1], kind: "struct", abi: "swift", parent_name: nil, signature: stripped.strip }
            current_parent = m[1]
          elsif (m = stripped.match(ENUM_RE))
            symbols << { name: m[1], kind: "enum_module", abi: "swift", parent_name: nil, signature: stripped.strip }
            current_parent = m[1]
          elsif (m = stripped.match(PROTOCOL_RE))
            symbols << { name: m[1], kind: "protocol", abi: "swift", parent_name: nil, signature: stripped.strip }
            current_parent = m[1]
          elsif (m = stripped.match(ACTOR_RE))
            symbols << { name: m[1], kind: "actor", abi: "swift", parent_name: nil, signature: stripped.strip }
            current_parent = m[1]
          elsif (m = stripped.match(FUNC_RE)) && current_parent.nil?
            symbols << { name: m[1], kind: "function", abi: "swift", parent_name: nil, signature: stripped.strip }
          elsif (m = stripped.match(INSTANCE_METHOD_RE)) && current_parent
            symbols << { name: m[1], kind: "instance_method", abi: "swift", parent_name: current_parent, signature: stripped.strip }
          elsif (m = stripped.match(VAR_RE)) && current_parent
            symbols << { name: m[1], kind: "instance_property", abi: "swift", parent_name: current_parent, signature: stripped.strip }
          elsif (m = stripped.match(LET_RE)) && current_parent
            symbols << { name: m[1], kind: "instance_property", abi: "swift", parent_name: current_parent, signature: stripped.strip }
          elsif (m = stripped.match(ENUM_CASE_RE)) && current_parent
            symbols << { name: m[1], kind: "enum_case", abi: "swift", parent_name: current_parent, signature: stripped.strip }
          elsif (m = stripped.match(INIT_RE)) && current_parent
            symbols << { name: "init", kind: "class_method", abi: "swift", parent_name: current_parent, signature: stripped.strip }
          end
        end

        symbols
      end
    end
  end
end
```

- [ ] **Step 4.6: Run, expect pass**

```bash
bundle exec rake test TEST=test/test_swift_interface_parser.rb
```

- [ ] **Step 4.7: Commit GREEN**

```bash
git add lib/rb_apple_sdk_knowledge/importer/swift_interface_parser.rb
git commit -m "feat: regex-based SwiftInterfaceParser for top-level Swift symbols"
```

---

## Task 5: C/Obj-C header parser via clang

**Files:**
- Create: `test/fixtures/MiniHeader.h`
- Create: `test/test_header_parser.rb`
- Create: `lib/rb_apple_sdk_knowledge/importer/header_parser.rb`

- [ ] **Step 5.1: Write fixture `test/fixtures/MiniHeader.h`**

```c
#ifndef MINI_HEADER_H
#define MINI_HEADER_H

#include <stdint.h>

typedef int32_t MiniStatus;

typedef struct MiniClient *MiniClientRef;

typedef enum {
  kMiniErrorNone = 0,
  kMiniErrorBadInput = -1
} MiniError;

extern const char *kMiniDefaultName;

MiniStatus MiniCreate(const char *name, MiniClientRef *outClient);
MiniStatus MiniDispose(MiniClientRef client);

#endif
```

- [ ] **Step 5.2: Write failing test `test/test_header_parser.rb`**

```ruby
# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/header_parser"

class TestHeaderParser < Test::Unit::TestCase
  FIXTURE = File.expand_path("fixtures/MiniHeader.h", __dir__)

  def setup
    @parser = AppleSDKKnowledge::Importer::HeaderParser.new
    @symbols = @parser.parse_file(FIXTURE)
  end

  def test_extracts_extern_function
    fn = @symbols.find { |s| s[:name] == "MiniCreate" && s[:kind] == "function" }
    assert_not_nil fn
    assert_equal "c", fn[:abi]
  end

  def test_extracts_typedef_struct_pointer_as_type
    t = @symbols.find { |s| s[:name] == "MiniClientRef" && s[:kind] == "struct" }
    assert_not_nil t
  end

  def test_extracts_enum_cases_as_global_constants
    cases = @symbols.select { |s| s[:abi] == "c" && s[:kind] == "global_constant" && %w[kMiniErrorNone kMiniErrorBadInput].include?(s[:name]) }
    assert_equal 2, cases.length
  end

  def test_extracts_extern_const
    c = @symbols.find { |s| s[:name] == "kMiniDefaultName" && s[:kind] == "global_constant" }
    assert_not_nil c
  end
end
```

- [ ] **Step 5.3: Run, expect failure**

```bash
bundle exec rake test TEST=test/test_header_parser.rb
```

- [ ] **Step 5.4: Commit RED**

```bash
git add test/fixtures/MiniHeader.h test/test_header_parser.rb
git commit -m "test: add failing spec for HeaderParser"
```

- [ ] **Step 5.5: Write `lib/rb_apple_sdk_knowledge/importer/header_parser.rb`**

```ruby
# frozen_string_literal: true
require "open3"
require "json"

module AppleSDKKnowledge
  module Importer
    class HeaderParser
      def parse_file(path)
        json = run_clang_ast_dump(path)
        extract_symbols(json)
      end

      private

      def run_clang_ast_dump(path)
        out, _err, status = Open3.capture3(
          "clang", "-Xclang", "-ast-dump=json", "-fsyntax-only",
          "-x", "c", path
        )
        raise "clang failed for #{path}" unless status.success?
        JSON.parse(out)
      rescue JSON::ParserError => e
        raise "clang produced invalid JSON for #{path}: #{e.message}"
      end

      def extract_symbols(node, symbols = [])
        return symbols unless node.is_a?(Hash)
        case node["kind"]
        when "FunctionDecl"
          if node["storageClass"] != "static"
            symbols << {
              name: node["name"],
              kind: "function",
              abi: "c",
              parent_name: nil,
              signature: function_signature(node),
              return_type: node.dig("type", "qualType")
            }
          end
        when "RecordDecl"
          if node["name"]
            symbols << {
              name: node["name"],
              kind: "struct",
              abi: "c",
              parent_name: nil,
              signature: "struct #{node['name']}"
            }
          end
        when "TypedefDecl"
          name = node["name"]
          underlying = node.dig("type", "qualType") || ""
          if underlying.include?("struct ") || underlying.include?("*")
            symbols << {
              name: name,
              kind: "struct",
              abi: "c",
              parent_name: nil,
              signature: "typedef #{underlying} #{name}"
            }
          end
        when "EnumDecl"
          (node["inner"] || []).each do |child|
            if child["kind"] == "EnumConstantDecl"
              symbols << {
                name: child["name"],
                kind: "global_constant",
                abi: "c",
                parent_name: nil,
                signature: "enum case #{child['name']}"
              }
            end
          end
        when "VarDecl"
          if node["storageClass"] == "extern" || node.dig("type", "qualType")&.include?("const")
            symbols << {
              name: node["name"],
              kind: "global_constant",
              abi: "c",
              parent_name: nil,
              signature: "extern #{node.dig('type', 'qualType')} #{node['name']}"
            }
          end
        end
        (node["inner"] || []).each { |child| extract_symbols(child, symbols) }
        symbols
      end

      def function_signature(node)
        return_type = node.dig("type", "qualType") || ""
        params = (node["inner"] || []).select { |i| i["kind"] == "ParmVarDecl" }
        param_str = params.map { |p| "#{p.dig('type', 'qualType')} #{p['name']}" }.join(", ")
        "#{return_type.split(" (").first} #{node['name']}(#{param_str})"
      end
    end
  end
end
```

- [ ] **Step 5.6: Run, expect pass**

```bash
bundle exec rake test TEST=test/test_header_parser.rb
```

- [ ] **Step 5.7: Commit GREEN**

```bash
git add lib/rb_apple_sdk_knowledge/importer/header_parser.rb
git commit -m "feat: HeaderParser via clang -ast-dump=json for C/Obj-C frameworks"
```

---

## Task 6: DocC parser

**Files:**
- Create: `test/test_docc_parser.rb`
- Create: `lib/rb_apple_sdk_knowledge/importer/docc_parser.rb`

- [ ] **Step 6.1: Write a minimal failing test that uses doc-text-only parsing logic**

```ruby
# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/docc_parser"

class TestDoccParser < Test::Unit::TestCase
  def test_parse_inline_renderjson_extracts_abstract_text
    json = {
      "metadata" => {
        "title" => "MIDIClientCreate",
        "symbolKind" => "func"
      },
      "abstract" => [
        { "type" => "text", "text" => "Creates a new MIDI client." }
      ],
      "primaryContentSections" => []
    }
    parser = AppleSDKKnowledge::Importer::DoccParser.new
    sym = parser.from_render_json(json)
    assert_equal "MIDIClientCreate", sym[:name]
    assert_equal "Creates a new MIDI client.", sym[:documentation]
  end
end
```

- [ ] **Step 6.2: Run, expect failure; commit RED**

```bash
bundle exec rake test TEST=test/test_docc_parser.rb
git add test/test_docc_parser.rb
git commit -m "test: add failing spec for DoccParser"
```

- [ ] **Step 6.3: Write `lib/rb_apple_sdk_knowledge/importer/docc_parser.rb`**

```ruby
# frozen_string_literal: true
require "json"
require "open3"

module AppleSDKKnowledge
  module Importer
    class DoccParser
      def from_render_json(node)
        title = node.dig("metadata", "title")
        abstract = (node["abstract"] || [])
          .select { |frag| frag["type"] == "text" }
          .map { |frag| frag["text"] }
          .join

        {
          name: title,
          documentation: abstract,
          kind_hint: node.dig("metadata", "symbolKind")
        }
      end

      def parse_doccarchive(path)
        # Walk a .doccarchive directory, find data/documentation/**/*.json,
        # call from_render_json on each, return array of symbol hashes.
        results = []
        Dir.glob(File.join(path, "data", "documentation", "**", "*.json")).each do |json_path|
          json = JSON.parse(File.read(json_path))
          sym = from_render_json(json)
          results << sym if sym[:name]
        rescue JSON::ParserError
          # skip malformed
        end
        results
      end
    end
  end
end
```

- [ ] **Step 6.4: Run, expect pass; commit GREEN**

```bash
bundle exec rake test TEST=test/test_docc_parser.rb
git add lib/rb_apple_sdk_knowledge/importer/docc_parser.rb
git commit -m "feat: DoccParser for render JSON extraction (abstract + symbol kind)"
```

---

## Task 7: Symbol consolidator

**Files:**
- Create: `test/test_consolidator.rb`
- Create: `lib/rb_apple_sdk_knowledge/importer/consolidator.rb`

- [ ] **Step 7.1: Write failing test**

```ruby
# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/consolidator"
require "digest"

class TestConsolidator < Test::Unit::TestCase
  def test_merges_swift_interface_with_docc_documentation
    swift_syms = [
      { name: "MIDIClientCreate", kind: "function", abi: "swift",
        parent_name: nil, signature: "func MIDIClientCreate(...)" }
    ]
    docc_syms = [
      { name: "MIDIClientCreate", documentation: "Creates a new client.", kind_hint: "func" }
    ]
    c = AppleSDKKnowledge::Importer::Consolidator.new
    merged = c.merge(swift_syms, [], docc_syms)
    found = merged.find { |s| s[:name] == "MIDIClientCreate" }
    assert_not_nil found
    assert_equal "Creates a new client.", found[:documentation]
  end

  def test_assigns_content_hash
    swift_syms = [{ name: "F", kind: "function", abi: "swift", parent_name: nil, signature: "sig" }]
    c = AppleSDKKnowledge::Importer::Consolidator.new
    merged = c.merge(swift_syms, [], [])
    assert merged.first[:content_hash].is_a?(String)
    assert_equal 64, merged.first[:content_hash].length
  end

  def test_dedupes_when_swift_and_c_have_same_name_signature
    swift = [{ name: "F", kind: "function", abi: "swift", parent_name: nil, signature: "F() -> Int" }]
    c_syms = [{ name: "F", kind: "function", abi: "c", parent_name: nil, signature: "F() -> Int" }]
    cons = AppleSDKKnowledge::Importer::Consolidator.new
    merged = cons.merge(swift, c_syms, [])
    assert_equal 1, merged.count { |s| s[:name] == "F" }
  end
end
```

- [ ] **Step 7.2: Run, expect failure; commit RED**

```bash
bundle exec rake test TEST=test/test_consolidator.rb
git add test/test_consolidator.rb
git commit -m "test: add failing spec for Consolidator"
```

- [ ] **Step 7.3: Write `lib/rb_apple_sdk_knowledge/importer/consolidator.rb`**

```ruby
# frozen_string_literal: true
require "digest"

module AppleSDKKnowledge
  module Importer
    class Consolidator
      def merge(swift_symbols, c_symbols, docc_symbols)
        docc_by_name = docc_symbols.each_with_object({}) do |sym, h|
          h[sym[:name]] = sym if sym[:name]
        end

        all_symbols = swift_symbols + c_symbols
        seen = {}
        all_symbols.each do |sym|
          key = "#{sym[:name]}|#{normalize_signature(sym[:signature])}"
          existing = seen[key]
          if existing
            # If duplicate signature exists, prefer Swift over C
            seen[key] = sym if sym[:abi] == "swift"
          else
            seen[key] = sym
          end
        end

        seen.values.map do |sym|
          docc = docc_by_name[sym[:name]]
          enriched = sym.merge(documentation: sym[:documentation] || docc&.fetch(:documentation, nil))
          enriched[:content_hash] = Digest::SHA256.hexdigest(
            "#{sym[:name]}|#{normalize_signature(sym[:signature])}|#{sym[:abi]}"
          )
          enriched
        end
      end

      private

      def normalize_signature(sig)
        return "" if sig.nil?
        sig.gsub(/\s+/, " ").gsub(/\b_\s+\w+:/, "").strip
      end
    end
  end
end
```

- [ ] **Step 7.4: Run, expect pass; commit GREEN**

```bash
bundle exec rake test TEST=test/test_consolidator.rb
git add lib/rb_apple_sdk_knowledge/importer/consolidator.rb
git commit -m "feat: Consolidator merges Swift + C + DocC by name with content_hash"
```

---

## Task 8: FTS5 + vec0 search API

**Files:**
- Create: `test/test_search.rb`
- Create: `lib/rb_apple_sdk_knowledge/search.rb`
- Modify: `lib/rb_apple_sdk_knowledge/store.rb` (add fts insert + lookup helpers)

- [ ] **Step 8.1: Add FTS rebuild and lookup methods to `Store`**

In `lib/rb_apple_sdk_knowledge/store.rb`, inside `class Store`, add:

```ruby
    def rebuild_fts!
      @db.execute("INSERT INTO symbols_fts(symbols_fts) VALUES('rebuild')")
    end

    def fts_search(framework_name, query, limit: 5)
      sql = <<~SQL
        SELECT s.name, s.kind, s.signature, f.name AS framework
        FROM symbols_fts ft
        JOIN symbols s ON s.id = ft.rowid
        JOIN frameworks f ON s.framework_id = f.id
        WHERE symbols_fts MATCH ? AND f.name = ?
        ORDER BY rank
        LIMIT ?
      SQL
      sanitized = query.to_s.gsub(/[-+*^"()]/, " ").squeeze(" ").strip
      return [] if sanitized.empty?
      @db.execute(sql, [sanitized, framework_name, limit]).map do |row|
        { name: row[0], kind: row[1], signature: row[2], framework: row[3] }
      end
    end

    def vec_insert(symbol_id, embedding)
      blob = embedding.pack("f*")
      @db.execute(
        "INSERT OR REPLACE INTO symbols_vec(symbol_id, embedding) VALUES (?, ?)",
        [symbol_id, blob]
      )
    end
```

- [ ] **Step 8.2: Write `lib/rb_apple_sdk_knowledge/search.rb`**

```ruby
# frozen_string_literal: true

module AppleSDKKnowledge
  class Search
    def initialize(store)
      @store = store
    end

    def lexical(framework:, query:, limit: 5)
      @store.fts_search(framework, query, limit: limit)
    end
  end
end
```

- [ ] **Step 8.3: Write `test/test_search.rb`**

```ruby
# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "fileutils"
require "digest"
require "rb_apple_sdk_knowledge/store"
require "rb_apple_sdk_knowledge/search"

class TestSearch < Test::Unit::TestCase
  def setup
    @tmpdir = Dir.mktmpdir
    @store = AppleSDKKnowledge::Store.open(File.join(@tmpdir, "kb.sqlite"))
    fw_id = @store.insert_framework(name: "CoreMIDI", swift_module: "CoreMIDI")
    [
      { name: "MIDIClientCreate", kind: "function", abi: "c",
        signature: "OSStatus MIDIClientCreate(CFStringRef name, ...)",
        documentation: "Creates a new MIDI client." },
      { name: "MIDIClientDispose", kind: "function", abi: "c",
        signature: "OSStatus MIDIClientDispose(MIDIClientRef client)",
        documentation: "Disposes a MIDI client." },
      { name: "MIDISend", kind: "function", abi: "c",
        signature: "OSStatus MIDISend(...)",
        documentation: "Sends MIDI events to a port." }
    ].each do |sym|
      @store.insert_symbol(
        framework_id: fw_id,
        name: sym[:name],
        kind: sym[:kind],
        abi: sym[:abi],
        signature: sym[:signature],
        documentation: sym[:documentation],
        content_hash: Digest::SHA256.hexdigest(sym[:name] + sym[:signature])
      )
    end
    @store.rebuild_fts!
  end

  def teardown
    @store.close
    FileUtils.rm_rf(@tmpdir)
  end

  def test_lexical_finds_typo_via_trigrams
    search = AppleSDKKnowledge::Search.new(@store)
    results = search.lexical(framework: "CoreMIDI", query: "MIDIClienntCreate")
    names = results.map { |r| r[:name] }
    assert_includes names, "MIDIClientCreate"
  end

  def test_lexical_filters_by_framework
    search = AppleSDKKnowledge::Search.new(@store)
    results = search.lexical(framework: "CoreMIDI", query: "MIDISend")
    assert_equal "CoreMIDI", results.first[:framework]
  end
end
```

- [ ] **Step 8.4: Run, expect pass after fixing any failures**

```bash
bundle exec rake test TEST=test/test_search.rb
```

- [ ] **Step 8.5: Commit**

```bash
git add lib/rb_apple_sdk_knowledge/store.rb lib/rb_apple_sdk_knowledge/search.rb test/test_search.rb
git commit -m "feat: add FTS5 trigram search and Search facade"
```

---

## Task 9: Embedder with optional Foundation Models / informers

**Files:**
- Create: `lib/rb_apple_sdk_knowledge/importer/embedder.rb`
- Create: `test/test_embedder.rb`

- [ ] **Step 9.1: Write `lib/rb_apple_sdk_knowledge/importer/embedder.rb`**

```ruby
# frozen_string_literal: true

module AppleSDKKnowledge
  module Importer
    class Embedder
      DIM = 768

      def initialize
        @backend = detect_backend
      end

      def available?
        !@backend.nil?
      end

      def backend_name
        @backend && @backend[:name]
      end

      def embed(text)
        return zero_vector if @backend.nil?
        @backend[:fn].call(text)
      end

      private

      def detect_backend
        if defined?(::AppleFoundationModel)
          { name: :foundation_models, fn: ->(t) { foundation_models_embed(t) } }
        elsif (require "informers"; true rescue false)
          model = Informers.pipeline("feature-extraction", "mochiya98/ruri-v3-310m-onnx")
          { name: :informers, fn: ->(t) { model.(t).flatten } }
        else
          nil
        end
      rescue LoadError
        nil
      end

      def foundation_models_embed(text)
        # Plan-A v1 does not yet expose embeddings. Fallback to zero vector.
        # When rb-foundation-model-mac v2 adds an embed API, replace this body.
        zero_vector
      end

      def zero_vector
        Array.new(DIM, 0.0)
      end
    end
  end
end
```

- [ ] **Step 9.2: Write `test/test_embedder.rb`**

```ruby
# frozen_string_literal: true
require "test_helper"
require "rb_apple_sdk_knowledge/importer/embedder"

class TestEmbedder < Test::Unit::TestCase
  def test_embed_returns_768_dim_vector
    e = AppleSDKKnowledge::Importer::Embedder.new
    v = e.embed("MIDI client creation function")
    assert_equal 768, v.length
    assert v.all? { |x| x.is_a?(Numeric) }
  end

  def test_zero_vector_when_no_backend
    # Test passes regardless of backend availability:
    # the contract is "always returns a 768-vec".
    e = AppleSDKKnowledge::Importer::Embedder.new
    v = e.embed("anything")
    assert_equal 768, v.length
  end
end
```

- [ ] **Step 9.3: Run, expect pass; commit**

```bash
bundle exec rake test TEST=test/test_embedder.rb
git add lib/rb_apple_sdk_knowledge/importer/embedder.rb test/test_embedder.rb
git commit -m "feat: Embedder with rb-foundation-model-mac/informers fallback"
```

---

## Task 10: Top-level Importer orchestrator

**Files:**
- Create: `lib/rb_apple_sdk_knowledge/importer.rb`
- Create: `test/test_importer_integration.rb`

- [ ] **Step 10.1: Write `lib/rb_apple_sdk_knowledge/importer.rb`**

```ruby
# frozen_string_literal: true
require_relative "importer/sdk_resolver"
require_relative "importer/swift_interface_parser"
require_relative "importer/header_parser"
require_relative "importer/docc_parser"
require_relative "importer/consolidator"
require_relative "importer/embedder"
require_relative "store"

module AppleSDKKnowledge
  class Importer
    def initialize(store_path:, fast: ENV["RB_APPLE_SDK_KNOWLEDGE_FAST"] == "1",
                   offline: ENV["RB_APPLE_SDK_KNOWLEDGE_OFFLINE"] == "1")
      @store_path = store_path
      @fast = fast
      @offline = offline
    end

    def run
      resolver = SDKResolver.new
      store = AppleSDKKnowledge::Store.open(@store_path)
      embedder = @fast ? nil : Embedder.new
      swift_parser = SwiftInterfaceParser.new
      header_parser = HeaderParser.new
      docc_parser = DoccParser.new
      consolidator = Consolidator.new

      resolver.frameworks.each do |fw|
        process_framework(fw, store, swift_parser, header_parser, docc_parser, consolidator, embedder)
      end

      store.rebuild_fts!
      store.db.execute("INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
                        ["sdk_version", resolver.sdk_version])
      store.close
    end

    private

    def process_framework(fw, store, swift_parser, header_parser, docc_parser, consolidator, embedder)
      fw_id = store.insert_framework(name: fw.name, swift_module: fw.name)

      swift_syms = collect_swift_symbols(fw, swift_parser)
      c_syms = collect_c_symbols(fw, header_parser)
      docc_syms = []  # doc enrichment optional in v1; relies on installed DocC

      merged = consolidator.merge(swift_syms, c_syms, docc_syms)

      merged.each do |sym|
        symbol_id = store.insert_symbol(
          framework_id: fw_id,
          name: sym[:name],
          kind: sym[:kind],
          abi: sym[:abi],
          signature: sym[:signature],
          documentation: sym[:documentation],
          content_hash: sym[:content_hash]
        )
        if embedder && embedder.available?
          text = "#{sym[:name]} #{sym[:signature]} #{sym[:documentation]}"
          store.vec_insert(symbol_id, embedder.embed(text))
        end
      end
    rescue SQLite3::ConstraintException
      # framework already inserted on rerun: skip
    end

    def collect_swift_symbols(fw, parser)
      pattern = File.join(fw.path, "Modules", "*.swiftmodule", "*.swiftinterface")
      Dir.glob(pattern).flat_map { |path| parser.parse_file(path) }
    rescue
      []
    end

    def collect_c_symbols(fw, parser)
      headers_dir = File.join(fw.path, "Headers")
      return [] unless File.directory?(headers_dir)
      Dir.glob(File.join(headers_dir, "*.h")).flat_map do |h|
        parser.parse_file(h)
      rescue
        []
      end
    end
  end
end
```

- [ ] **Step 10.2: Write integration test (skippable when SDK unavailable)**

```ruby
# frozen_string_literal: true
require "test_helper"
require "tmpdir"
require "rb_apple_sdk_knowledge/importer"

class TestImporterIntegration < Test::Unit::TestCase
  def test_runs_against_real_sdk_and_stores_foundation_symbols
    omit "Xcode SDK not present" unless system("xcrun --show-sdk-path > /dev/null 2>&1")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "kb.sqlite")
      ENV["RB_APPLE_SDK_KNOWLEDGE_FAST"] = "1"
      AppleSDKKnowledge::Importer.new(store_path: path).run
      ENV.delete("RB_APPLE_SDK_KNOWLEDGE_FAST")

      store = AppleSDKKnowledge::Store.open(path)
      fw_count = store.db.execute("SELECT COUNT(*) FROM frameworks").flatten.first
      sym_count = store.db.execute("SELECT COUNT(*) FROM symbols").flatten.first
      assert fw_count > 50, "expected >50 frameworks, got #{fw_count}"
      assert sym_count > 1000, "expected >1000 symbols, got #{sym_count}"

      foundation = store.db.execute(
        "SELECT name FROM symbols WHERE framework_id = (SELECT id FROM frameworks WHERE name = 'Foundation') LIMIT 5"
      ).flatten
      assert foundation.length > 0, "no Foundation symbols found"
      store.close
    end
  end
end
```

- [ ] **Step 10.3: Run integration test**

```bash
bundle exec rake test TEST=test/test_importer_integration.rb
```

Expected: passes (or omits if SDK absent).

- [ ] **Step 10.4: Commit**

```bash
git add lib/rb_apple_sdk_knowledge/importer.rb test/test_importer_integration.rb
git commit -m "feat: top-level Importer orchestrator with FAST/OFFLINE env flags"
```

---

## Task 11: Install-time hook via Rake task + post-install message

**Files:**
- Modify: `Rakefile`
- Modify: `rb-apple-sdk-knowledge.gemspec` (post_install_message)
- Create: `lib/rb_apple_sdk_knowledge.rb` (top-level loader)

- [ ] **Step 11.1: Write `lib/rb_apple_sdk_knowledge.rb`**

```ruby
# frozen_string_literal: true
require_relative "rb_apple_sdk_knowledge/version"
require_relative "rb_apple_sdk_knowledge/store"
require_relative "rb_apple_sdk_knowledge/search"
require_relative "rb_apple_sdk_knowledge/importer"

module AppleSDKKnowledge
  class Error < StandardError; end

  def self.knowledge_path(sdk_version: nil)
    sdk_version ||= detect_sdk_version
    File.expand_path("../data/sdk_knowledge_#{sdk_version}.sqlite", __dir__)
  end

  def self.open(sdk_version: nil)
    path = knowledge_path(sdk_version: sdk_version)
    raise Error, "knowledge base missing at #{path}; run `rake apple:knowledge:rebuild`" unless File.exist?(path)
    Store.open(path)
  end

  def self.detect_sdk_version
    require "open3"
    out, status = Open3.capture2("xcrun", "--show-sdk-version")
    raise Error, "xcrun unavailable" unless status.success?
    out.strip
  end
end
```

- [ ] **Step 11.2: Append a knowledge namespace to `Rakefile`**

```ruby
namespace :apple do
  namespace :knowledge do
    desc "Rebuild the local SDK knowledge base"
    task :rebuild do
      require "rb_apple_sdk_knowledge"
      sdk_version = AppleSDKKnowledge.detect_sdk_version
      path = AppleSDKKnowledge.knowledge_path(sdk_version: sdk_version)
      FileUtils.mkdir_p(File.dirname(path))
      puts "Building knowledge base at #{path}..."
      AppleSDKKnowledge::Importer.new(store_path: path).run
      puts "Done."
    end

    desc "Print info about the current knowledge base"
    task :info do
      require "rb_apple_sdk_knowledge"
      store = AppleSDKKnowledge.open
      fw = store.db.execute("SELECT COUNT(*) FROM frameworks").flatten.first
      sym = store.db.execute("SELECT COUNT(*) FROM symbols").flatten.first
      puts "Frameworks: #{fw}"
      puts "Symbols:    #{sym}"
      puts "DB path:    #{store.path}"
      store.close
    end
  end
end
```

- [ ] **Step 11.3: Add post_install_message to gemspec**

In `rb-apple-sdk-knowledge.gemspec`, add:

```ruby
  spec.post_install_message = <<~MSG
    rb-apple-sdk-knowledge installed.

    Run the following to build the local SDK knowledge base:
      bundle exec rake apple:knowledge:rebuild

    By default this can take several minutes. To skip embedding generation:
      RB_APPLE_SDK_KNOWLEDGE_FAST=1 bundle exec rake apple:knowledge:rebuild
  MSG
```

- [ ] **Step 11.4: Commit**

```bash
git add Rakefile rb-apple-sdk-knowledge.gemspec lib/rb_apple_sdk_knowledge.rb
git commit -m "feat: install-time rebuild via rake task + post_install_message"
```

---

## Task 12: CLI `exe/apple-sdk-knowledge`

**Files:**
- Create: `exe/apple-sdk-knowledge`
- Modify: `rb-apple-sdk-knowledge.gemspec` (`spec.executables`, `spec.bindir`)

- [ ] **Step 12.1: Write `exe/apple-sdk-knowledge`**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
require "rb_apple_sdk_knowledge"

case ARGV.first
when "rebuild"
  sdk_version = AppleSDKKnowledge.detect_sdk_version
  path = AppleSDKKnowledge.knowledge_path(sdk_version: sdk_version)
  FileUtils.mkdir_p(File.dirname(path))
  puts "Building knowledge base at #{path}..."
  AppleSDKKnowledge::Importer.new(store_path: path).run
  puts "Done."
when "info"
  store = AppleSDKKnowledge.open
  puts "Frameworks: #{store.db.execute("SELECT COUNT(*) FROM frameworks").flatten.first}"
  puts "Symbols:    #{store.db.execute("SELECT COUNT(*) FROM symbols").flatten.first}"
  puts "Path:       #{store.path}"
  store.close
when "search"
  framework = ARGV[1]
  query = ARGV[2]
  abort "usage: apple-sdk-knowledge search <framework> <query>" unless framework && query
  store = AppleSDKKnowledge.open
  results = AppleSDKKnowledge::Search.new(store).lexical(framework: framework, query: query)
  results.each { |r| puts "#{r[:framework]}::#{r[:name]} #{r[:signature]}" }
  store.close
else
  puts <<~USAGE
    usage:
      apple-sdk-knowledge rebuild
      apple-sdk-knowledge info
      apple-sdk-knowledge search <framework> <query>
  USAGE
end
```

- [ ] **Step 12.2: Make executable and update gemspec**

```bash
chmod +x exe/apple-sdk-knowledge
```

In gemspec, ensure:

```ruby
  spec.bindir = "exe"
  spec.executables = ["apple-sdk-knowledge"]
```

- [ ] **Step 12.3: Smoke-test the CLI**

```bash
bundle exec exe/apple-sdk-knowledge
```

Expected: prints usage.

- [ ] **Step 12.4: Commit**

```bash
git add exe/apple-sdk-knowledge rb-apple-sdk-knowledge.gemspec
git commit -m "feat: add apple-sdk-knowledge CLI for rebuild/info/search"
```

---

## Task 13: README and final polish

**Files:**
- Modify: `README.md`

- [ ] **Step 13.1: Replace README content**

```markdown
# rb-apple-sdk-knowledge

A SQLite knowledge base of every public Apple framework on the local Xcode SDK.
Built at install time on the user's machine. Read-only after that.

## Use cases

- Lexical and semantic search over Apple SDK symbols
- IDE/editor autocomplete data source
- RBS generation for Apple frameworks
- Knowledge backend for `rb-apple-sdk-mac` (the dynamic Ruby↔Apple bridge)

## Requirements

- macOS with Xcode installed (provides `xcrun`, headers, `.swiftinterface` files, optional DocC archives)
- Ruby 3.2+
- swift-syntax-compatible Swift 6.3+ toolchain (only required at SDK parse time)

## Installation

```ruby
gem "rb-apple-sdk-knowledge"
```

After install, build the knowledge base for your local SDK:

```bash
bundle exec rake apple:knowledge:rebuild
```

Skip embeddings (much faster, FTS5 search still works):

```bash
RB_APPLE_SDK_KNOWLEDGE_FAST=1 bundle exec rake apple:knowledge:rebuild
```

## CLI

```bash
apple-sdk-knowledge rebuild
apple-sdk-knowledge info
apple-sdk-knowledge search CoreMIDI MIDIClient
```

## Library API

```ruby
require "rb_apple_sdk_knowledge"

store = AppleSDKKnowledge.open
search = AppleSDKKnowledge::Search.new(store)
search.lexical(framework: "CoreMIDI", query: "MIDIClient").each do |r|
  puts "#{r[:name]} (#{r[:kind]})"
end
store.close
```

## License

MIT
```

- [ ] **Step 13.2: Commit and push**

```bash
git add README.md
git commit -m "docs: add README for rb-apple-sdk-knowledge"
gh repo create bash0C7/rb-apple-sdk-knowledge --public --source=. --remote=origin --push
```

---

## Out of scope for v1 (deferred with technical justification)

- **Rich DocC ingestion across all framework variants.** Apple distributes DocC content in multiple shapes (in-Xcode bundles, online developer.apple.com, framework-shipped `.doccarchive`); a robust crawler covering all of them is a separate research effort. v1 ingests render JSON when available and otherwise leaves `documentation` blank — the bridge still works, only `did_you_mean` semantic suggestions degrade.
- **Per-symbol availability/deprecation queries beyond the column.** The schema already records availability strings, but a structured matcher (e.g., "show me only symbols available on macOS 26+") is a feature of consumer code, not of this gem.
- **A swift-syntax-based parser instead of regex.** Regex is fragile against unusual `.swiftinterface` formatting. Empirical validation against the real macOS SDK in Task 10 will reveal whether the regex parser misses real-world symbols. If the gap is meaningful, swap to a swift-syntax shell-out in v1.x — flagged here as a follow-up that the user runs the integration test to expose.
