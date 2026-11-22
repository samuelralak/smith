# frozen_string_literal: true

require "json"
require "socket"

# A local HTTP server for specs that drive RubyLLM's real provider code:
# each request is answered by the next queued reply, either server-sent
# events (`events:`, each a Hash sent as one `data:` line, or a String sent
# as is), a JSON body (`json:`), or a text body (`text:`, a results file);
# a request with no reply queued gets a 500. A reply may instead wait
# before it answers (`after:` seconds) or close the connection once the
# request is read (`drop: true`). Requests are recorded with their method,
# path, headers and bodies, parsed when JSON and kept as they came otherwise
# (a multipart upload), and the raw body bytes (the core invisibility
# harness compares those byte for byte). A responder given to `answer` picks
# a reply from the request itself, before the queue, so concurrent requests
# get the same replies in any order.
class SseServer
  Request = Struct.new(:path, :body, :verb, :headers, :raw)

  attr_reader :requests

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @replies = Queue.new
    @requests = []
    @responder = nil
    @thread = Thread.new { serve }
  end

  def url = "http://127.0.0.1:#{@server.addr[1]}"

  # `fate`: `after:` seconds to wait before answering, or `drop: true`.
  def reply(**)
    @replies << entry(**)
    self
  end

  # The block takes a Request and returns `reply`'s keywords, or nil to
  # take the next queued reply.
  def answer(&responder)
    @responder = responder
    self
  end

  def pending_replies = @replies.size
  def clear_replies = @replies.clear

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
    verb, path, headers = read_head(client)
    length = headers.fetch("content-length", "0").to_i
    body = length.positive? ? client.read(length) : ""
    request = Request.new(path, parsed(body, headers), verb, headers, body)
    @requests << request
    respond(client, request)
  end

  def entry(events: nil, json: nil, text: nil, status: "200 OK", **fate)
    if fate[:drop] then [:drop]
    elsif events then [:events, events]
    elsif text then [:text, text]
    else [:json, json, status, fate[:after]]
    end
  end

  def respond(client, request)
    answered = @responder&.call(request)
    return write_reply(client, *entry(**answered)) if answered
    return write_json(client, { error: { message: "no reply queued" } }, status: "500 Internal Server Error") if
      @replies.empty?

    write_reply(client, *@replies.pop)
  end

  def write_reply(client, kind, payload = nil, status = nil, after = nil)
    case kind
    when :drop then nil
    when :events then write_events(client, payload)
    when :text then write_text(client, payload)
    else
      sleep(after) if after
      write_json(client, payload, status:)
    end
  end

  def parsed(body, headers)
    return if body.empty?
    return body if headers["content-type"].to_s.start_with?("multipart/")

    JSON.parse(body)
  end

  def read_head(client)
    method, path = client.gets.to_s.split.first(2)
    headers = {}
    while (line = client.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end
    [method, path, headers]
  end

  def write_events(client, events)
    client.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n")
    events.each do |event|
      client.write(event.is_a?(String) ? event : "data: #{JSON.generate(event)}\n\n")
      client.flush
    end
  end

  def write_text(client, text)
    client.write("HTTP/1.1 200 OK\r\nContent-Type: application/binary\r\nContent-Length: #{text.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{text}")
  end

  def write_json(client, payload, status: "200 OK")
    body = JSON.generate(payload)
    client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{body}")
  end
end
