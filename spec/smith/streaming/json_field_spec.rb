# frozen_string_literal: true

RSpec.describe Smith::Streaming::JsonField do
  # Every piece `push` returned, the text pushed `size` characters at a time.
  def pushed(field, text, size: 1)
    text.chars.each_slice(size).filter_map { field.push(_1.join) }
  end

  it "returns the text each piece adds to the field, nil when it adds none, and the field so far as value" do
    field = described_class.new(:reply)
    text = '{"meta": {"reply": "no"}, "list": ["reply", 1], "reply": "Hi \"you\" \u00e9", "after": "z"}'
    pieces = pushed(field, text, size: 3)

    expect(pieces.join).to eq('Hi "you" é')
    expect(pieces.size).to be > 2
    expect(pieces).to all(be_frozen)
    expect(field.push(' "more"}')).to be_nil
    expect(field.value).to eq('Hi "you" é')
    expect(field.value).to be_frozen
    expect(pushed(described_class.new(:reply), '{"reply": "ab"}')).to eq(%w[a b])
  end

  it "unescapes JSON's escapes, Unicode and surrogate pairs included, split anywhere" do
    text = '{"reply":"a\\"b\\\\c\\/d\\be\\ff\\ng\\rh\\ti\\x \\u00e9 \\ud83d\\ude00 \\ud83d! \\ude00 \\uZZZZ"}'
    expected = "a\"b\\c/d\be\ff\ng\rh\tix \u00e9 \u{1F600} \uFFFD! \uFFFD \uFFFD"

    [1, 2, 3, 7, text.length].each do |size|
      field = described_class.new("reply")
      pushed(field, text, size:)
      expect(field.value).to eq(expected), "pieces of #{size}"
    end
    field = described_class.new(:reply)
    field.push('{"reply":"\\ud83d"}')
    expect(field.value).to eq("�")
    field.reset
    field.push('{"reply":"\\ud83d\\u0041"}')
    expect(field.value).to eq("�A")
  end

  it "skips text before the object, reads the first object only, and only a string value" do
    fenced = described_class.new(:reply)
    expect(pushed(fenced, "```json\n{\"reply\": \"ok\"}\n```").join).to eq("ok")

    {
      '{"reply": 5, "x": "y"}' => "", '{"reply": {"text": "x"}}' => "", '{"reply": ["x"]}' => "",
      '{} {"reply": "late"}' => "", '{"reply\\u0020": "x", "replyx": "y"}' => "",
      '{"\\u0072eply": "escaped key"}' => "escaped key", '{"rep\\"ly": "x", "reply": "y"}' => "y",
      '{"reply": 5, "reply": "later"}' => "later",
      '{"note": "say \\"reply\\": \\"x\\"", "reply": "ok"}' => "ok", '{"note": "x\\"}", "reply": "real"}' => "real",
      '["reply", "x"]' => "", '{"a": [{"reply": "deep"}], "reply": "top"}' => "top",
      '{ "reply" : "spaced" }' => "spaced", '{"a":"b","reply":"c"}' => "c"
    }.each do |text, value|
      field = described_class.new(:reply)
      pushed(field, text)
      expect(field.value).to eq(value), text
    end
  end

  it "reads a string up to its limit, dropping the rest and saying so" do
    string = Smith::Streaming::JsonString.new(limit: 3)
    'abcdef"'.each_char { string.add(_1) }
    expect([string.text, string.overflowed?, string.closed?]).to eq(["abc", true, true])
    exact = Smith::Streaming::JsonString.new(limit: 3)
    'abc"'.each_char { exact.add(_1) }
    expect([exact.text, exact.overflowed?]).to eq(["abc", false])
  end

  it "starts over on reset, and is named by a Symbol or String" do
    field = described_class.new(:reply)
    field.push('{"reply": "first')
    expect(field.reset).to be_nil
    expect(field.value).to eq("")
    expect(pushed(field, '{"reply": "second"}').join).to eq("second")

    [nil, "", 3].each { |name| expect { described_class.new(name) }.to raise_error(ArgumentError, /named by/) }
  end
end
