--[[--
Getting started: a short guide shown once on first use and always reachable
from the menu, plus the "start now?" question right after an API key was set.
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("storyrecall/i18n")

local Guide = {}

local function bold(text)
    return TextBoxWidget.PTF_BOLD_START .. text .. TextBoxWidget.PTF_BOLD_END
end

function Guide.text()
    local lines = {
        _("Reminds you of the story, spoiler-free, up to exactly where you are."),
        "",
        bold(_("1. Set up the AI (once)")),
        _("Settings → AI → \"Set up API key\" and scan the QR code with your phone. Google Gemini is free."),
        "",
        bold(_("2. Create AI notes")),
        _("Tap \"AI notes: …\" in the Story Recall menu. Afterwards the book works offline. While charging this also starts by itself (adjustable in Settings)."),
        "",
        bold(_("3. Read")),
        _("After a break the recap appears by itself. Recap and chronicle are always in the menu, always only up to where you are."),
        "",
        _("The book text is sent to the AI provider you choose; free plans may use it to improve their products."),
    }
    return TextBoxWidget.PTF_HEADER .. table.concat(lines, "\n")
end

--- Second page: tips for everyday use.
function Guide.tipsText()
    local lines = {
        bold(_("Rewrite the story so far")),
        _("Only \"The story so far\" at your current reading position is rewritten. \"Correct AI notes\" restores the previous text. For an earlier chapter, go back there in the book first."),
        "",
        bold(_("Status line \"AI notes: …\"")),
        _("Tap: start, pause or try again now. Hold: provider, model and the last message. \"Pause: …\" continues by itself."),
        "",
        bold(_("Fixing AI notes")),
        _("\"Correct AI notes\" changes a single chapter. \"Re-create all AI notes\" creates them all again; the previous ones stay under \"Earlier AI notes\", so you can switch back without new requests."),
        "",
        bold(_("Spoiler-free")),
        _("Notes, recap and lexicon only show what you have read. Only process what you read: turn off \"Process the whole book when opening it\"."),
        "",
        _("Your own notes are never sent to the AI and stay on your device. Gestures: see Settings."),
    }
    return TextBoxWidget.PTF_HEADER .. table.concat(lines, "\n")
end

--- Third page: rough costs (prices change, so only orders of magnitude).
function Guide.costsText()
    local lines = {
        _("Mostly creating the AI notes costs: the AI reads the whole book. Roughly per book:"),
        "",
        bold(_("Short book (about 250 pages)")),
        _("Claude: Haiku about 0.50 €, Sonnet about 1.50 €"),
        bold(_("Average book (about 400 pages)")),
        _("Claude: Haiku about 1 €, Sonnet about 2.50 €"),
        bold(_("Long book (about 700 pages)")),
        _("Claude: Haiku about 1.50 €, Sonnet about 4–5 €"),
        "",
        bold(_("Google Gemini")),
        _("Free, but with a daily limit: a long book can take 2–3 days. With a paid account under 0.50 € per book and no daily limit."),
        "",
        _("\"Rewrite the story so far\" and \"Ask the AI\": a few cents each."),
        "",
        _("Estimate as of October 2026, prices change. Your provider's website shows the exact costs."),
    }
    return TextBoxWidget.PTF_HEADER .. table.concat(lines, "\n")
end

--- Fourth page: saving, with the way to each setting.
function Guide.savingText()
    local lines = {
        bold(_("Only process what you read")),
        _("Settings → AI → turn off \"Process the whole book when opening it\". You never pay for chapters you don't read."),
        "",
        bold(_("A cheaper model, and stay with it")),
        _("Settings → AI → Model, e.g. Haiku instead of Sonnet. Keep \"When overloaded: wait\", so no pricier model steps in."),
        "",
        bold(_("More chapters per request")),
        _("Settings → AI → Advanced → \"Chapters per request\", e.g. 5 instead of 3: saves about a quarter. Very long answers fail a little more often."),
        "",
        bold(_("Switch back instead of re-creating")),
        _("\"Earlier AI notes\" brings back older notes at no cost. Re-create all AI notes only when it is worth it."),
    }
    return TextBoxWidget.PTF_HEADER .. table.concat(lines, "\n")
end

local PAGES = {
    { title = "Getting started with Story Recall", text = Guide.text },
    { title = "Good to know", text = Guide.tipsText },
    { title = "Costs (rough)", text = Guide.costsText },
    { title = "Saving tips", text = Guide.savingText },
}

--- Show the guide.
-- @param on_setup function to start the AI setup (nil hides that button)
-- @param page 1 (getting started), 2 ("Good to know") or 3 (costs); true means 2
function Guide.show(on_setup, page)
    if page == true then page = 2 end
    page = PAGES[page] and page or 1
    local viewer
    local buttons = {}
    local function go(to)
        return function()
            UIManager:close(viewer)
            Guide.show(on_setup, to)
        end
    end
    if page == 1 then
        if on_setup then
            table.insert(buttons, {
                text = _("Set up AI now"),
                callback = function()
                    UIManager:close(viewer)
                    on_setup()
                end,
            })
        end
        table.insert(buttons, { text = _("Good to know"), callback = go(2) })
    else
        table.insert(buttons, { text = _("Back"), callback = go(page - 1) })
        if PAGES[page + 1] then
            table.insert(buttons, { text = _(PAGES[page + 1].title), callback = go(page + 1) })
        end
    end
    table.insert(buttons, {
        text = _("Close"),
        callback = function() UIManager:close(viewer) end,
    })
    viewer = TextViewer:new{
        title = _(PAGES[page].title),
        text = PAGES[page].text(),
        justified = false,
        buttons_table = { buttons },
    }
    UIManager:show(viewer)
end

--- Ask right after an API key was saved whether to start processing now.
function Guide.offerStart(on_start)
    UIManager:show(ConfirmBox:new{
        text = _("API key saved. Create AI notes for this book now?"),
        ok_text = _("Start now"),
        cancel_text = _("Later"),
        ok_callback = on_start,
    })
end

return Guide
