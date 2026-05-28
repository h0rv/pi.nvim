local M = {}

function M.feed_lines(tail, chunk, on_line)
  if not chunk or chunk == "" then return tail end

  tail = (tail or "") .. chunk

  while true do
    local nl = tail:find("\n", 1, true)
    if not nl then break end
    local line = tail:sub(1, nl - 1)
    tail = tail:sub(nl + 1)
    if line ~= "" then on_line(line) end
  end

  return tail
end

function M.spawn(cmd, callbacks)
  return pcall(vim.system, cmd, {
    text = true,
    stdin = true,
    stdout = vim.schedule_wrap(function(err, data)
      if err then
        if callbacks.on_error then callbacks.on_error(err) end
        return
      end
      if callbacks.on_stdout then callbacks.on_stdout(data) end
    end),
    stderr = vim.schedule_wrap(function(err, data)
      if err then
        if callbacks.on_error then callbacks.on_error(err) end
        return
      end
      if callbacks.on_stderr then callbacks.on_stderr(data) end
    end),
  }, vim.schedule_wrap(function(result)
    if callbacks.on_exit then callbacks.on_exit(result) end
  end))
end

return M
