# frozen_string_literal: true

require "test_helper"

class SwiftGemTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::SwiftGem.const_defined?(:VERSION)
    end
  end
end
