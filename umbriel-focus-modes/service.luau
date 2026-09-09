--!nonstrict

local PREFIX = "Umbriel Focus Modes: "
local STATUS_KEY = "status"
local STREAM_DISCONNECTED = "__UMBRIEL_FOCUS_MODES_DISCONNECTED__"
local CONFIG_DIR = noctalia.expandPath("~/.config/umbriel")
local FRAGMENT_PATH = CONFIG_DIR .. "/umbriel-focus-modes.toml"
local STAGED_PATH = CONFIG_DIR .. "/.umbriel-focus-modes.toml.tmp"
local ROLLBACK_PATH = CONFIG_DIR .. "/.umbriel-focus-modes.toml.rollback"

local connected = false
local unavailableLogged = false
local snapshotInFlight = false
local snapshotPending = false
local applyInFlight = false
local pendingValue = nil
local currentLayout = nil
local currentOutput = nil
local currentWorkspace = nil
local lastApplied = nil
local originalValue = true
local activeByOutput = {}
local activeOutputCount = 0

local function boolText(value)
  return value and "true" or "false"
end

local function parseFragmentValue(contents)
  if type(contents) ~= "string" then
    return nil
  end
  for line in string.gmatch(contents, "[^\r\n]+") do
    local value = string.match(line, "^%s*follows_mouse%s*=%s*(%a+)")
    if value == "true" then
      return true
    elseif value == "false" then
      return false
    end
  end
  return nil
end

local function parseOriginalValue(contents)
  if type(contents) ~= "string" then
    return nil
  end
  for line in string.gmatch(contents, "[^\r\n]+") do
    local value = string.match(line, "^%s*#%s*original_follows_mouse%s*=%s*(%a+)")
    if value == "true" then
      return true
    elseif value == "false" then
      return false
    end
  end
  return nil
end

local initialFragment = noctalia.readFile(FRAGMENT_PATH)
local parsedOriginal = parseOriginalValue(initialFragment)
if parsedOriginal ~= nil then
  originalValue = parsedOriginal
end
lastApplied = parseFragmentValue(initialFragment)

local function automaticEnabled()
  return noctalia.getConfig("automatic") ~= false
end

local function desiredForLayout(layout)
  if not automaticEnabled() then
    return originalValue
  elseif layout == "scrolling" then
    return noctalia.getConfig("scrolling_follow_mouse") == true
  elseif layout == "dwindle" then
    return noctalia.getConfig("dwindle_follow_mouse") ~= false
  elseif layout == "master" then
    return noctalia.getConfig("master_follow_mouse") ~= false
  end
  return nil
end

local function publishStatus(errorMessage)
  noctalia.state.set(STATUS_KEY, {
    connected = connected,
    enabled = automaticEnabled(),
    layout = currentLayout or "unknown",
    output = currentOutput or "",
    workspace = currentWorkspace or "",
    followMouse = lastApplied,
    error = errorMessage or "",
  })
end

local function setConnected(value)
  if connected == value then
    return
  end
  connected = value
  if value then
    unavailableLogged = false
    noctalia.log(PREFIX .. "connected to Umbriel IPC")
  elseif not unavailableLogged then
    noctalia.log(PREFIX .. "Umbriel IPC unavailable; retrying in 5 seconds")
    unavailableLogged = true
  end
  publishStatus()
end

local function renderFragment(value)
  return "# Managed by Noctalia plugin raell/umbriel-focus-modes.\n"
    .. "# Remove only through the plugin removal procedure in README.md.\n"
    .. "# original_follows_mouse = " .. boolText(originalValue) .. "\n\n"
    .. "[input.focus]\n"
    .. "follows_mouse = " .. boolText(value) .. "\n"
end

local requestApply

local function finishApply()
  applyInFlight = false
  if pendingValue ~= nil then
    local value = pendingValue
    pendingValue = nil
    requestApply(value)
  end
end

local function restorePrevious(previousContents, previousValue, message)
  local ok, err = noctalia.writeFile(ROLLBACK_PATH, previousContents)
  if ok then
    ok, err = noctalia.renameFile(ROLLBACK_PATH, FRAGMENT_PATH)
  end
  lastApplied = previousValue
  publishStatus(message)
  if ok then
    noctalia.log(PREFIX .. message .. "; restored previous fragment")
  else
    noctalia.log(PREFIX .. message .. "; rollback failed: " .. tostring(err))
  end
  finishApply()
end

requestApply = function(value)
  if type(value) ~= "boolean" then
    return
  end
  if applyInFlight then
    pendingValue = value
    return
  end
  if lastApplied == value then
    publishStatus()
    return
  end

  local previousContents = noctalia.readFile(FRAGMENT_PATH)
  if type(previousContents) ~= "string" then
    previousContents = renderFragment(originalValue)
  end
  local previousValue = parseFragmentValue(previousContents)
  local nextContents = renderFragment(value)

  if previousContents == nextContents then
    lastApplied = value
    publishStatus()
    return
  end

  applyInFlight = true
  local wrote, writeErr = noctalia.writeFile(STAGED_PATH, nextContents)
  if not wrote then
    noctalia.log(PREFIX .. "could not stage focus fragment: " .. tostring(writeErr))
    publishStatus("fragment write failed")
    finishApply()
    return
  end

  local validationStarted = noctalia.runAsync({ "umbriel", "validate", "-c", STAGED_PATH }, function(stagedResult)
    if stagedResult.exitCode ~= 0 then
      noctalia.removeFile(STAGED_PATH)
      noctalia.log(PREFIX .. "staged fragment validation failed: " .. noctalia.string.trim(stagedResult.stderr))
      publishStatus("staged fragment validation failed")
      finishApply()
      return
    end

    local renamed, renameErr = noctalia.renameFile(STAGED_PATH, FRAGMENT_PATH)
    if not renamed then
      noctalia.log(PREFIX .. "atomic fragment replacement failed: " .. tostring(renameErr))
      publishStatus("atomic fragment replacement failed")
      finishApply()
      return
    end

    local fullValidationStarted = noctalia.runAsync({ "umbriel", "validate" }, function(fullResult)
      if fullResult.exitCode ~= 0 then
        restorePrevious(previousContents, previousValue, "full configuration validation failed")
        return
      end

      local oldValue = lastApplied
      lastApplied = value
      publishStatus()
      noctalia.log(PREFIX .. "follows_mouse " .. boolText(oldValue) .. " -> " .. boolText(value))
      finishApply()
    end)

    if not fullValidationStarted then
      restorePrevious(previousContents, previousValue, "could not start full configuration validation")
    end
  end)

  if not validationStarted then
    noctalia.removeFile(STAGED_PATH)
    noctalia.log(PREFIX .. "could not start staged fragment validation")
    publishStatus("could not start fragment validation")
    finishApply()
  end
end

local function applyCurrentLayout()
  local desired = desiredForLayout(currentLayout)
  if desired ~= nil then
    requestApply(desired)
  elseif not automaticEnabled() then
    requestApply(originalValue)
  end
end

local function setFocusedWorkspace(workspace)
  if type(workspace) ~= "table" or type(workspace.layout) ~= "string" then
    return
  end
  local workspaceId = workspace.id or workspace.name
  if currentLayout == workspace.layout
      and currentOutput == workspace.output
      and currentWorkspace == workspaceId then
    return
  end
  local previousLayout = currentLayout
  currentLayout = workspace.layout
  currentOutput = workspace.output
  currentWorkspace = workspaceId
  if previousLayout ~= nil and previousLayout ~= currentLayout then
    noctalia.log(PREFIX .. "focused layout changed " .. previousLayout .. " -> " .. currentLayout)
  end
  publishStatus()
  applyCurrentLayout()
end

local function updateWorkspaceState(workspaces)
  if type(workspaces) ~= "table" then
    return false
  end

  local nextActiveByOutput = {}
  local focusedWorkspace = nil
  for _, workspace in ipairs(workspaces) do
    if type(workspace) == "table" then
      if workspace.active == true and type(workspace.output) == "string" then
        nextActiveByOutput[workspace.output] = workspace
      end
      if workspace.focused == true then
        focusedWorkspace = workspace
      end
    end
  end

  activeByOutput = nextActiveByOutput
  activeOutputCount = 0
  for _ in pairs(activeByOutput) do
    activeOutputCount = activeOutputCount + 1
  end
  if focusedWorkspace ~= nil then
    setFocusedWorkspace(focusedWorkspace)
  else
    local output = noctalia.focusedOutputName()
    if output ~= nil and activeByOutput[output] ~= nil then
      setFocusedWorkspace(activeByOutput[output])
    end
  end
  return true
end


local function handleJsonLine(line)
  if line == STREAM_DISCONNECTED then
    setConnected(false)
    return
  end


  local decoded = noctalia.json.decode(line)
  if type(decoded) ~= "table" then
    return
  end
  if decoded.event == "workspaces" and updateWorkspaceState(decoded.data) then
    setConnected(true)
  end
end

local function requestSnapshot()
  if snapshotInFlight then
    snapshotPending = true
    return
  end
  snapshotInFlight = true
  local started = noctalia.runAsync({ "umbriel", "workspaces", "--json" }, function(result)
    if result.exitCode == 0 then
      local workspaces = noctalia.json.decode(result.stdout)
      if updateWorkspaceState(workspaces) then
        setConnected(true)
      end
    else
      setConnected(false)
    end

    snapshotInFlight = false
    if snapshotPending then
      snapshotPending = false
      requestSnapshot()
    end
  end)
  if not started then
    snapshotInFlight = false
    setConnected(false)
  end
end

local function startEventStream()
  local command = "while true; do umbriel subscribe workspaces 2>/dev/null; "
    .. "printf '%s\\n' '" .. STREAM_DISCONNECTED .. "'; sleep 5; done"
  local started = noctalia.runStream(command, handleJsonLine)
  if not started then
    noctalia.log(PREFIX .. "could not start Umbriel IPC stream")
    publishStatus("could not start IPC stream")
  end
end

local function restoreOriginalOnExit()
  if lastApplied == originalValue then
    return
  end
  local contents = renderFragment(originalValue)
  local ok, err = noctalia.writeFile(STAGED_PATH, contents)
  if ok then
    ok, err = noctalia.renameFile(STAGED_PATH, FRAGMENT_PATH)
  end
  if ok then
    lastApplied = originalValue
    noctalia.runAsync({ "umbriel", "validate" })
  else
    noctalia.log(PREFIX .. "could not restore original follows_mouse on exit: " .. tostring(err))
  end
end

function onConfigChanged()
  applyCurrentLayout()
end

function onIpc(event, _payload)
  if event == "refresh" then
    requestSnapshot()
  elseif event == "status" then
    noctalia.log(PREFIX .. "layout=" .. tostring(currentLayout)
      .. " output=" .. tostring(currentOutput)
      .. " follows_mouse=" .. tostring(lastApplied)
      .. " connected=" .. tostring(connected))
  end
end

function onExit(_signal, reason)
  if reason == "disable" or reason == "uninstall" then
    restoreOriginalOnExit()
  end
end

noctalia.setUpdateInterval(500)

function update()
  if activeOutputCount > 1 then
    requestSnapshot()
  end
end

publishStatus()
if not noctalia.commandExists("umbriel") then
  noctalia.log(PREFIX .. "Umbriel is required but was not found on PATH")
  publishStatus("Umbriel is not installed")
else
  requestSnapshot()
  startEventStream()
end
