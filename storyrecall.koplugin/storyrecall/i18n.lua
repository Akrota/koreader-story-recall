--[[--
Minimal translation helper.

KOReader's gettext only knows the strings shipped with KOReader itself, so
Story Recall carries its own tables. English is the source language; a
translation table maps the English string to the translated one.
--]]

local translations = {
    de = require("storyrecall/l10n/de"),
}

local function currentLanguage()
    local lang = G_reader_settings and G_reader_settings:readSetting("language") or "en"
    return lang:match("^(%a%a)") or "en"
end

local function translate(msg)
    local tbl = translations[currentLanguage()]
    return tbl and tbl[msg] or msg
end

return translate
