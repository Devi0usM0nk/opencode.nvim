---@class opencode.server.Opts
---Full URL of an OpenCode server, e.g. `"http://localhost:4096"`.
---Bypasses local process discovery and connects directly.
---You _must_ run `opencode` with the `--port` flag to expose its server.
---If pointing to a headless server, you _must_ attach a TUI via `opencode attach <URL>`.
---@field url? string | fun(callback: fun(url?: string))
---@field connect? boolean Whether to connect to an OpenCode server before interacting with it, listening for events and targeting it for future interactions.
---Which OpenCode server API to speak.
---OpenCode 1 (`opencode`) and OpenCode 2 (`opencode2`) have different, incompatible server APIs.
---`"auto"` detects the API of each server during connection.
---@field version? opencode.server.Version
---@field username? string Basic auth username.
---@field password? string Basic auth password.
---@field start? fun() | false Start an OpenCode server. Called when none are found; will retry after.

---An OpenCode server's API dialect.
---@alias opencode.server.Version "auto" | "v1" | "v2"

---An OpenCode server.
---@class opencode.server.Server
---@field url string
---Resolved server API dialect, e.g. `"v2"` for OpenCode 2. Never `"auto"` after connection.
---@field version opencode.server.Version
---Basic auth credentials, defaulting to `server.username`/`server.password`.
---Discovery may override these per-server, e.g. with an OpenCode 2 service registration's password.
---@field username? string
---@field password? string
---Server process ID and version, as reported by its health endpoint.
---@field pid? integer
---@field reported_version? string
---@field cwd string
---@field title string
---@field subagents opencode.server.Agent[]
---@field subscription_job_id? number
---@field heartbeat_timer? uv.uv_timer_t
local Server = {}
Server.__index = Server

---Built-in OpenCode commands.
---@alias opencode.server.Command
---| 'agent.cycle'
---| 'prompt.clear'
---| 'prompt.submit'
---| 'session.compact'
---| 'session.first'
---| 'session.half.page.up'
---| 'session.half.page.down'
---| 'session.interrupt'
---| 'session.last'
---| 'session.new'
---| 'session.page.up'
---| 'session.page.down'
---| 'session.share'
---| 'session.redo'
---| 'session.undo'

---@class opencode.server.Session
---@field id string
---@field title string
---@field time { created: integer, updated: integer }

---@class opencode.server.Agent
---@field name string
---@field description string
---@field mode "primary" | "subagent"

---@alias opencode.server.PermissionReply
---| "once"
---| "always"
---| "reject"

---Events emitted by OpenCode.
---Not exhaustive.
---OpenCode 2 events are normalized to these shapes on subscription (see `Server:normalize_event`),
---with its extra fields preserved.
---@alias opencode.server.Event
---| { type: "file.edited" }
---| { type: "filesystem.changed" }
---| { type: "permission.asked", properties: { id: number|string, permission: string, patterns: string[], metadata?: { diff: string, filepath: string } } }
---| { type: "permission.replied", properties: { requestID: number|string } }
---| { type: "server.connected" }
---| { type: "server.instance.disposed" }
---| { type: "session.status", properties: { status: { type: "idle" | "busy" | "error" | "retry" } } }
---| { type: "tui.command.execute", properties: { command: string } }
---| { type: string, properties: table }

---Attempt to connect to an OpenCode server and fetch its health and details.
---Rejects if the health fails — the last line of defense against false-positive server discovery.
---Rejection message is non-empty if from a valid OpenCode server.
---
---@param url string
---@param opts? { username?: string, password?: string } Overrides for configured credentials, e.g. from discovery.
---@return Promise<opencode.server.Server>
function Server.new(url, opts)
  local self = setmetatable({}, Server)
  self.url = url:gsub("/$", "")
  local server_opts = require("opencode.config").opts.server or {}
  self.username = (opts and opts.username) or server_opts.username
  self.password = (opts and opts.password) or server_opts.password
  self.heartbeat_timer = vim.uv.new_timer()

  local Promise = require("opencode.promise")
  -- Serially check health first to confirm that this is a valid and authenticated OpenCode server,
  -- detecting its API dialect (OpenCode 1 vs. OpenCode 2) along the way.
  -- Would like to differentiate headless servers, but not possible afaict unfortunately.
  -- No endpoint exposes such information, and TUI commands sent to a headless server with none attached just no-op, with no tell in the respone.
  -- So user must manually `opencode attach` in that case.
  return self
    :detect_version()
    :next(function()
      return require("opencode.promise").all({
        self:get_path(),
        self:get_sessions(),
        self:get_agents(),
      })
    end)
    :next(
      function(results) ---@param results { [1]: { directory: string, worktree: string }, [2]: opencode.server.Session[], [3]: opencode.server.Agent }
        self.cwd = results[1].directory or results[1].worktree
        self.title = results[2][1] and results[2][1].title or "<No sessions>"
        self.subagents = vim.tbl_filter(function(agent) ---@param agent opencode.server.Agent
          return agent.mode == "subagent"
        end, results[3])

        return Promise.resolve(self)
      end
    )
end

---Detect this server's API dialect by probing the health endpoint of each.
---OpenCode 2's server API lives under `/api`, so a valid `/api/health` response identifies it;
---otherwise we expect an OpenCode 1 server at `/global/health`.
---A configured `version` of `"v1"` or `"v2"` skips probing the other dialect.
---Sets `self.version` to `"v1"` or `"v2"` and rejects if neither dialect responds.
---
---@return Promise<opencode.server.Server>
function Server:detect_version()
  local Promise = require("opencode.promise")
  local configured = require("opencode.config").opts.server.version

  if configured == "v1" or configured == "v2" then
    self.version = configured
    return self:get_health():next(function()
      return Promise.resolve(self)
    end)
  end

  return Promise.new(function(resolve, reject)
    -- Probe OpenCode 2 first: its `/api/health` responds with `{ healthy, version, pid }`.
    -- Note that OpenCode 1 also answers `/api/health` with `{ healthy }`,
    -- so success alone is not enough to identify OpenCode 2.
    self:curl("/api/health", "GET", nil, function(response)
      if response.pid ~= nil then
        self.version = "v2"
        self.pid = tonumber(response.pid)
        self.reported_version = response.version
        resolve(self)
      else
        -- Not an OpenCode 2 response; fall back to OpenCode 1.
        self.version = "v1"
        self:get_health():next(function()
          resolve(self)
        end, reject)
      end
    end, function(msg, _, status)
      -- No OpenCode 2 response at all; fall back to OpenCode 1.
      self.version = "v1"
      self:get_health():next(function()
        resolve(self)
      end, function(v1_msg)
        reject(status == 401 and msg or v1_msg)
      end)
    end)
  end)
end

---Human-readable name, stripping the protocol prefix.
---
---@return string
function Server:display_name()
  local name = self.url:gsub("^%w+://", "")
  return name
end

---Resolve an endpoint path for this server's API dialect.
---OpenCode 2 serves its API under `/api`; OpenCode 1 does not.
---Paths already carrying the prefix pass through untouched.
---
---@param path string
---@return string
function Server:api_path(path)
  if self.version == "v2" and not path:find("^/api/") then
    return "/api" .. path
  end
  return path
end

---@param path string
---@param method "GET" | "POST"
---@param body table?
---@param on_success fun(response: table)
---@param on_error fun(msg: string, code: number, status: number?)
---@param opts? { persistent?: boolean }
---@return number job_id
function Server:curl(path, method, body, on_success, on_error, opts)
  local url = self.url .. self:api_path(path)
  opts = opts or {
    persistent = false,
  }

  local cmd = {
    "curl",
    "-s", -- Silent
    "-S", -- Except for errors/stderr
    "--fail-with-body",
    "-X",
    method,
    "-H",
    "Content-Type: application/json",
    "-H",
    "Accept: application/json",
    "-H",
    "Accept: text/event-stream",
    "-N",
  }

  if self.username and self.password then
    -- We can always send credentials; servers with no auth set just ignore them
    table.insert(cmd, "--user")
    table.insert(cmd, self.username .. ":" .. self.password)
  end

  if not opts.persistent then
    table.insert(cmd, "--max-time")
    table.insert(cmd, 2)
  end

  if body then
    table.insert(cmd, "-d")
    table.insert(cmd, vim.fn.json_encode(body))
  end

  table.insert(cmd, url)

  local response_buffer = {}
  local function process_response_buffer()
    if #response_buffer > 0 then
      local full_event = table.concat(response_buffer)
      response_buffer = {}
      vim.schedule(function()
        local ok, result = pcall(vim.fn.json_decode, full_event)
        if ok then
          if on_success then
            on_success(result)
          end
        else
          local error_message = "Failed to decode response from "
            .. url
            .. "\nResponse: "
            .. full_event
            .. "\nError: "
            .. result
          on_error(error_message, -1)
        end
      end)
    end
  end

  local stderr_lines = {}
  return vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      if not data then
        return
      end
      for _, line in ipairs(data) do
        if line ~= "" and line:sub(1, 1) == ":" then
          -- SSE comment (e.g. OpenCode 2 sends `: heartbeat`); not part of any event
        elseif line == "" and opts.persistent then
          process_response_buffer()
        else
          local clean_line = (line:gsub("^data: ?", ""))
          table.insert(response_buffer, clean_line)
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_lines, line)
          end
        end
      end
    end,
    on_exit = function(_, code)
      if code == 0 then
        process_response_buffer()
      else
        local response_message = #response_buffer > 0 and table.concat(response_buffer, "\n") or nil
        local stderr_message = #stderr_lines > 0 and table.concat(stderr_lines, "") or nil
        local status

        local detail_lines = { "Request to " .. url .. " failed with exit code: " .. code }
        if response_message and response_message ~= "" then
          table.insert(detail_lines, "Response:\n" .. response_message)
        end
        if stderr_message and stderr_message ~= "" then
          table.insert(detail_lines, "Stderr:\n" .. stderr_message)
          -- Afaict `curl` requires manual parsing of the response code one way or another regardless of flags :/
          status = stderr_message:match("The requested URL returned error: (%d+)$")
          status = tonumber(status)
        end

        local error_message = table.concat(detail_lines, "\n")
        on_error(error_message, code, status)
      end
    end,
  })
end

---@return Promise<any>
function Server:get_health()
  return require("opencode.promise").new(function(resolve, reject)
    local path = self.version == "v2" and "/api/health" or "/global/health"
    self:curl(path, "GET", nil, resolve, function(msg, _, status)
      if status == 401 then
        reject("Unauthorized response from OpenCode at " .. self:display_name())
      else
        reject(msg)
      end
    end)
  end)
end

---@param text string
---@return Promise<any>
function Server:tui_append_prompt(text)
  return require("opencode.promise").new(function(resolve, reject)
    if self.version == "v2" then
      self:curl("/tui/append-prompt", "POST", { text = text }, resolve, reject)
    else
      self:curl("/tui/publish", "POST", { type = "tui.prompt.append", properties = { text = text } }, resolve, reject)
    end
  end)
end

---@param command opencode.server.Command | string
---@return Promise<any>
function Server:tui_execute_command(command)
  return require("opencode.promise").new(function(resolve, reject)
    if self.version == "v2" then
      self:curl("/tui/execute-command", "POST", { command = command }, resolve, reject)
    else
      self:curl(
        "/tui/publish",
        "POST",
        { type = "tui.command.execute", properties = { command = command } },
        resolve,
        reject
      )
    end
  end)
end

---@param permission number|string
---@param reply opencode.server.PermissionReply
---@return Promise<any>
function Server:permit(permission, reply)
  return require("opencode.promise").new(function(resolve, reject)
    self:curl("/permission/" .. permission .. "/reply", "POST", { reply = reply }, resolve, reject)
  end)
end

---@return Promise<opencode.server.Agent[]>
function Server:get_agents()
  return require("opencode.promise").new(function(resolve, reject)
    self:curl("/agent", "GET", nil, function(response)
      -- OpenCode 2 envelopes list responses in `{ data = ... }`
      resolve(self.version == "v2" and response.data or response)
    end, reject)
  end)
end

---@return Promise<opencode.server.Session[]>
function Server:get_sessions()
  return require("opencode.promise").new(function(resolve, reject)
    self:curl("/session", "GET", nil, function(response)
      -- OpenCode 2 envelopes list responses in `{ data = ... }`
      resolve(self.version == "v2" and response.data or response)
    end, reject)
  end)
end

---@param session_id string
---@return Promise<any>
function Server:select_session(session_id)
  return require("opencode.promise").new(function(resolve, reject)
    self:curl("/tui/select-session", "POST", { sessionID = session_id }, resolve, reject)
  end)
end

---@return Promise<{ directory: string, worktree: string }>
function Server:get_path()
  return require("opencode.promise").new(function(resolve, reject)
    -- OpenCode 2 renamed this endpoint; its `Location.Info` still carries a `directory`
    self:curl(self.version == "v2" and "/location" or "/path", "GET", nil, resolve, reject)
  end)
end

---@param on_success fun(response: opencode.server.Event) Invoked with each received event.
---@param on_error fun(msg: string?, code: number)
---@return number job_id
function Server:sse_subscribe(on_success, on_error)
  return self:curl("/event", "GET", nil, function(response)
    on_success(self.version == "v2" and self:normalize_event(response) or response)
  end, on_error, { persistent = true })
end

---Normalize an OpenCode 2 event to this plugin's event shape (OpenCode 1's).
---OpenCode 2 wraps payload fields in `data` instead of `properties`,
---and names permission actions `action` instead of `permission`.
---Extra OpenCode 2 fields are preserved.
---
---@param response table
---@return opencode.server.Event
function Server:normalize_event(response)
  local properties = response.data or {}
  if properties.action ~= nil and properties.permission == nil then
    properties.permission = properties.action
  end
  response.properties = properties
  return response
end

---How often OpenCode sends heartbeat events.
local OPENCODE_HEARTBEAT_INTERVAL_MS = 10000

---The currently connected server.
---Cleared when the server disposes itself, the connection errors, or the heartbeat disappears.
---@type opencode.server.Server?
Server.connected = nil

---Subscribe to this server's SSE stream and dispatch autocmds for received events.
---Disconnects currently connected server first.
---Idempotent.
---
---@return Promise<opencode.server.Server> server Promise that resolves or rejects according to initial connection success.
function Server:connect()
  local Promise = require("opencode.promise")

  if Server.connected == self then
    return Promise.resolve(self)
  elseif Server.connected then
    Server.connected:disconnect()
  end

  return Promise.new(function(resolve, reject)
    self.subscription_job_id = self:sse_subscribe(
      function(response)
        if self.heartbeat_timer then
          self.heartbeat_timer:start(
            OPENCODE_HEARTBEAT_INTERVAL_MS + 1000,
            0,
            vim.schedule_wrap(function()
              self:disconnect()
            end)
          )
        end

        if response.type == "server.connected" then
          Server.connected = self
          resolve(self)
        elseif response.type == "server.instance.disposed" then
          self:disconnect()
        end

        require("opencode.events").emit(response, self)
      end,
      -- Server disappeared ungracefully, e.g. process killed, network error, etc.
      -- Also called on manual disconnects, like our `vim.fn.jobstop`.
      function(msg)
        local was_connected = Server.connected == self
        self:disconnect()
        if not was_connected then
          reject(msg)
        end
      end
    )
  end)
end

---Unsubscribe from this server's SSE stream and stop the heartbeat timer.
---Idempotent.
function Server:disconnect()
  if self.subscription_job_id then
    vim.fn.jobstop(self.subscription_job_id)
    self.subscription_job_id = nil
  end
  if self.heartbeat_timer then
    self.heartbeat_timer:stop()
  end

  if Server.connected == self then
    Server.connected = nil
    require("opencode.events.status").reset()
  end
end

return Server
