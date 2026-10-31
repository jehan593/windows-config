-- hold-space-2x.lua
-- Tap SPACE  = pause / play
-- Hold SPACE = 2x speed while held, release = back to previous speed
-- (YouTube-style hold-to-fast-forward)
--
-- This script binds SPACE itself. To remap it, put this in input.conf:
--   YOURKEY script-binding hold_space_2x/space-hold-2x

local opts = {
    threshold = 0.3,  -- seconds held before a tap counts as a hold
    speed     = 2.0,  -- speed while held
    debug     = false, -- log events to %TEMP%\mpv-hold-space.log
}
require 'mp.options'.read_options(opts)

local log_path = (os.getenv("TEMP") or ".") .. "/mpv-hold-space.log"
local function dbg(msg)
    if opts.debug then
        local f = io.open(log_path, "a")
        if f then
            f:write(os.date("%H:%M:%S") .. "  " .. msg .. "\n")
            f:close()
        end
    end
end

dbg("script loaded (threshold=" .. tostring(opts.threshold) .. ", speed=" .. tostring(opts.speed) .. ", debug=" .. tostring(opts.debug) .. ")")

local orig_speed = nil
local engaged = false
local timer = nil
local was_paused = false -- video was paused when the hold started

local function engage()
    engaged = true
    mp.set_property_number("speed", opts.speed)
    if was_paused then
        mp.set_property_bool("pause", false)
    end
    mp.osd_message(">> " .. opts.speed .. "x")
end

local function restore_speed()
    engaged = false
    local s = orig_speed or 1.0
    mp.set_property_number("speed", s)
    if was_paused then
        mp.set_property_bool("pause", true)
        mp.osd_message("|| " .. string.format("%.2g", s) .. "x")
    else
        mp.osd_message("> " .. string.format("%.2g", s) .. "x")
    end
end

local function on_up(canceled)
    if timer then
        -- released before the threshold fired -> it was a tap
        timer:kill()
        timer = nil
        if not canceled then
            mp.commandv("cycle", "pause")
        end
    elseif engaged then
        restore_speed()
    end
    orig_speed = nil
end

local utils = require 'mp.utils'

-- mpv.net binds SPACE to its own play-pause handler at higher priority than
-- regular script bindings, so a forced binding is required to take over SPACE.
mp.add_forced_key_binding("SPACE", "space-hold-2x", function(e)
    dbg("event=" .. tostring(e.event) .. " canceled=" .. tostring(e.canceled)
        .. " key=" .. tostring(e.key_name) .. " " .. utils.to_string(e))
    if e.event == "down" then
        orig_speed = mp.get_property_number("speed") or 1.0
        was_paused = mp.get_property_bool("pause")
        engaged = false
        timer = mp.add_timeout(opts.threshold, function()
            timer = nil
            dbg("timer fired -> engaging " .. opts.speed .. "x")
            engage()
        end)
    elseif e.event == "up" or e.canceled then
        dbg("up path, timer=" .. tostring(timer) .. " engaged=" .. tostring(engaged))
        on_up(e.canceled)
    elseif e.event == "press" then
        -- down/up couldn't be tracked: fall back to plain pause toggle
        dbg("press fallback -> cycle pause")
        mp.commandv("cycle", "pause")
    end
    -- "repeat" while holding: nothing to do, speed is already engaged
end, { complex = true })
