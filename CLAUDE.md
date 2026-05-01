# CLAUDE.md — swift_gem

## 位置付け

Ruby ↔ Swift 拡張の **薄いフレームワーク gem**。`ruby-go-gem/go-gem-wrapper` の Swift 版に相当するが、`_tools/ruby_h_to_go` 相当のコード生成（Swift binding 自動生成）は **意図的に scope 外**。CRuby native ext + Swift Package Manager + C bridge の組み合わせを mkmf で繋ぐ最小限の接着剤に徹する。

## 動機

`bash0C7/rb-vision-ocrmac` のような Apple framework (Vision / AVFoundation / NaturalLanguage / Speech / Sound Analysis 等) を Ruby から呼びたい個別 gem を、毎回ゼロから書かずに済ませる。jakeoeding/swift-gem-poc の単一 gem 内に埋め込まれてた定型を framework に外出し。

## 核の設計原則

1. **シンプル徹底**: framework gem の責務は「mkmf を SPM に繋ぐシム」と「scaffold を吐く generator」のみ。Apple framework 自体は consumer の `Package.swift` に `import Vision` 等を書けば勝手に link される、framework は関与しない。
2. **builder DI**: `create_swift_makefile` の `builder:` lambda は swift toolchain を stub できる。CI / unit test では swift 不要。
3. **`source_dir:` 必須**: rake-compiler が extconf.rb を `tmp/<arch>/<gem>/<ver>/` で実行することへの対応。呼び出し側（extconf.rb）から `source_dir: __dir__` を渡してもらう契約。
4. **scaffold 整合性**: generator が吐く skeleton は、bundle gem 4.x の慣習 + bash0C7 sibling repo 慣習 (`vendor/bundle`, `.bundle/config`, `Gemfile.lock` ignore) と一致する。consumer (例: rb-vision-ocrmac) と diff = 期待差分 (実装本体・fixture・ビルド成果物) のみ になることを scaffold check で確認すること。
5. **rake-compiler は consumer 側の責務**: Rakefile に `Rake::ExtensionTask` を仕込むのは generated gem 側。framework は強制しないが scaffold には標準で含める。

## アーキテクチャ

```
swift_gem (この gem)
├── lib/swift_gem/mkmf.rb        ─ create_swift_makefile(target, package:, source_dir:, builder:)
├── lib/swift_gem/generator.rb   ─ Generator(gem_name).call(dest_dir:)
├── lib/swift_gem/templates/     ─ 19 template (静的 6 + ERB 13)
└── exe/swift_gem                 ─ CLI: swift_gem new <gem-name> [--dest DIR]

  ▲ depends on
  │
consumer gem (例: rb-vision-ocrmac)
├── ext/<name>/extconf.rb        ─ require "swift_gem/mkmf" + create_swift_makefile
├── ext/<name>/Package.swift     ─ SPM .dynamic library
├── ext/<name>/Sources/<Mod>/*.swift ─ 実装 + @_cdecl Bridge
└── ext/<name>/<name>.{c,h}      ─ CRuby ext (Init_<name>, rb_define_singleton_method)
```

## モジュール境界

| モジュール | 責務 |
|---|---|
| `SwiftGem::Mkmf` | `create_swift_makefile` で `swift build --package-path <dir>` を実行し、`-Wl,-rpath,<dir>/.build/release` `-L<dir>/.build/release` `-l<package>` を $LDFLAGS に注入してから標準 mkmf の `create_makefile` に委譲 |
| `SwiftGem::Generator` | gem 名から命名 transform (`module_name` / `module_path` / `exe_name`)、ERB テンプレを `dest_dir` に展開、`exe/<name>` に chmod +x |
| `SwiftGem::Generator::Context` | ERB 内で `<%= module_name %>` 等を method として呼べるための binding holder |
| `lib/swift_gem/templates/` | 静的: `gitignore` `bundle_config` `LICENSE.txt`<br>ERB: `gemspec` `Gemfile` `Rakefile` `README.md` `lib_main.rb` `lib_version.rb` `ext_Package.swift` `ext_Sources.swift` `ext_Bridge.swift` `ext_main.c` `ext_main.h` `ext_extconf.rb` `exe_cli` `examples_cli.swift` `test_helper.rb` `test_sample.rb` |
| `exe/swift_gem` | 素 ARGV CLI。`new` サブコマンドのみ。non-empty な `--dest` は refuse |

## 命名 transform 規則

入力 gem 名から生成する 4 つの派生名。

| 派生 | ロジック | 例 (`rb-vision-ocrmac`) | 例 (`my_swift_gem`) |
|---|---|---|---|
| `gem_name` | 入力そのまま | `rb-vision-ocrmac` | `my_swift_gem` |
| `module_name` | `rb-` prefix 除去 + ハイフン/アンダースコア区切りを CamelCase 連結 | `VisionOcrmac` | `MySwiftGem` |
| `module_path` | `rb-` prefix 除去 + ハイフン → アンダースコア (snake_case) | `vision_ocrmac` | `my_swift_gem` |
| `exe_name` | `rb-` prefix 除去 (ハイフンはそのまま) | `vision-ocrmac` | `my_swift_gem` |
| `c_symbol_prefix` | `module_path + "_"` | `vision_ocrmac_` | `my_swift_gem_` |

`rb-skypemac` / `rb-appscript` 慣習 = ハイフン区切り gem 名 + トップレベル単一 module の組み合わせを採用。bundle gem デフォルトのネスト namespace (`Rb::Vision::Ocrmac`) は **不採用**。

## TDD 規律

- **t-wada 式**: fail first、RED → GREEN → REFACTOR の独立 commit (global CLAUDE.md 準拠)
- **test-unit** (rspec ではない)。`bundle exec rake test`
- **mkmf 系 test**: `builder:` を stub に注入して swift toolchain なしで Makefile shape を assert
- **generator 系 test**: 命名 transform のパラメタライズド + ERB 出力ファイル一覧 + 主要ファイルの key pattern を assert
- **smoke E2E**: `bundle exec exe/swift_gem new <name>` → 生成された gem で `bundle install && bundle exec rake test` が通ることを最終 acceptance とする (CI には組み込まず手動で実行)

## 関連プロジェクト

- `~/dev/src/github.com/bash0C7/rb-vision-ocrmac` — 最初の consumer。Apple Vision OCR の Ruby binding。scaffold 整合性検証の reference
- `~/dev/src/github.com/bash0C7/archives_go_jp_searcher` — rb-vision-ocrmac の最初の caller。combat proof の最終段
- 参考: `ruby-go-gem/go-gem-wrapper` (Go 版の先達)、`jakeoeding/swift-gem-poc` (Swift 版 POC、本 gem の構造的雛形)

## 環境依存情報

- macOS 12+ (Vision/AVFoundation 等の最低要件)、Apple Silicon (arm64-darwin) 前提
- Swift 6.0+ (SPM の `.dynamic` library + `@_cdecl` ABI)
- Ruby 3.2+、bundler 4.x (`bundle gem --test=test-unit` 慣習)
- `Gemfile.lock` は library として **track しない** (`.gitignore` 済)

## 禁止事項

- **Python コードを置かない** (global CLAUDE.md)
- **`Gemfile.lock` を git track しない** (library なので consumer の lock を尊重)
- **rake-compiler の代替実装**を framework に組み込まない (consumer の Rakefile に任せる)
- **Bundler の path: 解決ロジックの再発明** (Bundler 標準で十分)
- **ruby_h_to_go 相当の Swift binding コード生成** (POC 段階で scope 外、3 個目 consumer ができる頃に再検討)
- **commit message は英語**、conventional commits 準拠 (global CLAUDE.md)
- **`.claude/` はコミット対象** (global CLAUDE.md)
