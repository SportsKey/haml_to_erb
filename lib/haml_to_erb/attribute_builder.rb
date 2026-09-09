# frozen_string_literal: true

require "json"
require_relative "prism_parser"
require_relative "interpolation"

module HamlToErb
  # Builds HTML attribute strings from HAML static and dynamic attributes
  # Single class consolidating parsing, building, and formatting
  class AttributeBuilder
    # HTML5 boolean attributes - presence matters, not value
    BOOLEAN_ATTRIBUTES = %w[
      allowfullscreen async autofocus autoplay checked controls default
      defer disabled formnovalidate hidden inert ismap itemscope loop
      multiple muted nomodule novalidate open playsinline readonly
      required reversed scoped seamless selected
    ].freeze

    # Matches one "key =>" or "key:" pair at the start of a Ruby hash body.
    # The key may be a symbol (:foo), a quoted string ("v-bind:x"), or a bare
    # word (foo). Quoted keys allow any inner character so attribute names with
    # colons, dots, @, etc. (Vue/Angular/Stimulus bindings) parse correctly.
    KEY_PATTERN = /\A\s*(?::(\w+)|(['"])((?:\\.|[^\\])*?)\2|([\w-]+))\s*(?:=>|:)\s*/

    # Keys whose hash value HAML expands into prefixed attributes at render time.
    HASH_ATTRIBUTES = %w[data aria].freeze

    # Expressions that can evaluate to nil or false. hamlit omits such data-*/aria-*
    # values; inline `attr="<%= expr %>"` would emit an empty attribute instead.
    NIL_CAPABLE_NODES = [
      Prism::NilNode, Prism::FalseNode, Prism::IfNode, Prism::UnlessNode,
      Prism::AndNode, Prism::OrNode, Prism::CaseNode
    ].freeze

    def initialize
      @parser = PrismParser.new
      @fragments = []
    end

    # Build a complete HTML attribute string from static and dynamic HAML attributes
    # Returns a string like ' class="foo bar" id="main" href="/path"'
    # obj_ref_attrs: optional hash with class/id from object reference syntax
    def build(static, dynamic, obj_ref_attrs = nil)
      attrs = {}
      class_parts = []
      id_parts = []
      @fragments = []
      @spreads = []
      @dynamic_class = false

      # Static attributes (already parsed by HAML - includes shorthand classes/ids)
      static&.each do |key, value|
        if key == "class"
          class_parts << value
        elsif key == "id"
          id_parts << value
        else
          attrs[key] = "#{key}=\"#{escape_attr(value)}\""
        end
      end

      # Dynamic attributes - parse the Ruby hash and convert to HTML
      if dynamic
        dyn = dynamic.old || dynamic.new
        if dyn && !dyn.empty?
          parse_dynamic(dyn).each do |attr_str|
            if attr_str.start_with?("class=")
              class_parts << extract_quoted_value(attr_str, "class")
            elsif attr_str.start_with?("id=")
              id_parts << extract_quoted_value(attr_str, "id")
            else
              # Conditional booleans (`<%= 'disabled' if ... %>`) have no name to
              # dedupe on; key them uniquely so two on one tag both survive.
              attr_name = attr_str.start_with?("<%") ? "<%#{attrs.size}" : attr_str.split("=").first
              attrs[attr_name] = attr_str
            end
          end
        end
      end

      # Object reference attributes (from %div[@user] syntax)
      if obj_ref_attrs
        class_parts << obj_ref_attrs[:class] if obj_ref_attrs[:class]
        id_parts << obj_ref_attrs[:id] if obj_ref_attrs[:id]
      end

      # A spread hash may carry its own class; hamlit merges it with the tag's classes,
      # whereas a second class attribute would be ignored by the browser. Pull the class
      # out into class_names and hand the rest to tag.attributes.
      if class_parts.any? && @spreads.any?
        @dynamic_class = true
        class_parts.concat(@spreads.map { |expr| "<%= (#{expr}).values_at(:class, \"class\") %>" })
        @fragments.concat(@spreads.map { |expr| "**(#{expr}).except(:class, \"class\")" })
      else
        @fragments.concat(@spreads.map { |expr| "**(#{expr})" })
      end

      # Build final parts array - escape non-ERB parts only
      parts = []
      parts << build_class(class_parts) if class_parts.any?
      parts << "id=\"#{escape_parts(id_parts).join(" ")}\"" if id_parts.any?
      parts.concat(attrs.values)
      parts << "<%= tag.attributes(#{@fragments.join(", ")}) %>" if @fragments.any?

      parts.empty? ? "" : " " + parts.join(" ")
    end

    private

    # Literal and interpolated classes inline as before. Once a class value is an
    # arbitrary expression (which may be nil, false or an Array) the whole list goes
    # through class_names, which drops nil/false and flattens arrays like hamlit.
    def build_class(class_parts)
      return "class=\"#{escape_parts(class_parts).join(" ")}\"" unless @dynamic_class

      "class=\"<%= class_names(#{class_parts.map { |part| class_argument(part) }.join(", ")}) %>\""
    end

    def class_argument(part)
      return ::Regexp.last_match(1) if part =~ /\A<%= (.*) %>\z/m

      literal = part.split(/(<%= .*? %>)/m).map do |segment|
        if segment =~ /\A<%= (.*) %>\z/m
          "\#{#{::Regexp.last_match(1)}}"
        else
          segment.gsub("\\") { "\\\\" }.gsub('"') { '\\"' }
        end
      end.join
      "\"#{literal}\""
    end

    def extract_quoted_value(attr_str, prefix)
      if attr_str =~ /\A#{prefix}="(.*)"\z/
        ::Regexp.last_match(1)
      else
        attr_str.sub(/\A#{prefix}="/, "").sub(/"\z/, "")
      end
    end

    def parse_dynamic(hash_str)
      content = hash_str.strip
      content = content[1..-2] if content.start_with?("{") && content.end_with?("}")

      # Try to parse as static Ruby hash using Prism
      hash = @parser.parse_hash(content)
      return format_hash(hash) if hash

      # Fallback: parse key-value pairs and wrap dynamic values in ERB
      parse_to_erb_attrs(content)
    end

    # Convert a Ruby hash to an array of HTML attribute strings
    def format_hash(hash, prefix = nil)
      hash.flat_map do |key, value|
        # hamlit hyphenates keys only inside data/aria hashes; top-level keys stay as written.
        attr_name = prefix ? "#{prefix}-#{key.to_s.tr("_", "-")}" : key.to_s
        format_attribute(attr_name, value, nested: !prefix.nil?)
      end
    end

    def format_attribute(attr_name, value, nested: false)
      case value
      when Hash
        format_hash(value, attr_name)
      when true
        format_true_value(attr_name)
      when false
        format_false_value(attr_name, nested:)
      when nil
        []
      when Array
        format_array_value(attr_name, value)
      else
        [ "#{attr_name}=\"#{escape_attr(value.to_s)}\"" ]
      end
    end

    # hamlit renders `true` bare for boolean attributes and for data-*/aria-*, but writes
    # the string "true" for anything else (`draggable="true"`, an enumerated attribute).
    def format_true_value(attr_name)
      if BOOLEAN_ATTRIBUTES.include?(attr_name) || attr_name.start_with?("data-", "aria-")
        [ attr_name ]
      else
        [ "#{attr_name}=\"true\"" ]
      end
    end

    # hamlit drops `false` for boolean attributes and inside data/aria hashes, but
    # writes the string "false" for any other top-level attribute.
    def format_false_value(attr_name, nested: false)
      if nested || BOOLEAN_ATTRIBUTES.include?(attr_name)
        []
      else
        [ "#{attr_name}=\"false\"" ]
      end
    end

    def format_array_value(attr_name, value)
      if attr_name == "class"
        [ "#{attr_name}=\"#{escape_attr(value.join(" "))}\"" ]
      else
        [ "#{attr_name}=\"#{escape_attr(value.to_json)}\"" ]
      end
    end

    def parse_to_erb_attrs(hash_str)
      attrs = []
      remaining = hash_str.strip

      while remaining && !remaining.empty?
        # `**opts` spreads a hash into the attributes; only tag.attributes can do that at render time.
        if remaining.match?(/\A\s*\*\*/)
          remaining = remaining.sub(/\A\s*\*\*/, "")
          value, remaining = extract_value(remaining)
          @spreads << value.strip if value && !value.strip.empty?
          remaining = remaining&.sub(/\A\s*,\s*/, "")
          next
        end

        # Match key: symbol (:foo), string ('foo'/"foo"), or bare word (foo)
        match = remaining.match(KEY_PATTERN)
        unless match
          # `%div{ attrs }`: HAML passes the brace contents as arguments, so a bare
          # expression is a whole attribute hash.
          value, remaining = extract_value(remaining)
          @spreads << value.strip if value && !value.strip.empty?
          remaining = remaining&.sub(/\A\s*,\s*/, "")
          next
        end

        key = match[1] || match[3] || match[4]
        remaining = remaining[match.end(0)..]

        value, remaining = extract_value(remaining)
        next if value.nil?

        attr = format_dynamic_value(key, value.strip)
        attrs << attr if attr

        remaining = remaining&.sub(/\A\s*,\s*/, "")
      end

      attrs
    end

    def extract_value(str)
      return [ nil, str ] if str.nil? || str.empty?

      depth = { "{" => 0, "(" => 0, "[" => 0 }
      close = { "{" => "}", "(" => ")", "[" => "]" }
      in_string = nil
      interpolation_depth = 0
      escape = false
      i = 0

      while i < str.length
        char = str[i]

        if escape
          escape = false
        elsif char == "\\"
          escape = true
        elsif interpolation_depth.positive?
          if char == "{"
            interpolation_depth += 1
          elsif char == "}"
            interpolation_depth -= 1
          elsif [ '"', "'" ].include?(char)
            quote = char
            i += 1
            while i < str.length
              if str[i] == "\\"
                i += 2
              elsif str[i] == quote
                break
              else
                i += 1
              end
            end
          end
        elsif in_string
          if in_string == '"' && char == "#" && str[i + 1] == "{"
            interpolation_depth = 1
            i += 1
          elsif char == in_string
            in_string = nil
          end
        elsif [ '"', "'" ].include?(char)
          in_string = char
        elsif depth.key?(char)
          depth[char] += 1
        elsif close.values.include?(char)
          depth[close.key(char)] -= 1
        elsif char == "," && depth.values.all?(&:zero?)
          return [ str[0...i], str[i..] ]
        end

        i += 1
      end

      [ str, "" ]
    end

    def format_dynamic_value(key, value, nested: false)
      return format_class_value(value) if key == "class"

      if value.start_with?("{")
        format_nested_hash(key, value)
      elsif value.start_with?("[")
        format_array_literal(key, value)
      elsif value =~ /\A(["'])(.*)\1\z/m
        format_string_literal(key, value, ::Regexp.last_match(2))
      elsif value == "true"
        format_true_value(key).first || key
      elsif value == "false"
        format_false_literal(key, nested:)
      elsif value == "nil"
        nil
      elsif value =~ /\A:(\w+)\z/
        "#{key}=\"#{::Regexp.last_match(1)}\""
      elsif value =~ /\A\d+(\.\d+)?\z/
        "#{key}=\"#{value}\""
      elsif BOOLEAN_ATTRIBUTES.include?(key) || (nested && boolean_expression?(value))
        # Boolean attributes, and predicate-valued data/aria values, render bare when
        # true and not at all otherwise, like hamlit.
        "<%= '#{key}' if (#{value}) %>"
      elsif HASH_ATTRIBUTES.include?(key)
        # `data: some_hash` expands to data-* at render time; tag.attributes does the same.
        @fragments << "#{key}: #{value}"
        nil
      elsif nested && nil_capable?(value)
        # `|| nil` turns false into nil so tag.attributes omits it like hamlit does.
        @fragments << "\"#{key}\" => (#{value}) || nil"
        nil
      else
        "#{key}=\"<%= #{value} %>\""
      end
    end

    # hamlit drops nil/false classes and flattens arrays; class_names does the same,
    # so any class value that is not a plain literal is handed to it (see build_class).
    def format_class_value(value)
      if value =~ /\A(["'])(.*)\1\z/m
        format_string_literal("class", value, ::Regexp.last_match(2))
      elsif value =~ /\A:(\w+)\z/
        "class=\"#{::Regexp.last_match(1)}\""
      elsif value.start_with?("[") && (arr = @parser.parse_array(value))
        "class=\"#{escape_attr(arr.join(" "))}\""
      else
        @dynamic_class = true
        "class=\"<%= #{value} %>\""
      end
    end

    def nil_capable?(expression)
      result = Prism.parse(expression)
      return false if result.errors.any?

      nil_capable_node?(result.value)
    end

    # A predicate call (`new_record?`, `!x`, possibly followed by `.presence`) yields a
    # boolean, which hamlit renders as a bare attribute or nothing at all.
    def boolean_expression?(expression)
      result = Prism.parse(expression)
      return false if result.errors.any?

      body = result.value.statements.body
      body.length == 1 && predicate_call?(body.first)
    end

    def predicate_call?(node)
      node = node.body&.body&.first if node.is_a?(Prism::ParenthesesNode)
      return false unless node.is_a?(Prism::CallNode)

      node.name.to_s.end_with?("?") || node.name == :! ||
        (node.name == :presence && predicate_call?(node.receiver))
    end

    def nil_capable_node?(node)
      return true if NIL_CAPABLE_NODES.any? { |klass| node.is_a?(klass) }
      return true if node.is_a?(Prism::CallNode) && (node.safe_navigation? || node.name == :presence)

      node.compact_child_nodes.any? { |child| nil_capable_node?(child) }
    end

    def format_nested_hash(key, value)
      nested = @parser.parse_hash(value)
      if nested
        format_hash(nested, key).join(" ")
      elsif value.include?("**")
        # A spread inside the hash cannot be expanded statically; hand the whole hash over.
        @fragments << "#{key}: #{value}"
        nil
      else
        expand_nested_hash(key, value)
      end
    end

    def expand_nested_hash(prefix, hash_str)
      content = hash_str.strip
      content = content[1..-2] if content.start_with?("{") && content.end_with?("}")

      attrs = []
      remaining = content.strip

      while remaining && !remaining.empty?
        match = remaining.match(KEY_PATTERN)
        break unless match

        raw_key = (match[1] || match[3] || match[4]).tr("_", "-")
        attr_name = "#{prefix}-#{raw_key}"
        remaining = remaining[match.end(0)..]

        val, remaining = extract_value(remaining)
        next if val.nil?

        attr = format_dynamic_value(attr_name, val.strip, nested: true)
        attrs << attr if attr

        remaining = remaining&.sub(/\A\s*,\s*/, "")
      end

      attrs.empty? ? nil : attrs.join(" ")
    end

    def format_array_literal(key, value)
      arr = @parser.parse_array(value)
      if arr
        json = key == "class" ? arr.join(" ") : arr.to_json
        "#{key}=\"#{escape_attr(json)}\""
      else
        "#{key}=\"<%= #{value} %>\""
      end
    end

    def format_string_literal(key, value, inner)
      if inner.match?(/['"]\s*\+|\+\s*['"]/)
        "#{key}=\"<%= #{value} %>\""
      elsif inner.include?('#{')
        "#{key}=\"#{Interpolation.convert(inner)}\""
      else
        "#{key}=\"#{inner}\""
      end
    end

    def format_false_literal(key, nested: false)
      if nested || BOOLEAN_ATTRIBUTES.include?(key)
        nil
      else
        "#{key}=\"false\""
      end
    end

    # Escape an array of attribute parts, skipping ERB expressions
    def escape_parts(parts)
      parts.map { |part| part.include?("<%") ? part : escape_attr(part) }
    end

    # HTML5 attribute escaping:
    # - & → &amp; (prevents entity injection)
    # - " → &quot; (prevents attribute boundary escape)
    # - < and > NOT escaped (valid in HTML5 attribute values per spec,
    #   required for Stimulus actions like "click->form#submit")
    def escape_attr(str)
      str.to_s.gsub("&", "&amp;").gsub('"', "&quot;")
    end
  end
end
