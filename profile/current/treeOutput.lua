-- Tree-style output handler for Busted
-- Displays nested describe/it blocks with indentation, similar to Mocha/Node.js

local function write(message)
  io.write("[mudlet-busted] " .. tostring(message or '') .. '\n')
end

return function(options)
  local busted = require('busted')
  local handler = require('busted.outputHandlers.base')()

  -- Symbols (UTF-8 via string.char for Lua 5.1 compat)
  local successSymbol = string.char(0xe2, 0x9c, 0x93)  -- ✓
  local failureSymbol = string.char(0xe2, 0x9c, 0x97)  -- ✗
  local pendingSymbol = '?'
  local errorSymbol   = string.char(0xe2, 0x8a, 0x98)  -- ⊘

  -- ANSI colours
  local green   = '\27[38;5;046m'
  local red     = '\27[38;5;196m'
  local yellow  = '\27[38;5;220m'
  local pink    = '\27[38;5;211m'
  local dim     = '\27[38;5;240m'
  local reset   = '\27[0m'
  local bold    = '\27[1m'

  -- Track describe depth
  local depth = 0
  local startTime = os.clock()

  local function indent(d)
    return string.rep('  ', d)
  end

  handler.describeStart = function(element, parent)
    local name = element.name or ''
    if #name > 0 then
      write(indent(depth) .. bold .. name .. reset)
    end
    depth = depth + 1
    return nil, true
  end

  handler.describeEnd = function(element, parent)
    depth = math.max(0, depth - 1)
    return nil, true
  end

  handler.testEnd = function(element, parent, status, debug)
    local name = element.name or '(unnamed)'

    if status == 'success' then
      handler.successesCount = handler.successesCount + 1
      write(indent(depth) .. green .. successSymbol .. reset .. dim .. ' ' .. name .. reset)
    elseif status == 'pending' then
      handler.pendingsCount = handler.pendingsCount + 1
      local pending = handler.pendings[#handler.pendings]
      local msg = pending and pending.message
      local output = indent(depth) .. pink .. pendingSymbol .. ' ' .. name
      if msg then
        output = output .. dim .. ' (' .. msg .. ')'
      end
      write(output .. reset)
    elseif status == 'failure' then
      handler.failuresCount = handler.failuresCount + 1
      local failure = handler.failures[#handler.failures]
      write(indent(depth) .. red .. failureSymbol .. ' ' .. name .. reset)
      if failure then
        local msg = tostring(failure.message or failure)
        for line in msg:gmatch('[^\n]+') do
          write(indent(depth + 1) .. red .. line .. reset)
        end
      end
    elseif status == 'error' then
      handler.errorsCount = handler.errorsCount + 1
      local err = handler.errors[#handler.errors]
      write(indent(depth) .. red .. errorSymbol .. ' ' .. name .. reset)
      if err then
        local msg = tostring(err.message or err)
        for line in msg:gmatch('[^\n]+') do
          write(indent(depth + 1) .. red .. line .. reset)
        end
      end
    end

    return nil, true
  end

  handler.suiteStart = function(suite, count, total)
    if count == 1 then
      startTime = os.clock()
      write('')
    end
    return nil, true
  end

  handler.suiteEnd = function()
    local elapsed = os.clock() - startTime

    write('')
    local summary = green .. '  ' .. handler.successesCount .. ' passing' .. reset ..
      dim .. ' (' .. string.format('%.2fs', elapsed) .. ')' .. reset

    if handler.failuresCount > 0 then
      summary = summary .. red .. '  ' .. handler.failuresCount .. ' failing' .. reset
    end
    if handler.errorsCount > 0 then
      summary = summary .. red .. '  ' .. handler.errorsCount .. ' errors' .. reset
    end
    if handler.pendingsCount > 0 then
      summary = summary .. pink .. '  ' .. handler.pendingsCount .. ' pending' .. reset
    end

    write(summary)
    write('')

    return nil, true
  end

  handler.error = function(element, parent, message, debug)
    write(red .. errorSymbol .. ' File error: ' .. tostring(element.name) .. reset)
    if message then
      for line in tostring(message):gmatch('[^\n]+') do
        write('  ' .. red .. line .. reset)
      end
    end

    return nil, true
  end

  busted.subscribe({ 'test', 'end' }, handler.testEnd, { predicate = handler.cancelOnPending })
  busted.subscribe({ 'describe', 'start' }, handler.describeStart)
  busted.subscribe({ 'describe', 'end' }, handler.describeEnd)
  busted.subscribe({ 'suite', 'start' }, handler.suiteStart)
  busted.subscribe({ 'suite', 'end' }, handler.suiteEnd)
  busted.subscribe({ 'error', 'file' }, handler.error)
  busted.subscribe({ 'failure', 'file' }, handler.error)
  busted.subscribe({ 'error', 'describe' }, handler.error)
  busted.subscribe({ 'failure', 'describe' }, handler.error)

  return handler
end
