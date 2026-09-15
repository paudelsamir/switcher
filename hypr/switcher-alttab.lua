
local function emit(msg)
  hl.dispatch(hl.dsp.event(msg))
end

local ALT_KEYS = { "Alt_L", "Alt_R" }

local function alt_held()
  for _, key in ipairs(ALT_KEYS) do

    local ok, down = pcall(hl.is_key_down, key)
    if ok and down then
      return true
    end
  end
  return false
end

local session = {
  watching = false,
  armed = false,
  ticks = 0,
  timer = nil,
}

local ARM_DEADLINE = 66

local function stop_watch()
  session.watching = false
  session.armed = false
  session.ticks = 0
  if session.timer then
    session.timer:set_enabled(false)
  end
end

local function tick()
  if not session.watching then
    return
  end
  if alt_held() then

    session.armed = true
    return
  end
  session.ticks = session.ticks + 1
  if session.armed then
    stop_watch()
    emit("switcher:alttab commit")
  elseif session.ticks >= ARM_DEADLINE then
    stop_watch()
  end
end

local function watch()
  session.watching = true
  session.armed = false
  session.ticks = 0

  if not session.timer then
    session.timer = hl.timer(tick, { timeout = 30, type = "repeat" })
  end
  session.timer:set_enabled(true)
end

local function step(dir)
  return function()
    emit("switcher:alttab step " .. dir)
    watch()
  end
end

hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")

o.bind("ALT + TAB", "Switch windows", step("next"), { repeating = true })
o.bind("ALT + SHIFT + TAB", "Switch windows (backwards)", step("prev"), { repeating = true })

function switcher_alttab_closed()
  stop_watch()
  return hl.dsp.no_op()
end
