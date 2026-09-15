
local function emit(msg)
  hl.dispatch(hl.dsp.event(msg))
end

local function tracker(prefix, sign)
  local travel = 0

  local function report(e)
    travel = travel + sign * e.delta.y
    emit(string.format("%s-at %.1f %d", prefix, travel, e.time_ms))
  end

  return {
    start = function(e)
      travel = 0
      emit(prefix .. "-begin")
      report(e)
    end,
    update = report,
    finish = function(e)

      emit(string.format("%s-end %d %d", prefix, e.cancelled and 1 or 0, e.time_ms))
      travel = 0
    end,
  }
end

hl.gesture({ fingers = 4, direction = "up", action = tracker("switcher:overview", -1) })
hl.gesture({ fingers = 4, direction = "down", action = tracker("switcher:overview-down", 1) })

o.bind("SUPER + grave", "Overview", "omarchy-shell shell toggle paudelsamir.switcher")
o.bind("SUPER + ALT + O", "Overview", "omarchy-shell shell toggle paudelsamir.switcher")

function switcher_overview_closed()
  return hl.dsp.no_op()
end
