local process = require("pi.process")

local M = {}

local function decode_event(line)
  local ok, decoded = pcall(vim.json.decode, line)
  if not ok then
    return nil
  end
  return decoded
end

local function normalize(event)
  if not event or not event.type then
    return nil
  end

  if event.type == "message_update" then
    local delta = event.assistantMessageEvent
    if delta and delta.type == "thinking_delta" then
      return { type = "thinking" }
    end
    if delta and delta.type == "error" then
      return { type = "error", message = delta.reason or "unknown error" }
    end
    return nil
  end

  if event.type == "tool_execution_start" then
    return { type = "tool_start", tool = event.toolName or "unknown" }
  end

  if event.type == "tool_execution_end" then
    return { type = "tool_end", tool = event.toolName or "unknown" }
  end

  if event.type == "agent_end" then
    return { type = "done" }
  end

  if event.type == "response" and event.success == false then
    return { type = "error", message = event.error or "unknown error" }
  end

  return nil
end

local function feed_stream(session, key, chunk, on_event, on_error)
  if session.cancelled then return end

  session[key] = process.feed_lines(session[key] or "", chunk, function(line)
    local event = decode_event(line)
    if event then
      local normalized = normalize(event)
      if normalized then on_event(normalized) end
    elseif on_error then
      on_error(line)
    end
  end)
end

function M.start(session, cmd, payload, handlers)
  session.stdout_tail = ""
  session.stderr_tail = ""

  local ok, proc = process.spawn(cmd, {
    on_stdout = function(data)
      feed_stream(session, "stdout_tail", data, handlers.on_event, nil)
    end,
    on_stderr = function(data)
      feed_stream(session, "stderr_tail", data, function() end, function(line)
        handlers.on_stderr(line)
      end)
    end,
    on_error = handlers.on_error,
    on_exit = function(result)
      if session.cancelled then
        handlers.on_exit({ code = 0, signal = 15 })
        return
      end

      if session.stdout_tail and session.stdout_tail ~= "" then
        local event = decode_event(session.stdout_tail)
        if event then
          local normalized = normalize(event)
          if normalized then handlers.on_event(normalized) end
        end
        session.stdout_tail = ""
      end

      if session.stderr_tail and session.stderr_tail ~= "" then
        handlers.on_stderr(session.stderr_tail)
        session.stderr_tail = ""
      end

      handlers.on_exit(result)
    end,
  })

  if not ok then
    return nil, proc
  end

  local wrote, write_err = pcall(proc.write, proc, payload)
  if not wrote then
    pcall(proc.kill, proc, 15)
    return nil, write_err
  end

  return proc
end

function M.finish(session)
  if not session or not session.process then
    return
  end

  local stdin = session.process._state and session.process._state.stdin
  if stdin then
    pcall(function()
      stdin:close()
    end)
  elseif not session.process:is_closing() then
    pcall(session.process.kill, session.process, 15)
  end
end

function M.cancel(session)
  if session.process and not session.process:is_closing() then
    pcall(session.process.kill, session.process, 15)
  end
end

M.decode_event = decode_event
M.normalize = normalize

return M
