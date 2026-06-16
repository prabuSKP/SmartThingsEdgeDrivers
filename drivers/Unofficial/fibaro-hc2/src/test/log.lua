-- Copyright 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0
--
-- Local mock for SmartThings Edge Driver log module

local log = {}

log.levels = {
  trace = 0,
  debug = 1,
  info = 2,
  warn = 3,
  error = 4
}

log._level = log.levels.debug

function log.level(new_level)
  if new_level then
    log._level = new_level
  end
  return log._level
end

function log.trace(...)
  if log._level <= log.levels.trace then
    print("[TRACE]", ...)
  end
end

function log.debug(...)
  if log._level <= log.levels.debug then
    print("[DEBUG]", ...)
  end
end

function log.info(...)
  if log._level <= log.levels.info then
    print("[INFO]", ...)
  end
end

function log.info_with(opts, ...)
  if log._level <= log.levels.info then
    print("[INFO]", ...)
  end
end

function log.warn(...)
  if log._level <= log.levels.warn then
    print("[WARN]", ...)
  end
end

function log.error(...)
  if log._level <= log.levels.error then
    print("[ERROR]", ...)
  end
end

return log
