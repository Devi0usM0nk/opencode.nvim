local M = {}

---@type "idle" | "busy" | "error" | nil
local status = nil
---@type string?
M.url = nil

---@return string
function M.statusline()
  local url = (M.url and (" " .. M.url:gsub("^%w+://", "")) or "")
  return M.icon() .. url
end

---@return "󰚩" | "󱜙" | "󱚡" | "󱚧"
function M.icon()
  if status == "idle" then
    return "󰚩"
  elseif status == "busy" then
    return "󱜙"
  elseif status == "error" then
    return "󱚡"
  else
    return "󱚧"
  end
end

---@param event opencode.server.Event
---@param url string
function M.update(event, url)
  M.url = url

  if
    event.type == "server.connected" or (event.type == "session.status" and event.properties.status.type == "idle")
  then
    status = "idle"
  elseif
    event.type == "session.status"
    and (event.properties.status.type == "busy" or event.properties.status.type == "retry")
  then
    -- OpenCode 2 reports transient failures as `retry`; show it as activity
    status = "busy"
  elseif event.type == "session.status" and event.properties.status.type == "error" then
    status = "error"
  elseif event.type == "server.instance.disposed" then
    M.reset()
  end
end

function M.reset()
  status = nil
  M.url = nil
end

return M
