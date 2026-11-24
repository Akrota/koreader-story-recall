--[[--
ZenOS integration: a Home widget showing where you are in the book you read
last, spoiler-free (the story so far at the furthest chapter read). Tapping
it opens the book with the recap.

Without ZenOS nothing here runs. Everything is read from the stored notes;
no AI request is made.
--]]

local DocSettings = require("docsettings")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Screen = require("device").screen
local _ = require("storyrecall/i18n")
local T = require("ffi/util").template

local ZenOS = {}

ZenOS.HOME_ID = "storyrecall.current_book"

local FILENAME = "story_recall.lua"

--- The last book with Story Recall notes, and its state at the furthest chapter read.
-- @return { file, title, chapter_index, chapter_title, text } or { file, title } or nil
function ZenOS.currentBook()
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory or not ReadHistory.hist then return end
    for i, item in ipairs(ReadHistory.hist) do
        if i > 10 then break end
        local path = item.file and DocSettings:getSidecarDir(item.file) .. "/" .. FILENAME
        if path and not require("storyrecall/comic").isComic(item.file)
                and lfs.attributes(item.file, "mode") == "file" and lfs.attributes(path, "mode") == "file" then
            local ok_open, settings = pcall(LuaSettings.open, LuaSettings, path)
            local data = ok_open and settings and settings.data
            if data then
                local book = data.book or {}
                local result = { file = item.file, title = book.title or item.text }
                local Series = require("storyrecall/series")
                local chosen
                for _key, note in pairs(data.ai_chapters or {}) do
                    if (data.furthest_chapter or 0) > 0 and Series.noteVisible(data, note) and note.story_so_far
                            and (not chosen or note.index > chosen.index) then
                        chosen = note
                    end
                end
                if chosen then
                    -- The last paragraph says where things stand; the rest is history.
                    local text = chosen.story_so_far:gsub("\r", "")
                    local last = text:match(".*\n%s*\n(.-)%s*$")
                    result.text = (last and last ~= "") and last or text
                    result.chapter_index = chosen.index
                    result.chapter_title = chosen.title
                end
                return result
            end
        end
    end
end

local HomeWidget = InputContainer:extend{
    width = nil,
    height = nil,
    on_tap = nil,
}

function HomeWidget:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapStoryRecall = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
    local book = ZenOS.currentBook()
    local heading, body
    if not book then
        heading = "Story Recall"
        body = _("Open a book and create its AI notes; this widget then shows where you are in the story.")
    elseif not book.text then
        heading = book.title or "Story Recall"
        body = _("No AI notes for this book yet.")
    else
        heading = book.title or "Story Recall"
        if book.chapter_index and book.chapter_index > 0 then
            heading = heading .. " · " .. T(_("Chapter %1"), book.chapter_index)
        end
        body = book.text
    end
    self.file = book and book.file

    local padding = Screen:scaleBySize(10)
    local inner_w = self.width - 2 * padding
    -- Font:getFace scales the size for the screen itself.
    local title = TextWidget:new{
        text = heading,
        face = Font:getFace("smallinfofontbold", 18),
        max_width = inner_w,
    }
    local gap = Screen:scaleBySize(6)
    local body_h = math.max(0, self.height - 2 * padding - title:getSize().h - gap)
    local text = TextBoxWidget:new{
        text = body,
        face = Font:getFace("smallinfofont", 16),
        width = inner_w,
        height = body_h,
        height_overflow_show_ellipsis = true,
    }
    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        padding = padding,
        bordersize = 0,
        VerticalGroup:new{ align = "left", title, VerticalSpan:new{ width = gap }, text },
    }
end

function HomeWidget:onTapStoryRecall()
    if self.on_tap then self.on_tap(self.file) end
    return true
end

--- Register the Home widget if ZenOS is there. Safe to call repeatedly.
-- @param on_tap function(file) when the widget is tapped
-- @return true if registered
function ZenOS.registerHome(on_tap)
    local register = rawget(_G, "__ZENOS_REGISTER_HOME_ITEM") or rawget(_G, "__ZEN_UI_REGISTER_HOME_ITEM")
    if type(register) ~= "function" then return false end
    local ok, result = pcall(register, ZenOS.HOME_ID, function(ctx)
        return HomeWidget:new{ width = ctx.width, height = ctx.height, on_tap = on_tap }
    end, {
        label = "Story Recall",
        size = "s",
    })
    if not ok then logger.warn("StoryRecall: ZenOS home registration failed:", result) end
    return ok and result ~= false
end

return ZenOS
