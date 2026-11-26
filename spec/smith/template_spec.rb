# frozen_string_literal: true

require "smith/template"

# Logic-less fill-in fields (additions design 2.3 and 2.14): {{name}} or
# {{ name }} only, every other "{{" refused at its position, values
# substituted as they are in one pass, Hash and Array values as canonical
# JSON, and linear time.
RSpec.describe Smith::Template do
  def problems(text) = described_class.problems(text)

  describe "fill-in fields" do
    it "reads {{name}} and {{ name }}, in order of first appearance, once each" do
      template = described_class.new("The person:\n{{person_summary}}\n\n{{ posting }} and {{person_summary}} again")

      expect(template.fields).to eq(%w[person_summary posting])
      expect(template.fields).to be_frozen
      expect(template.field_count).to eq(3)
    end

    it "takes names of a letter or underscore, then up to 63 letters, digits or underscores" do
      longest = "_#{"a1" * 31}b"

      expect(longest.length).to eq(64)
      expect(described_class.new("{{#{longest}}}").fields).to eq([longest])
      expect(problems("{{#{longest}c}}")).to eq(["{{ at line 1, column 1: not a fill-in field; " \
                                                 "fill-in fields are {{name}} or {{ name }} only"])
    end

    it "leaves text without fields, single braces and closing braces as they are" do
      text = "JSON looks like {\"a\": {\"b\": 1}} and } or { alone }}"

      expect(problems(text)).to eq([])
      expect(described_class.new(text).render({})).to eq(text)
    end
  end

  describe "refused forms" do
    forms = {
      "{{#section}}x{{/section}}" => ["{{# at line 1, column 1: a Mustache section",
                                      "{{/ at line 1, column 14: a section's closing"],
      "{{^empty}}" => ["{{^ at line 1, column 1: an inverted section"],
      "{{> partial}}" => ["{{> at line 1, column 1: a partial"],
      "{{! note }}" => ["{{! at line 1, column 1: a comment"],
      "{{{raw}}}" => ["{{{ at line 1, column 1: triple braces"],
      "{{&raw}}" => ["{{& at line 1, column 1: an unescaped tag"],
      "{{=<% %>=}}" => ["{{= at line 1, column 1: a delimiter change"]
    }
    rule = "; fill-in fields are {{name}} or {{ name }} only"

    forms.each do |text, expected|
      it "refuses #{text} at its position" do
        expect(problems(text)).to eq(expected.map { "#{_1}#{rule}" })
        expect { described_class.new(text) }.to raise_error(ArgumentError, /#{Regexp.escape(expected.first)}/)
      end
    end

    others = ["{{}}", "{{ }}", "{{a.b}}", "{{1a}}", "{{ a}}", "{{a }}", "{{  a  }}", "{{\ta\t}}", "{{-a}}", "{{a}",
              "{{a", "{{", "{{é}}", "{{a\n}}"]

    others.each do |text|
      it "refuses #{text.inspect} as not a fill-in field" do
        expect(problems("ok\nand #{text}")).to eq(["{{ at line 2, column 5: not a fill-in field#{rule}"])
      end
    end

    it "counts columns in characters, not bytes, and reports every refused tag" do
      text = "été \u{1F69A} {{#a}}\n{{ok}} {{^b}}"

      expect(problems(text)).to eq(["{{# at line 1, column 7: a Mustache section#{rule}",
                                    "{{^ at line 2, column 8: an inverted section#{rule}"])
    end

    it "reports a run of opening braces once" do
      expect(problems("#{"{" * 10}a}}")).to eq(["{{{ at line 1, column 1: triple braces#{rule}"])
    end

    it "stops at #{described_class::MAX_PROBLEMS} problems" do
      expect(problems("{{#a}} " * 500).size).to eq(described_class::MAX_PROBLEMS)
    end

    it "keeps its reading rules to itself" do
      expect(described_class.constants).to eq([:MAX_PROBLEMS])
    end

    it "takes only valid UTF-8 text" do
      expect { described_class.new("\xff{{a}}".b) }.to raise_error(ArgumentError, /UTF-8/)
      expect { described_class.new(:text) }.to raise_error(ArgumentError, /a String/)
    end
  end

  describe "#render" do
    let(:template) { described_class.new("Channel: {{channel}}\n\n{{ ticket }} ({{channel}})") }

    it "substitutes each value as it is, with no escaping" do
      rendered = template.render("channel" => "<email> & \"web\"", ticket: "Ma commande n'est pas arrivée")

      expect(rendered).to eq("Channel: <email> & \"web\"\n\nMa commande n'est pas arrivée (<email> & \"web\")")
      expect(rendered.encoding).to eq(Encoding::UTF_8)
    end

    it "fills in one pass, so a value holding a field stays text" do
      rendered = template.render(channel: "{{ticket}}", ticket: "{{channel}}")

      expect(rendered).to eq("Channel: {{ticket}}\n\n{{channel}} ({{ticket}})")
    end

    it "renders Hash and Array values as canonical JSON, and other scalars as JSON" do
      values = { channel: { "z" => 1, "a" => [true, nil, 0.5] }, ticket: [1.0, "x"] }

      expect(template.render(values)).to eq("Channel: {\"a\":[true,null,0.5],\"z\":1}\n\n[1,\"x\"] " \
                                            "({\"a\":[true,null,0.5],\"z\":1})")
      expect(described_class.new("{{a}} {{b}} {{c}} {{d}}").render(a: 3, b: false, c: 1e21, d: :sym))
        .to eq("3 false 1e+21 sym")
    end

    it "raises TemplateValueMissing, a WorkflowError naming only the field, for a nil or absent value" do
      expect { template.render(channel: "web") }
        .to raise_error(Smith::TemplateValueMissing, "fill-in field {{ticket}} has no value")
      expect { template.render(channel: nil, ticket: "secret ticket text") }
        .to raise_error(Smith::TemplateValueMissing, "fill-in field {{channel}} has no value")
      expect(Smith::TemplateValueMissing.ancestors).to include(Smith::WorkflowError)
    end

    it "refuses a value with no JSON form, naming its class only" do
      expect { template.render(channel: Object.new, ticket: "t") }
        .to raise_error(Smith::CanonicalJSON::Error, "canonical JSON cannot hold a Object")
    end

    # Host values come from any source: a Latin-1 or UTF-16 String, or a
    # binary column holding UTF-8 bytes, is text the prompt can hold.
    it "returns UTF-8, converting a String from its own encoding, a binary one read as UTF-8 bytes" do
      fill = described_class.new("{{a}}|{{b}}|{{c}}|{{d}}|{{e}}")
      rendered = fill.render(a: "café".encode(Encoding::ISO_8859_1), b: "été \u{1F69A}".encode(Encoding::UTF_16LE),
                             c: "naïve".b, d: "plain".encode(Encoding::US_ASCII), e: "ü".encode(Encoding::ISO_8859_1).to_sym)

      expect(rendered).to eq("café|été \u{1F69A}|naïve|plain|ü")
      expect([rendered.encoding, rendered.valid_encoding?]).to eq([Encoding::UTF_8, true])
    end

    it "refuses a String with no UTF-8 form, naming only the field" do
      fill = described_class.new("{{text}}")
      # Binary bytes that are not UTF-8, invalid UTF-8, an odd UTF-16 byte, and
      # a Windows-1252 byte with no character.
      ["secret \xff".b, (+"secret \xff").force_encoding(Encoding::UTF_8), "\xff".b.force_encoding(Encoding::UTF_16LE),
       "\x81".b.force_encoding(Encoding::Windows_1252)].each do |value|
        expect { fill.render(text: value) }
          .to raise_error(Smith::CanonicalJSON::Error, "fill-in field {{text}} holds text with no UTF-8 form")
      end
    end
  end

  # Stated bound: reading and filling in a 1 MiB template with a field every
  # 12 bytes takes under a second (tens of milliseconds here), and twice the
  # text at most three times as long: linear, with headroom for a busy machine.
  describe "linear time" do
    def seconds
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end

    # The best of three runs, so one pause for garbage collection does not
    # decide the ratio.
    def timed(bytes)
      text = "word {{a}} " * (bytes / 11)
      template = nil
      runs = Array.new(3) { seconds { template = described_class.new(text) } + seconds { template.render(a: "v") } }
      [runs.min, template]
    end

    it "reads and renders 1 MiB within the bound, and 2 MiB in at most three times as long" do
      timed(64 * 1024) # warm up
      one, template = timed(1024 * 1024)
      two, = timed(2 * 1024 * 1024)

      expect(template.field_count).to eq(1024 * 1024 / 11)
      expect(one).to be < 1.0
      expect(two).to be < [3 * one, 0.05].max
    end

    it "checks 1 MiB of opening braces, or of refused tags, within the same bound" do
      expect(seconds { expect(problems("{" * (1024 * 1024)).size).to eq(1) }).to be < 1.0
      expect(seconds { expect(problems("{{ x" * (256 * 1024)).size).to eq(described_class::MAX_PROBLEMS) })
        .to be < 1.0
      expect(seconds { problems("a" * (1024 * 1024)) }).to be < 1.0
    end
  end
end
