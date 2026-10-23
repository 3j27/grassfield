-- Grassfield core modules shared by the real session (session.lua) and the nested dev session (dev.lua).

-- Hyprland keeps package.loaded across reloads; drop our modules so edits are picked up.
for module in pairs(package.loaded) do
  if module == "grassfield" or module:sub(1, 11) == "grassfield." then
    package.loaded[module] = nil
  end
end

require("grassfield.cursor").apply()
require("grassfield.looknfeel")
require("grassfield.input")
require("grassfield.windows")
-- Omarchy's screen-share protection for password managers (SEC-01).
require("grassfield.privacy")
require("grassfield.placement")
require("grassfield.stacking")
require("grassfield.bindings")
