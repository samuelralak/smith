# frozen_string_literal: true

require "json"
require "socket"

# A local HTTP server for specs that drive RubyLLM's real provider code:
# each request is answered by the next queued reply, either server-sent
# events (`events:`, each a Hash sent as one `data:` line, or a String sent
# as is) or a JSON body (`json:`); a request with no reply queued gets a 500.
# Requests are recorded with their paths and parsed bodies.
class SseServer
  Request = Struct.new(:path, :body)

  attr_reader :requests

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @replies = Queue.new
    @requests = []
    @thread = Thread.new { serve }
  end

  def url = "http://127.0.0.1:#{@server.addr[1]}"

  def reply(events: nil, json: nil)
    @replies << (events ? [:events, events] : [:json, json])
    self
  end

  def close
    @thread.kill
    @server.close
  end

  private

  def serve
    loop do
      client = @server.accept
      handle(client)
    ensure
      client&.close
    end
  end

  def handle(client)
    path, length = read_head(client)
    body = length.positive? ? client.read(length) : ""
    @requests << Request.new(path, (JSON.parse(body) unless body.empty?))
    return write_json(client, { error: { message: "no reply queued" } }, status: "500 Internal Server Error") if
      @replies.empty?

    kind, payload = @replies.pop
    kind == :events ? write_events(client, payload) : write_json(client, payload)
  end

  def read_head(client)
    path = client.gets.to_s.split[1]
    length = 0
    while (line = client.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      length = value.to_i if name.casecmp?("content-length")
    end
    [path, length]
  end

  def write_events(client, events)
    client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
    events.each do |event|
      client.write(event.is_a?(String) ? event : "data: #{JSON.generate(event)}\n\n")
      client.flush
    end
  end

  def write_json(client, payload, status: "200 OK")
    body = JSON.generate(payload)
    client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{body}")
  end
end
