
local function emit(msg)
  hl.dispatch(hl.dsp.event(msg))
end

local SUPER_KEYS = { "Super_L", "Super_R" }

local function super_held()
  for _, key in ipairs(SUPER_KEYS) do

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

local ARM_DEADLINE = 20

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
  if super_held() then

    session.armed = true
    return
  end
  session.ticks = session.ticks + 1
  if session.armed then

    stop_watch()
    emit("switcher:overview-switch-commit")
  elseif session.ticks >= ARM_DEADLINE then

    stop_watch()
    emit("switcher:overview-switch-commit")
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

local function switch_step(dir)
  return function()
    switcher_unbind_arrows()
    emit("switcher:overview-switch " .. dir)
    watch()
  end
end

hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")

o.bind("SUPER + TAB", "Next workspace through overview", switch_step("next"), { repeating = true })
o.bind("SUPER + SHIFT + TAB", "Previous workspace through overview", switch_step("prev"), { repeating = true })

function switcher_overview_closed()
  stop_watch()
  switcher_bind_arrows()
  return hl.dsp.no_op()
end