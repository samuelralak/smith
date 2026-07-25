# frozen_string_literal: true

RSpec.describe "Smith::Tool managed execution authority" do
  subject(:authority_class) { Smith::Tool.const_get(:ExecutionAuthority, false) }

  it "can be claimed exactly once by the authorized tool" do
    tool = Object.new
    claim = Object.new

    authority_class.around(tool:, dispatch_claim: claim) do
      expect(authority_class.current.claim(tool, claim)).to be(true)
      expect(authority_class.current.claim(tool, claim)).to be(false)
    end
  end

  it "rejects a different dispatch claim for the same tool" do
    tool = Object.new
    admitted_claim = Object.new

    authority_class.around(tool:, dispatch_claim: admitted_claim) do
      expect(authority_class.current.claim(tool, Object.new)).to be(false)
      expect(authority_class.current.claim(tool, admitted_claim)).to be(true)
    end
  end

  it "restores an enclosing authority" do
    outer = Object.new
    inner = Object.new
    outer_claim = Object.new
    inner_claim = Object.new

    authority_class.around(tool: outer, dispatch_claim: outer_claim) do
      enclosing = authority_class.current
      authority_class.around(tool: inner, dispatch_claim: inner_claim) do
        expect(authority_class.current.claim(inner, inner_claim)).to be(true)
      end
      expect(authority_class.current).to equal(enclosing)
    end
  end

  it "is not a public Smith tool constant" do
    expect { Smith::Tool::ExecutionAuthority }.to raise_error(NameError, /private constant/)
  end
end
