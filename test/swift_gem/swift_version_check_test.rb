# frozen_string_literal: true

require "test_helper"
require "swift_gem/swift_version_check"

class SwiftGemSwiftVersionCheckTest < Test::Unit::TestCase
  Check = SwiftGem::SwiftVersionCheck

  test "parses Apple Swift version line" do
    output = "Apple Swift version 6.3.1 (swift-6.3.1-RELEASE)\nTarget: arm64-apple-macosx15.0\n"
    assert_equal Gem::Version.new("6.3.1"), Check.parse(output)
  end

  test "parses two-segment Swift version" do
    output = "Apple Swift version 6.3 (swiftlang-6.3.0.0)\n"
    assert_equal Gem::Version.new("6.3"), Check.parse(output)
  end

  test "parse returns nil for unrecognized output" do
    assert_nil Check.parse("not a swift version banner")
  end

  test "call! returns version when toolchain is exactly the minimum" do
    prober = -> { "Apple Swift version 6.3 (swift-6.3-RELEASE)\n" }
    assert_equal Gem::Version.new("6.3"), Check.call!(prober: prober)
  end

  test "call! returns version when toolchain is newer than minimum" do
    prober = -> { "Apple Swift version 6.4.2 (swift-6.4.2-RELEASE)\n" }
    assert_equal Gem::Version.new("6.4.2"), Check.call!(prober: prober)
  end

  test "call! raises IncompatibleSwiftVersion when toolchain is older than 6.3" do
    prober = -> { "Apple Swift version 6.2.4 (swiftlang-6.2.4.1.4 clang-1700.6.4.2)\n" }
    error = assert_raise(Check::IncompatibleSwiftVersion) do
      Check.call!(prober: prober)
    end
    assert_match(/6\.3/, error.message)
    assert_match(/6\.2\.4/, error.message)
  end

  test "call! raises IncompatibleSwiftVersion when probe output is unparseable" do
    prober = -> { "swift not found" }
    assert_raise(Check::IncompatibleSwiftVersion) do
      Check.call!(prober: prober)
    end
  end
end
