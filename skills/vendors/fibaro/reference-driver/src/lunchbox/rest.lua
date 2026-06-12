local socket = require "cosock.socket"
local Request = require "luncheon.request"
local Response = require "luncheon.response"
local log = require "log"

local lb_utils = require "lunchbox.util"
local utils = require "utils"

local RestClient = {}
RestClient.__index = RestClient

local function copy_response_headers(source, target)
  for header in source.headers:iter() do
    target.headers:append_chunk(header)
  end
end

local function empty_body_response(original_response)
  local full_response = Response.new(original_response.status, nil)
  copy_response_headers(original_response, full_response)
  full_response._received_body = true
  full_response._parsed_headers = true
  log.info_with({hub_logs = true}, string.format(
    "[Fibaro] HTTP response has no body framing, treating status %s as empty body",
    tostring(original_response.status)
  ))
  return full_response
end

local function connect(client)
  local use_ssl = client.base_url.scheme == "https"
  local sock, err = client.socket_builder(client.base_url.host, client.base_url.port, use_ssl)
  if sock == nil then
    client.socket = nil
    return false, err
  end

  client.socket = sock
  return true, nil
end

local function reconnect(client)
  if client.socket ~= nil then
    client.socket:close()
    client.socket = nil
  end

  return connect(client)
end

local function send_request(client, request)
  if client.socket == nil then
    return nil, "no socket available"
  end

  local payload = request:serialize()
  local bytes, err, idx = nil, nil, 0
  repeat
    bytes, err, idx = client.socket:send(payload, idx + 1, #payload)
  until (bytes == #payload) or (err ~= nil)

  return bytes, err
end

local function recv_additional_response(original_response, sock)
  local full_response = Response.new(original_response.status, nil)
  local headers = original_response:get_headers()
  local content_length = tonumber(headers:get_one("Content-Length") or "0")

  copy_response_headers(original_response, full_response)

  if content_length <= 0 then
    full_response._received_body = true
    full_response._parsed_headers = true
    log.info_with({hub_logs = true}, string.format(
      "[Fibaro] HTTP response has Content-Length 0, treating status %s as empty body",
      tostring(original_response.status)
    ))
    return full_response
  end

  local total = 0
  repeat
    local next_recv, next_err, partial = sock:receive(content_length - total)

    if next_recv ~= nil and #next_recv >= 1 then
      total = total + #next_recv
      full_response:append_body(next_recv)
    end

    if partial ~= nil and #partial >= 1 then
      total = total + #partial
      full_response:append_body(partial)
    end

    if next_err ~= nil and next_err ~= "closed" then
      return nil, next_err
    end
  until total >= content_length

  full_response._received_body = true
  full_response._parsed_headers = true
  return full_response
end

local function parse_chunked_response(original_response, sock)
  local full_response = Response.new(original_response.status, nil)
  copy_response_headers(original_response, full_response)

  -- Read the first chunk size line directly from the socket.
  -- Do NOT call original_response:get_body() here because that triggers
  -- luncheon's internal chunked body parser which uses self._source(pattern),
  -- but our source function (created in handle_response) only supports
  -- line-by-line reading via sock:receive("*l") and ignores byte-count
  -- arguments, causing tonumber(nil, 16) crash on real Fibaro devices
  -- that use Transfer-Encoding: chunked.
  local chunk_size_line, line_err = sock:receive("*l")
  if not chunk_size_line then
    return nil, "failed to read chunk size: " .. tostring(line_err)
  end

  local next_chunk_bytes = tonumber(chunk_size_line, 16)
  local next_chunk_body = ""
  local bytes_read = 0
  local expecting_body = true

  repeat
    local pattern = expecting_body and next_chunk_bytes or "*l"
    local next_recv, next_err, partial = sock:receive(pattern)

    if next_err ~= nil then
      if string.lower(next_err) == "closed" then
        if partial ~= nil and #partial >= 1 then
          full_response:append_body(partial)
          next_chunk_bytes = 0
        end
      else
        return nil, ("unexpected error reading chunked transfer: " .. next_err)
      end
    end

    if next_recv ~= nil and #next_recv >= 1 then
      if expecting_body then
        bytes_read = bytes_read + #next_recv
        next_chunk_body = next_chunk_body .. next_recv

        if bytes_read >= next_chunk_bytes then
          full_response:append_body(next_chunk_body)
          next_chunk_body = ""
          bytes_read = 0
          expecting_body = false
        end
      else
        next_chunk_bytes = tonumber(next_recv, 16)
        expecting_body = true
      end
    end
  until next_chunk_bytes == 0

  sock:receive("*l")
  full_response._received_body = true
  full_response._parsed_headers = true
  return full_response
end

local function handle_response(sock)
  local initial_recv, initial_err, partial = Response.source(function() return sock:receive("*l") end)
  if initial_recv == nil then
    return nil, initial_err, partial
  end

  local headers = initial_recv:get_headers()
  if headers:get_one("Content-Length") then
    return recv_additional_response(initial_recv, sock)
  end

  if tostring(headers:get_one("Transfer-Encoding") or ""):lower() == "chunked" then
    return parse_chunked_response(initial_recv, sock)
  end

  return empty_body_response(initial_recv), nil, nil
end

local function execute_request(client, request, retry_fn)
  if client.socket == nil then
    local success, err = connect(client)
    if not success then return nil, err end
  end

  local should_retry = retry_fn or function() return false end
  local backoff = utils.backoff_builder(10, 1, 0.1)

  while true do
    local retry = should_retry()
    local _, send_err = send_request(client, request)
    if send_err == nil then
      local response, recv_err = handle_response(client.socket)
      if recv_err == nil then
        return response, nil
      end

      if not retry then
        return nil, recv_err
      end
    else
      if not retry then
        return nil, send_err
      end
    end

    local success, err = reconnect(client)
    if not success and not retry then
      return nil, err
    end

    socket.sleep(backoff())
  end
end

function RestClient.new(base_url, socket_builder)
  base_url = lb_utils.force_url_table(base_url)
  if type(socket_builder) ~= "function" then
    socket_builder = utils.labeled_socket_builder()
  end

  return setmetatable({
    base_url = base_url,
    socket_builder = socket_builder,
    socket = nil,
  }, RestClient)
end

function RestClient:shutdown()
  if self.socket ~= nil then
    self.socket:close()
    self.socket = nil
  end
end

function RestClient:get(path, additional_headers, retry_fn)
  local request = Request.new("GET", path, nil)
    :add_header("user-agent", "smartthings-lua-edge-driver")
    :add_header("host", tostring(self.base_url.host))
    :add_header("connection", "keep-alive")

  if type(additional_headers) == "table" then
    for k, v in pairs(additional_headers) do
      request = request:add_header(k, v)
    end
  end

  return execute_request(self, request, retry_fn)
end

function RestClient:post(path, body_string, additional_headers, retry_fn)
  local request = Request.new("POST", path, nil)
    :add_header("user-agent", "smartthings-lua-edge-driver")
    :add_header("host", tostring(self.base_url.host))
    :add_header("connection", "keep-alive")

  if type(additional_headers) == "table" then
    for k, v in pairs(additional_headers) do
      request = request:add_header(k, v)
    end
  end

  request = request:append_body(body_string or "")
  return execute_request(self, request, retry_fn)
end

return RestClient
