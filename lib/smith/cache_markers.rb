# frozen_string_literal: true

module Smith
  # Anthropic's prompt-cache markers (`cache_control: { type: "ephemeral" }`
  # on a request, a system block, a content block, a tool result's block or
  # a tool) and Smith's own `"cache" => true` on a content part say how a
  # request is billed, never what it asks: the reply is the same with or
  # without them. What identifies a request (the response memo's key, a batch
  # request's digest, a seed's drift digest) leaves them out, so a host that
  # caches a prompt on one call and not on the next still finds what the
  # first call got. Only the places markers can sit are looked at: a tool's
  # input or schema, or anything else a request carries as data, is never
  # touched, and nothing is walked deeper than a tool result's blocks.
  module CacheMarkers
    MARKER_KEYS = [:cache_control, "cache_control"].freeze
    private_constant :MARKER_KEYS

    module_function

    # A request payload (a batch request's params, a chat's params): its own
    # marker, and those of its system blocks, its messages' blocks and its
    # tools.
    def strip_request(request)
      return request unless request.is_a?(Hash)

      request = unmarked(request)
      request = replaced(request, :system) { strip_blocks(_1) }
      request = replaced(request, :messages) do |messages|
        messages.is_a?(Array) ? messages.map { |message| replaced(message, :content) { strip_blocks(_1) } } : messages
      end
      replaced(request, :tools) { |tools| tools.is_a?(Array) ? tools.map { unmarked(_1) } : tools }
    end

    # A message's content: a block or blocks, a tool result's own blocks
    # included.
    def strip_blocks(content)
      case content
      when Array then content.map { strip_block(_1) }
      when Hash then strip_block(content)
      else content
      end
    end

    # Seed messages as Smith keeps them: each content part without its
    # `"cache" => true`.
    def strip_parts(messages)
      return messages unless messages.is_a?(Array)

      messages.map do |message|
        replaced(message, :content) { |content| content.is_a?(Array) ? content.map { unflagged(_1) } : content }
      end
    end

    def unflagged(part) = part.is_a?(Hash) ? part.except("cache", :cache) : part

    def strip_block(block)
      return block unless block.is_a?(Hash)

      block = unmarked(block)
      return block unless (block[:type] || block["type"]).to_s == "tool_result"

      replaced(block, :content) { |content| content.is_a?(Array) ? content.map { unmarked(_1) } : unmarked(content) }
    end

    def unmarked(value)
      return value unless value.is_a?(Hash)

      value.reject { |key, item| MARKER_KEYS.include?(key) && marker?(item) }
    end

    def marker?(value) = value.is_a?(Hash) && (value[:type] || value["type"]).to_s == "ephemeral"

    # The Hash with its value under `key` (a Symbol or a String key) passed
    # through the block.
    def replaced(hash, key)
      return hash unless hash.is_a?(Hash)

      [key, key.to_s].each do |name|
        hash = hash.merge(name => yield(hash[name])) if hash.key?(name)
      end
      hash
    end

    private_class_method :strip_block, :unflagged, :unmarked, :marker?, :replaced
  end
end
