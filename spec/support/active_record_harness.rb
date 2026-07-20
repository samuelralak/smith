# frozen_string_literal: true

begin
  require "active_record"
  require "sqlite3"
  require "ruby_llm/active_record/payload_helpers"
  require "ruby_llm/active_record/chat_methods"
  require "ruby_llm/active_record/message_methods"
  require "ruby_llm/active_record/model_methods"
  require "ruby_llm/active_record/tool_call_methods"
  require "ruby_llm/active_record/acts_as"
rescue LoadError => e
  raise "Active Record specs require the development and test bundle: #{e.message}"
end

ActiveRecord::Base.include RubyLLM::ActiveRecord::ActsAs unless ActiveRecord::Base.respond_to?(:acts_as_chat)
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

ActiveRecord::Schema.define do
  self.verbose = false
  create_table :claimable_records do |t|
    t.string :status, null: false
    t.integer :lock_version, null: false, default: 0
    t.timestamps
  end

  create_table :smith_workflow_state_records do |t|
    t.string :key, null: false, index: { unique: true }
    t.text :payload, null: false
    t.integer :lock_version, null: false, default: 0
    t.integer :workflow_revision, null: false, default: 0
    t.string :unique_token
    t.timestamps
  end
  add_index :smith_workflow_state_records, :unique_token, unique: true

  create_table :transactional_peer_records do |t|
    t.string :workflow_key, null: false
    t.string :event_name, null: false
    t.timestamps
  end

  create_table :spec_ruby_llm_models do |t|
    t.string :model_id, null: false
    t.string :name, null: false
    t.string :provider, null: false
    t.string :family
    t.integer :context_window
    t.integer :max_output_tokens
    t.json :modalities, default: {}
    t.json :capabilities, default: []
    t.json :pricing, default: {}
    t.json :metadata, default: {}
    t.timestamps
  end
  add_index :spec_ruby_llm_models, %i[provider model_id], unique: true

  create_table :spec_ruby_llm_chats do |t|
    t.references :model
    t.timestamps
  end

  create_table :spec_ruby_llm_messages do |t|
    t.references :chat, null: false
    t.references :model
    t.references :tool_call
    t.string :role, null: false
    t.text :content
    t.json :content_raw
    t.integer :input_tokens
    t.integer :output_tokens
    t.timestamps
  end

  create_table :spec_ruby_llm_tool_calls do |t|
    t.references :message, null: false
    t.string :tool_call_id, null: false
    t.string :name, null: false
    t.json :arguments, default: {}
    t.timestamps
  end
end

class ClaimableRecord < ActiveRecord::Base
  def mark_processing!
    update_columns(status: "processing", updated_at: Time.now.utc)
  end

  def mark_ready!
    update_columns(status: "ready", updated_at: Time.now.utc)
  end
end

RSpec.configure do |config|
  config.around(:each, :ar) do |example|
    if example.metadata[:commit]
      begin
        example.run
      ensure
        SmithWorkflowStateRecord.delete_all
        TransactionalPeerRecord.delete_all
      end
    else
      ActiveRecord::Base.transaction do
        example.run
        raise ActiveRecord::Rollback
      end
    end
  end
end
