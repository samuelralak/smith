# frozen_string_literal: true

# A Smith::Tool subclass inherits every declaration of its parent's (its
# description, parameters, provider params, category, capabilities,
# authorize, before_execute and capture), each read from the nearest class
# that declared it, and overrides one by declaring it again. A tool none of
# whose classes declares authorize runs as an undeclared one always has; a
# subclass is never less guarded than its parent unless it says so.
RSpec.describe "Smith::Tool declarations, inherited" do
  let(:tool_class) { require_const("Smith::Tool") }
  let(:denied) { require_const("Smith::ToolPolicyDenied") }

  def tool(name, parent = tool_class, &body)
    with_stubbed_class(name, parent) do
      define_method(:perform) { |**kwargs| kwargs.except(:context).merge(by: self.class.name) }
      class_exec(&body) if body
    end
  end

  def schema(klass) = klass.new.params_schema

  describe "description and parameters" do
    it "gives a subclass its parent's, adds and replaces parameters by name, and leaves the parent alone" do
      parent = tool("SpecSearchTool") do
        description "Search the catalogue."
        param :query, type: :string, desc: "What to look for"
        param :limit, type: :integer, required: false
      end
      same = tool("SpecSameSearchTool", parent)
      wider = tool("SpecWiderSearchTool", parent) do
        description "Search the catalogue and the archive."
        param :limit, type: :integer, desc: "At most this many", required: true
        param :archive, type: :boolean, required: false
      end

      expect([same.description, same.desc, same.new.description]).to eq(["Search the catalogue."] * 3)
      expect(schema(same)).to eq(schema(parent))
      expect(wider.description).to eq("Search the catalogue and the archive.")
      expect(schema(wider)["properties"].keys).to eq(%w[query limit archive])
      expect(schema(wider)["properties"]["limit"]).to include("description" => "At most this many")
      expect(schema(wider)["required"]).to eq(%w[query limit])
      expect(parent.parameters.keys).to eq(%i[query limit])
      expect(schema(parent)["required"]).to eq(%w[query])
    end

    it "reaches a subclass made before its parent declared, and a grandchild through its parent" do
      parent = tool("SpecLateParentTool")
      child = tool("SpecLateChildTool", parent)
      grandchild = tool("SpecLateGrandchildTool", child)
      parent.description "Declared late."
      parent.param :query, type: :string

      expect([child.description, grandchild.description]).to eq(["Declared late."] * 2)
      expect(grandchild.parameters.keys).to eq(%i[query])
    end

    it "takes a schema given with `params` from the nearest class that gave one, unless the subclass declares params" do
      parent = tool("SpecSchemaParentTool") do
        params({ type: "object", properties: { term: { type: "string" } }, required: ["term"] })
      end
      same = tool("SpecSchemaSameTool", parent)
      own_params = tool("SpecSchemaParamsTool", parent) { param :query, type: :string }
      own_schema = tool("SpecSchemaOwnTool", tool("SpecParamsParentTool") { param :query, type: :string }) do
        params({ type: "object", properties: { id: { type: "integer" } }, required: ["id"] })
      end

      expect(schema(same)).to eq(schema(parent))
      expect(schema(own_params)["properties"].keys).to eq(%w[query])
      expect(schema(own_schema)["properties"].keys).to eq(%w[id])
    end

    it "gives a Smith-shipped stub's description, parameters and compatibility to the host's subclass" do
      search = tool("SpecHostWebSearch", Smith::Tools::WebSearch)

      expect(search.description).to eq(Smith::Tools::WebSearch.description)
      expect(schema(search)).to eq(schema(Smith::Tools::WebSearch))
      expect(search.compatible_with_spec).to eq(Smith::Tools::WebSearch.compatible_with_spec)
    end
  end

  describe "provider params and category" do
    it "gives a subclass its parent's until it declares its own" do
      parent = tool("SpecCachedTool") do
        category :data_access
        with_params(cache_control: { type: "ephemeral" })
      end
      same = tool("SpecCachedSameTool", parent)
      own = tool("SpecCachedOwnTool", parent) do
        category :computation
        with_params(strict: true)
      end

      expect([same.category, same.new.provider_params]).to eq([:data_access, { cache_control: { type: "ephemeral" } }])
      expect([own.category, own.provider_params]).to eq([:computation, { strict: true }])
      expect([parent.category, parent.provider_params]).to eq([:data_access, { cache_control: { type: "ephemeral" } }])
      expect([tool_class.category, tool("SpecPlainTool").provider_params]).to eq([nil, {}])
    end
  end

  describe "capabilities" do
    it "merge key by key: a subclass keeps what it does not name and replaces what it does" do
      parent = tool("SpecGuardedTool") do
        capabilities do
          sensitivity :high
          privilege :elevated
        end
      end
      same = tool("SpecGuardedSameTool", parent)
      looser = tool("SpecGuardedLooserTool", parent) do
        capabilities do
          privilege :none
          replay :safe
        end
      end

      expect(same.capabilities).to eq(sensitivity: :high, privilege: :elevated)
      expect(looser.capabilities).to eq(sensitivity: :high, privilege: :none, replay: :safe)
      expect(parent.capabilities).to eq(sensitivity: :high, privilege: :elevated)
      expect(tool("SpecUndeclaredTool").capabilities).to be_nil
      expect { same.new.execute(context: { user: :someone }) }.to raise_error(denied, /privilege :elevated/)
      expect(looser.new.execute(context: {})).to eq(by: "SpecGuardedLooserTool")
    end

    it "keep a parent's trace sensitivity on its subclass's tool calls" do
      traces = Smith::Trace::Memory.new
      allow(Smith.config).to receive_messages(trace_adapter: traces, trace_content: true)
      parent = tool("SpecSecretTool") { capabilities { sensitivity :high } }
      tool("SpecSecretChildTool", parent).new.execute(token: "s3cret")
      tool("SpecOpenTool").new.execute(token: "open")

      data = traces.traces.select { _1[:type] == :tool_call }.map { _1[:data] }
      expect(data.map { _1[:tool] }).to eq(%w[spec_secret_child spec_open])
      expect(data.map { _1.key?(:args) }).to eq([false, true])
    end
  end

  describe "authorize" do
    let(:allow_admins) { ->(context) { context&.dig(:role) == :admin } }

    it "is never lost on a subclass: an inherited authorize denies it as its parent" do
      rule = allow_admins
      parent = tool("SpecAdminTool") { authorize(&rule) }
      child = tool("SpecAdminChildTool", parent)
      grandchild = tool("SpecAdminGrandchildTool", child)

      [parent, child, grandchild].each do |klass|
        expect { klass.new.execute(context: { role: :guest }) }.to raise_error(denied), klass.name
        expect { klass.new.execute }.to raise_error(denied), klass.name
        expect(klass.new.execute(context: { role: :admin })).to eq(by: klass.name)
      end
      expect(child.authorize).to equal(parent.authorize)
    end

    it "is the nearest declared: a subclass's own replaces its parent's for it and its subclasses" do
      rule = allow_admins
      parent = tool("SpecRuleParentTool") { authorize(&rule) }
      own = tool("SpecRuleOwnTool", parent) { authorize { |context| rule.call(context) && context[:ok] } }
      below = tool("SpecRuleBelowTool", own)

      [own, below].each do |klass|
        expect { klass.new.execute(context: { role: :admin }) }.to raise_error(denied), klass.name
        expect(klass.new.execute(context: { role: :admin, ok: true })).to eq(by: klass.name)
      end
      expect(parent.new.execute(context: { role: :admin })).to eq(by: "SpecRuleParentTool")

      loose = tool("SpecRuleLooseTool", parent) { authorize { |context| context&.dig(:ok) } }
      both = tool("SpecRuleBothTool", parent) do
        authorize { |context| superclass.authorize.call(context) && context[:ok] }
      end
      expect(loose.new.execute(context: { ok: true })).to eq(by: "SpecRuleLooseTool")
      expect { both.new.execute(context: { ok: true }) }.to raise_error(denied)
      expect(both.new.execute(context: { role: :admin, ok: true })).to eq(by: "SpecRuleBothTool")
    end

    it "is absent only when no class declares one, which runs the tool as before" do
      parent = tool("SpecOpenParentTool")
      child = tool("SpecOpenChildTool", parent)

      expect([tool_class.authorize, parent.authorize, child.authorize]).to eq([nil, nil, nil])
      expect(child.new.execute(context: nil)).to eq(by: "SpecOpenChildTool")
    end
  end

  describe "before_execute" do
    it "runs the parent's hook on a subclass until it declares its own" do
      seen = []
      parent = tool("SpecHookedTool") { before_execute { |instance, _kwargs| seen << [:parent, instance.class.name] } }
      child = tool("SpecHookedChildTool", parent)
      own = tool("SpecHookedOwnTool", parent) do
        before_execute { |instance, _kwargs| seen << [:own, instance.class.name] }
      end

      [parent, child, own].each { _1.new.execute }

      expect(seen).to eq([[:parent, "SpecHookedTool"], [:parent, "SpecHookedChildTool"], [:own, "SpecHookedOwnTool"]])
    end
  end
end
