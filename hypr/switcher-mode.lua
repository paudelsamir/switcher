
hl.config({
  general = {

    layout = "scrolling",
  },

  scrolling = {

    column_width = 0.5,
  },
})

hl.gesture({ fingers = 3, direction = "horizontal", action = "scroll_move" })

hl.gesture({ fingers = 3, direction = "vertical", action = "workspace" })

hl.animation({ leaf = "workspaces", enabled = true, speed = 3, bezier = "easeOutQuint", style = "slidevert" })

hl.unbind("SUPER + LEFT")
hl.unbind("SUPER + RIGHT")
hl.unbind("SUPER + UP")
hl.unbind("SUPER + DOWN")
function switcher_bind_arrows()
  hl.unbind("SUPER + LEFT")
  hl.unbind("SUPER + RIGHT")
  hl.unbind("SUPER + UP")
  hl.unbind("SUPER + DOWN")
  o.bind("SUPER + LEFT", "Focus on left window", hl.dsp.layout("focus l"))
  o.bind("SUPER + RIGHT", "Focus on right window", hl.dsp.layout("focus r"))
  o.bind("SUPER + UP", "Focus on above window", hl.dsp.layout("focus u"))
  o.bind("SUPER + DOWN", "Focus on below window", hl.dsp.layout("focus d"))
end

function switcher_unbind_arrows()
  hl.unbind("SUPER + LEFT")
  hl.unbind("SUPER + RIGHT")
  hl.unbind("SUPER + UP")
  hl.unbind("SUPER + DOWN")
end

switcher_bind_arrows()

o.bind("SUPER + Page_Down", "Next workspace", hl.dsp.focus({ workspace = "e+1" }))
o.bind("SUPER + Page_Up", "Previous workspace", hl.dsp.focus({ workspace = "e-1" }))

hl.unbind("SUPER + TAB")
hl.unbind("SUPER + SHIFT + TAB")
