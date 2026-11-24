local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../storyrecall.koplugin/?.lua;" .. package.path
for _, m in ipairs({ "ui/event", "ui/widget/infomessage", "ui/widget/menu", "ui/widget/textviewer", "ui/uimanager",
    "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/inputdialog", "ui/widget/container/centercontainer", "docsettings", "luasettings", "libs/libkoreader-lfs" }) do package.loaded[m] = {} end
package.loaded["device"] = { screen = {} }
package.loaded["ui/widget/textboxwidget"] = { PTF_BOLD_START = "", PTF_BOLD_END = "", PTF_HEADER = "" }
package.loaded["util"] = { cleanupSelectedText = function(t) return (t:gsub("^%s+", ""):gsub("%s+$", "")) end }
package.loaded["storyrecall/i18n"] = function(t) return t end
package.loaded["ffi/util"] = { template = function(t) return t end }
local C = require("storyrecall/context")
local pavel = { name = "Павел", type = "character", aliases = {}, facts = { 1 } }
local jake = { name = "Jake Thayne", type = "character", aliases = { "Jake" }, facts = { 1, 2 } }
local by = { ["павел"] = pavel, ["Павел"] = pavel, ["jake thayne"] = jake, ["jake"] = jake }
local function ok(n, c) print(c and "PASS" or "FAIL", n) end
ok("cyrillic name found", C.find({ pavel, jake }, by, "Павел")[1] == pavel)
ok("cyrillic in quotes", C.find({ pavel, jake }, by, "„Павел“,")[1] == pavel)
ok("Jake’s (typographic apostrophe)", C.find({ pavel, jake }, by, "Jake’s")[1] == jake)
ok("Jakes (German genitive)", C.find({ pavel, jake }, by, "Jakes")[1] == jake)
ok("«Jake»", C.find({ pavel, jake }, by, "«Jake»")[1] == jake)
