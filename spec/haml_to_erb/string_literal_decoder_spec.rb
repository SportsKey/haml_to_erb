# frozen_string_literal: true

require "spec_helper"

RSpec.describe HamlToErb::StringLiteralDecoder do
  describe ".decode" do
    # Builds the Ruby double-quoted string literal Haml produces for
    # interpolated text, e.g. '"（...#{name}...）"'. String#dump escapes the
    # literal text (e.g. non-ASCII to \uXXXX) but, unlike Haml, also escapes the
    # interpolation marker; un-escape it so #{...} stays live like Haml emits it.
    def literal(text)
      text.dump.gsub('\#{', '#{')
    end

    it "decodes \\uXXXX escapes back to the original characters" do
      result = described_class.decode(literal('こんにちは、#{name}。'))
      expect(result).to eq("こんにちは、<%= name %>。")
    end

    it "decodes \\u{...} escapes for characters outside the BMP" do
      result = described_class.decode(literal('🍎 x #{count}'))
      expect(result).to eq("🍎 x <%= count %>")
    end

    it "decodes standard escape sequences (\\n, \\t)" do
      result = described_class.decode(literal("line1\nline2\t" + '#{x}'))
      expect(result).to eq("line1\nline2\t<%= x %>")
    end

    it "decodes escaped quotes and backslashes" do
      result = described_class.decode(literal('say "hi" \\ #{name}'))
      expect(result).to eq('say "hi" \\ <%= name %>')
    end

    it "preserves the interpolation expression verbatim" do
      result = described_class.decode(literal('#{user[:name].upcase}'))
      expect(result).to eq("<%= user[:name].upcase %>")
    end

    it 'treats an escaped \\#{...} as literal text, not interpolation' do
      # The original text contained a literal "#{...}"; String#dump escapes it
      # to "\#{...}", which must not become an ERB tag.
      result = described_class.decode('"price is \\#{amount}"')
      expect(result).to eq('price is #{amount}')
      expect(result).not_to include("<%=")
    end

    it "leaves a plain literal without interpolation as decoded text" do
      result = described_class.decode(literal("こんにちは"))
      expect(result).to eq("こんにちは")
    end
  end
end
