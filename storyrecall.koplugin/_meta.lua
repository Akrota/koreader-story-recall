-- Loaded before the plugin's own modules are on the package path,
-- so the description is translated inline.
local lang = G_reader_settings and G_reader_settings:readSetting("language") or "en"

local description = "Reminds you of the story so far, spoiler-free, up to where you are: after a break, when starting the next volume, or when you forget a name."
if lang:match("^de") then
    description = "Erinnert dich spoilerfrei an die bisherige Geschichte, genau bis zu deiner Stelle: nach einer Pause, beim nächsten Band oder bei einem vergessenen Namen."
end

return {
    fullname = "Story Recall",
    description = description,
    version = "0.9.9",
}
