# frozen_string_literal: true

require "spec_helper"

# Each example pins the converter to what hamlit renders for the same HAML, so the
# converted ERB produces the same DOM. Expected values were checked against hamlit 3.0.
RSpec.describe HamlToErb::Converter do
  def convert(haml)
    HamlToErb.convert(haml)
  end

  describe "class attribute" do
    it "leaves purely static classes inline" do
      expect(convert('.card{ class: "big" }')).to eq("<div class=\"card big\"></div>\n")
    end

    it "routes a falsy-capable expression through class_names so false never renders" do
      expect(convert('.card{ class: preview && "preview" }'))
        .to eq("<div class=\"<%= class_names(\"card\", preview && \"preview\") %>\"></div>\n")
    end

    it "routes a variable through class_names so arrays flatten" do
      expect(convert(".booking{ class: classes }"))
        .to eq("<div class=\"<%= class_names(\"booking\", classes) %>\"></div>\n")
    end

    it "routes a dynamic array literal through class_names" do
      expect(convert('%div{ class: [nil, "b", active && "c"] }'))
        .to eq("<div class=\"<%= class_names([nil, \"b\", active && \"c\"]) %>\"></div>\n")
    end

    it "keeps an interpolated class as a string literal argument" do
      expect(convert('.btn{ class: "btn-#{size}" }'))
        .to eq("<div class=\"btn btn-<%= size %>\"></div>\n")
    end

    it "quotes static parts correctly when mixed with a dynamic part" do
      expect(convert('.btn{ class: size_class, id: "x" }'))
        .to eq("<div class=\"<%= class_names(\"btn\", size_class) %>\" id=\"x\"></div>\n")
    end
  end

  describe "data and aria hashes" do
    it "expands a hash variable with tag.attributes" do
      expect(convert("%span{ data: data_attributes }"))
        .to eq("<span <%= tag.attributes(data: data_attributes) %>></span>\n")
    end

    it "expands an aria hash variable with tag.attributes" do
      expect(convert("%span{ aria: aria_opts }"))
        .to eq("<span <%= tag.attributes(aria: aria_opts) %>></span>\n")
    end

    it "hands a nested hash containing a spread to tag.attributes whole" do
      haml = '%body{ data: { ten: "1", **(barcode? ? { controller: "barcode" } : {}) } }'
      expect(convert(haml))
        .to eq("<body <%= tag.attributes(data: { ten: \"1\", **(barcode? ? { controller: \"barcode\" } : {}) }) %>></body>\n")
    end

    it "routes a nil-capable nested value through tag.attributes so nil and false are omitted" do
      expect(convert('%div{ data: { controller: "x", voucher_item: (sale? ? "true" : nil) } }'))
        .to eq("<div data-controller=\"x\" <%= tag.attributes(\"data-voucher-item\" => ((sale? ? \"true\" : nil)) || nil) %>></div>\n")
    end

    it "treats safe navigation, presence and && as nil-capable" do
      result = convert("%div{ data: { venue: current_venue&.id, name: params[:q].presence, tag: sale? && \"sale\" } }")
      expect(result).to include('"data-venue" => (current_venue&.id) || nil')
      expect(result).to include('"data-name" => (params[:q].presence) || nil')
      expect(result).to include('"data-tag" => (sale? && "sale") || nil')
    end

    it "renders a predicate-valued nested attribute bare or not at all" do
      expect(convert("%div{ data: { newrecord: form.object.new_record?.presence, locked: !editable? } }"))
        .to eq("<div <%= 'data-newrecord' if (form.object.new_record?.presence) %> <%= 'data-locked' if (!editable?) %>></div>\n")
    end

    it "keeps a plain call inline" do
      expect(convert("%div{ data: { lat: location.lat } }"))
        .to eq("<div data-lat=\"<%= location.lat %>\"></div>\n")
    end

    it "renders true bare and drops false inside the hash" do
      expect(convert("%div{ data: { x: true, y: false, z: nil } }")).to eq("<div data-x></div>\n")
    end
  end

  describe "spreads and whole-hash attributes" do
    it "spreads **opts through tag.attributes" do
      expect(convert("%button{ type: \"button\", **decrement_attrs } -"))
        .to eq("<button type=\"button\" <%= tag.attributes(**(decrement_attrs)) %>>-</button>\n")
    end

    it "merges a class carried by the spread with the tag's own classes" do
      expect(convert("%button.btn{ **decrement_attrs } -"))
        .to eq("<button class=\"<%= class_names(\"btn\", (decrement_attrs).values_at(:class, \"class\")) %>\" " \
               "<%= tag.attributes(**(decrement_attrs).except(:class, \"class\")) %>>-</button>\n")
    end

    it "treats a bare expression as the whole attribute hash" do
      expect(convert("#section{ section_attrs }"))
        .to eq("<div id=\"section\" <%= tag.attributes(**(section_attrs)) %>></div>\n")
    end
  end

  describe "attribute names and values" do
    it "keeps underscores in top-level keys, like hamlit" do
      expect(convert('%svg{ stroke_width: 2, viewBox: "0 0 1 1" }'))
        .to eq("<svg stroke_width=\"2\" viewBox=\"0 0 1 1\"></svg>\n")
    end

    it "hyphenates keys inside data hashes" do
      expect(convert("%div{ data: { foo_bar: 1 } }")).to eq("<div data-foo-bar=\"1\"></div>\n")
    end

    it "writes the string false for a top-level non-boolean attribute" do
      expect(convert("%div{ lang: false }")).to eq("<div lang=\"false\"></div>\n")
    end

    it "writes the string true for a non-boolean attribute such as draggable, but bare for booleans and data-*" do
      expect(convert('%div{ draggable: true, foo: true, "data-x": true, disabled: true }'))
        .to eq("<div draggable=\"true\" foo=\"true\" data-x disabled></div>\n")
    end

    it "keeps two conditional boolean attributes on one tag" do
      result = convert("%input{ disabled: locked?, required: needed? }")
      expect(result).to include("<%= 'disabled' if (locked?) %>")
      expect(result).to include("<%= 'required' if (needed?) %>")
    end
  end

  describe "unescaped output" do
    it "converts != to <%==" do
      expect(convert("!= raw_html")).to eq("<%== raw_html %>\n")
    end

    it "converts a tag with != to <%== inside the tag" do
      expect(convert("%span!= raw_html")).to eq("<span><%== raw_html %></span>\n")
    end

    it "converts a != block opener" do
      expect(convert("!= wrapper do\n  %p x\n")).to eq("<%== wrapper do %>\n  <p>x</p>\n<% end %>\n")
    end

    it "keeps = and &= escaped" do
      expect(convert("= safe\n&= also_safe\n%b= x\n")).to eq("<%= safe %>\n<%= also_safe %>\n<b><%= x %></b>\n")
    end
  end

  describe ":ruby filter" do
    it "keeps a statement that spans lines inside one block" do
      haml = <<~HAML
        :ruby
          steps_url = path(signup,
            id: signup.step)
          continue_url = event.open? ? steps_url : nil
      HAML

      expect(convert(haml)).to eq(<<~ERB)
        <%
          steps_url = path(signup,
            id: signup.step)
          continue_url = event.open? ? steps_url : nil
        %>
      ERB
    end

    it "keeps a trailing comment from swallowing the closing tag" do
      expect(convert(":ruby\n  x = 1\n  # note\n")).to eq("<%\n  x = 1\n  # note\n%>\n")
    end

    it "indents the block with its tag" do
      expect(convert("%div\n  :ruby\n    x = 1\n")).to eq("<div>\n  <%\n    x = 1\n  %>\n</div>\n")
    end

    it "emits nothing for an empty filter instead of crashing" do
      expect(convert(":ruby\n%p x\n")).to eq("<p>x</p>\n")
    end
  end
end
