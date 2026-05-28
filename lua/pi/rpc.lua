local runner = require("pi.runner")
local proc = require("pi.process")

local M = {}

local process = nil
local rpc_cmd = nil
local is_running = false
local is_busy = false
local stdout_tail = ""
local stderr_tail = ""
local current_handlers = nil
local startup_error = nil

local function feed_stdout(chunk)
  stdout_tail = proc.feed_lines(stdout_tail, chunk, function(line)
    local event = runner.decode_event(line)
    if event then
      local normalized = runner.normalize(event)
      if normalized and current_handlers and current_handlers.on_event then
        current_handlers.on_event(normalized)
        if normalized.type == "done" or normalized.type == "error" then
          is_busy = false
        end
      end
    elseif current_handlers and current_handlers.on_error then
      current_handlers.on_error("unparseable RPC event: " .. line)
    end
  end)
end

local function feed_stderr(chunk)
  stderr_tail = proc.feed_lines(stderr_tail, chunk, function(line)
    if current_handlers and current_handlers.on_stderr then
      current_handlers.on_stderr(line)
    end
  end)
end

function M.start(cmd)
  if is_running then
    if process and process:is_closing() then
      is_running = false
      is_busy = false
      process = nil
    else
      return true
    end
  end

  startup_error = nil
  rpc_cmd = cmd

  local ok, handle = proc.spawn(cmd, {
    on_stdout = feed_stdout,
    on_stderr = feed_stderr,
    on_error = function(err)
      if current_handlers and current_handlers.on_error then
        current_handlers.on_error(err)
      else
        startup_error = tostring(err)
      end
    end,
    on_exit = function(result)
      is_running = false
      is_busy = false
      if current_handlers and current_handlers.on_exit then
        current_handlers.on_exit(result)
      elseif not startup_error and result.code ~= 0 and result.code ~= 143 and result.code ~= 124 then
        startup_error = "pi RPC exited with code " .. result.code
      end
      current_handlers = nil
    end,
  })

  if not ok then
    return false, handle
  end

  process = handle
  is_running = true
  return true
end

function M.stop()
  if not is_running or not process then return end

  current_handlers = nil

  pcall(process.write, process, nil)

  if not process:is_closing() then
    pcall(process.kill, process, 15)
  end

  process = nil
  is_running = false
  is_busy = false
  stdout_tail = ""
  stderr_tail = ""
end

function M.restart()
  local cmd = rpc_cmd
  M.stop()
  if cmd then
    return M.start(cmd)
  end
  return false, "no cmd stored"
end

function M.is_running()
  return is_running
end

function M.send(message, handlers)
  if not is_running or not process then
    if handlers and handlers.on_error then
      handlers.on_error("RPC process is not running")
    end
    return
  end

  if process:is_closing() then
    is_running = false
    is_busy = false
    process = nil
    if handlers and handlers.on_error then
      handlers.on_error("RPC process has exited unexpectedly")
    end
    return
  end

  local payload = vim.json.encode(message) .. "\n"
  local ok, err = pcall(process.write, process, payload)
  if not ok then
    if handlers and handlers.on_error then
      handlers.on_error("failed to write to RPC process: " .. tostring(err))
    end
    return
  end

  if handlers then
    current_handlers = handlers
  end
end

function M.prompt(payload, handlers)
  if not is_running or not process then
    local msg = startup_error or "RPC process is not running"
    startup_error = nil
    if handlers and handlers.on_error then
      handlers.on_error(msg)
    end
    return
  end

  if process:is_closing() then
    is_running = false
    is_busy = false
    process = nil
    local msg = startup_error or "RPC process has exited unexpectedly"
    startup_error = nil
    if handlers and handlers.on_error then
      handlers.on_error(msg)
    end
    return
  end

  if is_busy then
    if handlers and handlers.on_error then
      handlers.on_error("RPC process is busy")
    end
    return
  end

  stdout_tail = ""
  stderr_tail = ""

  is_busy = true

  if handlers then
    current_handlers = handlers
  end

  local ok, err = pcall(process.write, process, payload)
  if not ok then
    is_busy = false
    current_handlers = nil
    if handlers and handlers.on_error then
      handlers.on_error("failed to write prompt payload: " .. tostring(err))
    end
  end
end

function M.abort()
  if not is_running or not process or not is_busy then return end
  pcall(process.write, process, '{"type":"abort"}\n')
end

do
  local autocmd_registered = false
  function M._setup_autocmd()
    if autocmd_registered then return end
    autocmd_registered = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        if is_running then
          current_handlers = nil
          M.stop()
        end
      end,
    })
  end
end

return M
