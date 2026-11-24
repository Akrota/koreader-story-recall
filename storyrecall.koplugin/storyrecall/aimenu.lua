--[[--
AI settings menu and status line.
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local AI = require("storyrecall/ai")
local Processor = require("storyrecall/processor")
local _ = require("storyrecall/i18n")
local T = require("ffi/util").template

local AIMenu = {}

local function currentProvider(plugin)
    return AI.getProvider(plugin:getSetting("ai_provider")) or AI.PROVIDERS[1]
end

local function currentModel(plugin)
    local provider = currentProvider(plugin)
    return (plugin:getSetting("ai_models") or {})[provider.id] or provider.default_model
end

local function setModel(plugin, model)
    local models = plugin:getSetting("ai_models") or {}
    models[currentProvider(plugin).id] = model
    plugin:setSetting("ai_models", models)
end

local function errorText(message)
    local kind, detail = tostring(message or ""):match("^([^:]*):?(.*)$")
    if kind == "config" then
        if detail == "key" then return _("API key missing") end
        if detail == "model" then return _("no model chosen") end
        if detail == "url" then return _("address missing") end
        return _("settings incomplete")
    elseif kind == "auth" then
        return detail == "expired" and _("API key expired") or _("API key rejected")
    elseif kind == "rate_limit" then
        return _("provider limit reached")
    elseif kind == "quota" then
        return detail == "credit" and _("no credit left at the provider") or _("daily limit reached, continues later")
    end
    return T(_("error: %1"), detail ~= "" and detail or kind)
end

--- A provider error in plain words, for single requests (rewrite the story
-- so far, ask the AI, internet summary). Same for every provider.
function AIMenu.describeError(err)
    err = type(err) == "table" and err or {}
    local kind = err.kind
    if kind == "rate_limit" then
        local at = err.retry_after and os.date("%H:%M", os.time() + err.retry_after)
        if err.daily then
            return at and T(_("the provider's daily limit is reached; new requests from about %1"), at)
                or _("the provider's daily limit is reached; try again tomorrow")
        end
        return at and T(_("the provider's limit is reached for the moment; try again from about %1"), at)
            or _("the provider's limit is reached for the moment; try again in a minute")
    elseif kind == "server" then
        return _("the provider is overloaded right now; try again in a few minutes")
    elseif kind == "timeout" then
        return _("the provider took too long to answer; try again later")
    elseif kind == "network" then
        return _("no connection to the provider; check the Wi-Fi")
    elseif kind == "auth" then
        return _("the provider rejected the API key (Story Recall → Settings → AI)")
    elseif kind == "quota" then
        return _("no credit left at the provider")
    end
    return tostring(err.message or kind or "?")
end

--- One-line status for the current book.
function AIMenu.statusText(plugin)
    local store, processor = plugin.store, plugin.processor
    if not store or not processor then return _("AI notes") end
    local total = #require("storyrecall/chapters").upTo(plugin.ui, math.huge)
    local done = store:countChapterNotes()
    local state = processor.state
    local detail
    if state == "running" then
        detail = processor.using_fallback and _("working (fallback)") or _("working")
    elseif state == "waiting_retry" then
        if processor.message == "server" then
            detail = _("pause: overloaded")
        elseif processor.message == "format" then
            detail = _("pause: unusable answer")
        else
            detail = _("pause: limit")
        end
    elseif state == "waiting_quota" then
        local wait_until = plugin:getSetting("ai_quota_wait_until")
        if processor.message ~= "quota:credit" and wait_until and wait_until > os.time() then
            -- When it goes on by itself (short enough for one menu line).
            detail = T(_("limit, continues at %1"), os.date("%H:%M", wait_until))
        else
            detail = errorText(processor.message)
        end
    elseif state == "waiting_network" then
        detail = _("waiting for Wi-Fi")
    elseif state == "done" then
        detail = done >= total and _("complete") or _("up to date")
    elseif state == "error" then
        detail = errorText(processor.message)
    elseif state == "stopped" then
        detail = _("paused")
    else
        local cfg, reason = AI.configFrom(plugin.settings)
        if cfg and AIMenu.nothingToDo(plugin) then
            -- Every chapter is done: tapping offers to create them again, not to start
            detail = _("tap to re-create")
        else
            detail = cfg and _("tap to start") or errorText("config:" .. reason)
        end
    end
    -- Short enough to fit one menu line.
    return T(_("AI notes: %1/%2 · %3"), done, total, detail)
end

--- Full details for a long press on the status line.
function AIMenu.statusDetails(plugin)
    local processor = plugin.processor
    local provider = currentProvider(plugin)
    local lines = {
        AIMenu.statusText(plugin),
        "",
        T(_("Provider: %1"), _(provider.name)),
        T(_("Model: %1"), (processor and processor.cfg and processor.cfg.model) or currentModel(plugin) or _("not set")),
    }
    local wait_until = plugin:getSetting("ai_quota_wait_until")
    if processor and processor.state == "waiting_quota" and wait_until and wait_until > os.time() then
        table.insert(lines, T(_("Next try by itself: %1"), os.date("%H:%M", wait_until)))
    end
    local err = processor and processor.last_error
    if err then
        table.insert(lines, "")
        table.insert(lines, T(_("Last message from the provider: %1"), tostring(err.message or err.kind)))
    end
    table.insert(lines, "")
    table.insert(lines, _("Tap the status line to start or pause; during a pause after an error, tapping tries again right away."))
    return table.concat(lines, "\n")
end

--- Tapping the status (main menu or recap ☰): start, pause or try again.
-- Without an API key it starts the key setup right away. When every chapter
-- already has a note, it offers to create them all again.
-- @param on_change optional, called when the notes were cleared (refresh the menu)
function AIMenu.toggleProcessing(plugin, on_change)
    local processor = plugin.processor
    if processor.state == "waiting_retry" then
        -- Paused after an error: tapping means "try again now", not "stop".
        UIManager:show(InfoMessage:new{ text = _("Trying again…"), timeout = 1 })
        UIManager:scheduleIn(0.3, function() processor:retryNow() end)
    elseif processor:isActive() then
        processor:stop("stopped")
    else
        local _cfg, missing = AI.configFrom(plugin.settings)
        if missing == "key" then
            plugin:startKeySetup()
            return
        end
        if AIMenu.nothingToDo(plugin) then
            AIMenu.confirmRecreate(plugin, _("All chapters already have AI notes."), nil, on_change)
            return
        end
        plugin.store:clearChapterFailures()
        plugin:setSetting("ai_quota_wait_until", nil) -- tapping means "try now"
        plugin.ai_block_notified = nil -- a new failure may tell again
        local ok, reason = processor:start()
        if not ok and reason == "network" then
            UIManager:show(InfoMessage:new{ text = _("No Wi-Fi. Processing continues automatically when the device is online."), timeout = 4 })
        elseif not ok and reason ~= "done" then
            UIManager:show(InfoMessage:new{ text = T(_("Cannot start: %1. See Story Recall → Settings → AI."), errorText("config:" .. tostring(reason))) })
        end
    end
end

--- Menu item for the book: shows the status, tap to start or pause.
function AIMenu.statusItem(plugin)
    return {
        storyrecall_status = true, -- found by AIMenu.refreshOpenMenu
        text_func = function() return AIMenu.statusText(plugin) end,
        enabled_func = function() return plugin.store ~= nil end,
        keep_menu_open = true,
        hold_callback = function()
            UIManager:show(InfoMessage:new{ text = AIMenu.statusDetails(plugin) })
        end,
        callback = function(touchmenu_instance)
            AIMenu.toggleProcessing(plugin, function() touchmenu_instance:updateItems() end)
            touchmenu_instance:updateItems()
        end,
    }
end

--- Live progress: redraw KOReader's menu if it shows the status line right
-- now (Story Recall's main menu is open). Otherwise nothing happens.
function AIMenu.refreshOpenMenu(plugin)
    local container = plugin.ui and plugin.ui.menu and plugin.ui.menu.menu_container
    local menu = container and container[1]
    if not (menu and type(menu.item_table) == "table" and menu.updateItems) then return false end
    if not UIManager:isWidgetShown(container) then return false end
    for _i, item in ipairs(menu.item_table) do
        if type(item) == "table" and item.storyrecall_status then
            menu:updateItems()
            return true
        end
    end
    return false
end

local function editText(title, value, hint, on_save)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = value or "",
        input_hint = hint,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local text = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                UIManager:close(dialog)
                on_save(text)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Address of an own OpenAI-compatible service.
local function editAddress(plugin, on_done)
    editText(_("Address (OpenAI-compatible)"), plugin:getSetting("ai_custom_url"),
        "https://example.com/v1", function(text)
            if text == "" then
                plugin:setSetting("ai_custom_url", nil)
            else
                local url = require("storyrecall/keysetup").cleanUrl(text)
                if not url then
                    UIManager:show(InfoMessage:new{ text = _("The address must start with https:// (http:// only for a server in your home network).") })
                    return
                end
                plugin:setSetting("ai_custom_url", url)
            end
            if on_done then on_done() end
        end)
end

local function providerItems(plugin)
    local items = {}
    for _i, provider in ipairs(AI.PROVIDERS) do
        table.insert(items, {
            text = _(provider.name),
            radio = true,
            checked_func = function() return currentProvider(plugin).id == provider.id end,
            callback = function()
                plugin:setSetting("ai_provider", provider.id)
                -- An own service needs its address; the AI menu shows it from now on.
                if provider.id == "custom" and not plugin:getSetting("ai_custom_url") then
                    editAddress(plugin)
                end
            end,
        })
    end
    return items
end

local function modelItems(plugin)
    local items = {}
    local provider = currentProvider(plugin)
    for _i, model in ipairs(provider.models or {}) do
        table.insert(items, {
            text = model .. " " .. (provider.free and _("[free]") or _("[paid]")),
            radio = true,
            checked_func = function() return currentModel(plugin) == model end,
            callback = function() setModel(plugin, model) end,
        })
    end
    table.insert(items, {
        text = _("Other model…"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            editText(_("Model name"), currentModel(plugin), "e.g. gemini-3.6-flash", function(text)
                setModel(plugin, text ~= "" and text or nil)
                touchmenu_instance:updateItems()
            end)
        end,
    })
    return items
end

local function fallbackItems(plugin)
    local provider = currentProvider(plugin)
    local function current()
        local fallback = (plugin:getSetting("ai_fallback_models") or {})[provider.id]
        if fallback == nil then fallback = provider.fallback_model end
        return fallback ~= "" and fallback or nil
    end
    local function set(value)
        local fallbacks = plugin:getSetting("ai_fallback_models") or {}
        fallbacks[provider.id] = value
        plugin:setSetting("ai_fallback_models", fallbacks)
    end
    local items = {
        {
            text = _("None"),
            radio = true,
            checked_func = function() return current() == nil end,
            callback = function() set("") end,
        },
    }
    for _i, model in ipairs(provider.models or {}) do
        table.insert(items, {
            text = model,
            radio = true,
            checked_func = function() return current() == model end,
            callback = function() set(model) end,
        })
    end
    return items
end

--- "Rewrite the story so far" (main menu).
function AIMenu.rewriteItem(plugin)
    return {
        text = _("Rewrite the story so far"),
        help_text = _("Rewrites \"The story so far\" for your current reading position, from all chapter summaries (one request). The other chapters stay unchanged. The previous text stays and can be restored when correcting the AI notes. For an earlier chapter, go back there in the book first."),
        enabled_func = function() return plugin.store ~= nil and plugin.store:countChapterNotes() > 1 end,
        callback = function() plugin:rewriteStorySoFar() end,
    }
end

--- Ask whether to delete this book's AI notes and create them again.
-- @param intro optional first paragraph (why the question comes up now)
-- @param ok_text optional button text
-- @param on_done optional, called after the notes were cleared (e.g. to refresh the menu)
-- @param cancel_text optional text for the button that keeps the notes
function AIMenu.confirmRecreate(plugin, intro, ok_text, on_done, cancel_text)
    local corrected = 0
    for _key, note in pairs(plugin.store.data.ai_chapters or {}) do
        if note.edited then corrected = corrected + 1 end
    end
    local text = _("Create this book's AI notes again? Your own notes stay. The current AI notes are kept and can be used again under Book and notes → Earlier AI notes.")
    if intro then text = intro .. "\n\n" .. text end
    if corrected > 0 then
        text = text .. "\n\n" .. T(_("Your corrections in %1 chapter(s) are kept with them."), corrected)
    end
    text = text .. AIMenu.dropWarning(plugin) -- defined below, called later
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = ok_text or _("Create again"),
        cancel_text = cancel_text,
        ok_callback = function()
            plugin.processor:stop("stopped")
            -- Put the current notes aside instead of deleting them (up to two per provider)
            plugin.store:stashChapterNotes()
            plugin.store:save()
            if on_done then on_done() end
            plugin:onStoryRecallProcess()
        end,
    })
end

--- True when every chapter that can get an AI note already has one.
function AIMenu.nothingToDo(plugin)
    return plugin.store ~= nil and plugin.processor ~= nil and plugin.store:countChapterNotes() > 0
        and #plugin.processor:pendingChapters() == 0
end

--- Name of a saved set for the menu, e.g. "gemini-3.8-flash · 73 chapters · 24.10.2026"
-- (the model names the provider well enough and keeps the line short).
local function setLabel(set)
    local provider = AI.getProvider(set.provider)
    local name = set.model or (provider and _(provider.name)) or tostring(set.provider)
    return T(_("%1 · %2 chapters · %3"), name, set.count or 0, os.date("%d.%m.%Y", set.saved or os.time()))
end

--- Warning when putting the current notes aside would push out the oldest
-- saved set of their provider (at most two per provider).
-- @param taken optional set taken out first (using it frees its place)
local function dropWarning(plugin, taken)
    local dropped = plugin.store:stashWouldDrop()
    if not dropped or (taken and taken.provider == dropped.provider) then return "" end
    return "\n\n" .. T(_("The oldest earlier notes of this provider are deleted (at most two are kept): %1"), setLabel(dropped))
end
AIMenu.dropWarning = dropWarning

--- "Earlier AI notes" (Book & notes menu): use or delete a set that was put
-- aside (re-created, or another provider), or delete them all.
function AIMenu.savedNotesItem(plugin)
    return {
        text = _("Earlier AI notes"),
        help_text = _("When the AI notes are created again, the previous ones are kept here, up to two per provider. Using one swaps it with the current notes, without new requests."),
        enabled_func = function() return plugin.store ~= nil and #plugin.store:getSavedSets() > 0 end,
        sub_item_table_func = function()
            local items = {}
            for _i, set in ipairs(plugin.store:getSavedSets()) do
                table.insert(items, {
                    text = setLabel(set),
                    callback = function(touchmenu_instance)
                        local box
                        box = ConfirmBox:new{
                            text = T(_("Use these AI notes again?\n\n%1\n\nThe current AI notes are kept here instead."), setLabel(set))
                                .. dropWarning(plugin, set),
                            ok_text = _("Use"),
                            ok_callback = function()
                                plugin:restoreSavedNotes(set.id)
                                if touchmenu_instance then touchmenu_instance:closeMenu() end
                            end,
                            other_buttons_first = true,
                            other_buttons = {{
                                {
                                    text = _("Delete"),
                                    callback = function()
                                        UIManager:close(box)
                                        plugin.store:deleteSavedSet(set.id)
                                        plugin.store:save()
                                        if touchmenu_instance then touchmenu_instance:closeMenu() end
                                    end,
                                },
                            }},
                        }
                        UIManager:show(box)
                    end,
                })
            end
            if #items > 0 then items[#items].separator = true end
            table.insert(items, {
                text = _("Delete all earlier AI notes"),
                callback = function(touchmenu_instance)
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete the earlier AI notes of this book? The current AI notes and your own notes stay."),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            plugin.store:deleteSavedSets()
                            plugin.store:save()
                            if touchmenu_instance then touchmenu_instance:closeMenu() end
                        end,
                    })
                end,
            })
            return items
        end,
    }
end

--- "Re-create all AI notes" (Book & notes menu).
function AIMenu.recreateItem(plugin)
    return {
        text = _("Re-create all AI notes"),
        help_text = _("Creates this book's AI notes again, e.g. with another model or provider. Your own notes stay. The current AI notes are kept under \"Earlier AI notes\"."),
        enabled_func = function() return plugin.store ~= nil and plugin.store:countChapterNotes() > 0 end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            AIMenu.confirmRecreate(plugin, nil, nil, function() touchmenu_instance:updateItems() end)
        end,
    }
end

function AIMenu.settingsItems(plugin)
    local items = {
        {
            text_func = function() return T(_("Provider: %1"), _(currentProvider(plugin).name)) end,
            sub_item_table_func = function() return providerItems(plugin) end,
        },
        {
            text_func = function() return T(_("Model: %1"), currentModel(plugin) or _("not set")) end,
            sub_item_table_func = function() return modelItems(plugin) end,
        },
        {
            text = _("Set up API key"),
            help_text = _("Shows a QR code: scan it with your phone, get a key there and send it to the e-reader."),
            keep_menu_open = true,
            callback = function()
                plugin:startKeySetup()
            end,
        },
        {
            text_func = function()
                local provider = currentProvider(plugin)
                local fallback = (plugin:getSetting("ai_fallback_models") or {})[provider.id]
                if fallback == nil then fallback = provider.fallback_model end
                return T(_("Fallback model: %1"), (fallback and fallback ~= "") and fallback or _("none"))
            end,
            help_text = _("Only with \"When overloaded: other model\": the lighter model tried last, when the others are overloaded or at their limit."),
            enabled_func = function() return plugin:getSetting("ai_on_overload") == "switch" end,
            sub_item_table_func = function() return fallbackItems(plugin) end,
            advanced = true,
        },
        {
            text_func = function()
                return T(_("API key: %1"), AI.getKey(currentProvider(plugin).id) and _("saved") or _("missing"))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local provider = currentProvider(plugin)
                editText(T(_("API key for %1"), _(provider.name)), nil,
                    _("Paste or type the key. Leave empty to remove it."), function(text)
                        AI.setKey(provider.id, text)
                        touchmenu_instance:updateItems()
                        if text ~= "" then plugin:onApiKeySaved() end
                    end)
            end,
            hold_callback = function()
                UIManager:show(InfoMessage:new{ text = T(_("Keys are stored in:\n%1\n\nYou can also create this file on a computer:\nreturn { gemini = \"…\" }"), AI.keysFile()) })
            end,
        },
        {
            text_func = function()
                return T(_("Address: %1"), plugin:getSetting("ai_custom_url") or _("not set"))
            end,
            custom_only = true,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                editAddress(plugin, function() touchmenu_instance:updateItems() end)
            end,
        },
        {
            text = _("Test connection"),
            keep_menu_open = true,
            separator = true,
            callback = function()
                local cfg, reason = AI.configFrom(plugin.settings)
                if not cfg then
                    UIManager:show(InfoMessage:new{ text = errorText("config:" .. reason) })
                    return
                end
                local info = InfoMessage:new{ text = _("Testing…") }
                UIManager:show(info)
                Processor.testConnection(cfg, function(ok, err)
                    UIManager:close(info)
                    local text = ok and _("Connection works.")
                        or T(_("Connection failed: %1"), err and (err.kind .. (err.message and (" – " .. err.message) or "")) or "?")
                    UIManager:show(InfoMessage:new{ text = text })
                end)
            end,
        },
        {
            text_func = function()
                local labels = { wifi = _("whenever Wi-Fi is on"), charging = _("only while charging"), manual = _("only on request") }
                return T(_("AI notes automatically: %1"), labels[plugin:getSetting("ai_when")] or "?")
            end,
            help_text = _("Processing uses Wi-Fi and battery. 'Only while charging' processes a book while the device is plugged in; you can always start it yourself from the Story Recall menu or with a gesture."),
            sub_item_table = {
                {
                    text = _("Whenever Wi-Fi is on"),
                    radio = true,
                    checked_func = function() return plugin:getSetting("ai_when") == "wifi" end,
                    callback = function() plugin:setSetting("ai_when", "wifi") end,
                },
                {
                    text = _("Only while charging"),
                    radio = true,
                    checked_func = function() return plugin:getSetting("ai_when") == "charging" end,
                    callback = function() plugin:setSetting("ai_when", "charging") end,
                },
                {
                    text = _("Only on request (menu or gesture)"),
                    radio = true,
                    checked_func = function() return plugin:getSetting("ai_when") == "manual" end,
                    callback = function() plugin:setSetting("ai_when", "manual") end,
                    separator = true,
                },
                {
                    text = _("Turn Wi-Fi on while charging"),
                    help_text = _("When the device is plugged in and chapters still lack AI notes, Story Recall turns Wi-Fi on by itself, also if it was turned off automatically after a while."),
                    enabled_func = function() return plugin:getSetting("ai_when") == "charging" end,
                    checked_func = function() return plugin:getSetting("ai_wifi_when_charging") end,
                    callback = function()
                        plugin:setSetting("ai_wifi_when_charging", not plugin:getSetting("ai_wifi_when_charging"))
                    end,
                },
            },
        },
        {
            text_func = function()
                return T(_("Language of the notes: %1"),
                    plugin:getSetting("ai_notes_language") == "book" and _("like the book") or _("like KOReader"))
            end,
            help_text = _("\"Like KOReader\": the notes are written in KOReader's language, also for books in another language. \"Like the book\": in the language of each book. Applies to notes created from now on."),
            sub_item_table = {
                {
                    text = _("Like KOReader"),
                    radio = true,
                    checked_func = function() return plugin:getSetting("ai_notes_language") ~= "book" end,
                    callback = function() plugin:setSetting("ai_notes_language", "device") end,
                },
                {
                    text = _("Like the book"),
                    radio = true,
                    checked_func = function() return plugin:getSetting("ai_notes_language") == "book" end,
                    callback = function() plugin:setSetting("ai_notes_language", "book") end,
                },
            },
        },
        {
            text = _("Process the whole book when opening it"),
            help_text = _("On: all chapters are processed in the background as soon as Wi-Fi is available, so the book works offline afterwards. Off: only chapters you have read."),
            checked_func = function() return plugin:getSetting("ai_whole_book") end,
            callback = function()
                plugin:setSetting("ai_whole_book", not plugin:getSetting("ai_whole_book"))
            end,
        },
        {
            -- Stay with the chosen model (same quality, never a pricier one) or switch
            text_func = function()
                return T(_("When overloaded: %1"), plugin:getSetting("ai_on_overload") == "switch"
                    and _("other model") or _("wait"))
            end,
            help_text = _("Wait: the AI notes always come from your chosen model. When the provider is overloaded or the daily limit is reached, Story Recall pauses and continues by itself later. Other model: after 3 failures in a row it tries the provider's other models (faster, but the notes can differ in quality, and another model may cost more)."),
            sub_item_table = {
                {
                    text = _("Wait and stay with the model"),
                    radio = true,
                    checked_func = function() return plugin:getSetting("ai_on_overload") ~= "switch" end,
                    callback = function() plugin:setSetting("ai_on_overload", "wait") end,
                },
                {
                    text = _("Other model after 3 failures"),
                    radio = true,
                    checked_func = function() return plugin:getSetting("ai_on_overload") == "switch" end,
                    callback = function() plugin:setSetting("ai_on_overload", "switch") end,
                },
            },
        },
        {
            text_func = function() return T(_("Chapters per request: %1"), plugin:getSetting("ai_batch_chapters")) end,
            advanced = true,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text = _("Chapters per request"),
                    info_text = _("More chapters per request: fewer requests, less battery and Wi-Fi time. 1: strictest spoiler protection, because the AI never sees a later chapter."),
                    value = plugin:getSetting("ai_batch_chapters"),
                    value_min = 1,
                    value_max = 5,
                    default_value = 3,
                    callback = function(spin)
                        plugin:setSetting("ai_batch_chapters", spin.value)
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        },
        {
            text_func = function() return T(_("Pause between requests: %1 s"), plugin:getSetting("ai_delay")) end,
            advanced = true,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text = _("Pause between requests"),
                    info_text = _("Free plans allow only a few requests per minute. A longer pause avoids hitting the limit."),
                    value = plugin:getSetting("ai_delay"),
                    value_min = 0,
                    value_max = 120,
                    default_value = 5,
                    unit = "s",
                    callback = function(spin)
                        plugin:setSetting("ai_delay", spin.value)
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        },
    }
    -- Rarely needed: in a submenu, so the AI menu fits on one page. The
    -- address only matters for an own service (the menu is built when opened).
    local custom = currentProvider(plugin).id == "custom"
    local main, advanced = {}, {}
    for _i, item in ipairs(items) do
        if custom or not item.custom_only then
            table.insert(item.advanced and advanced or main, item)
        end
        item.advanced, item.custom_only = nil, nil
    end
    table.insert(main, { text = _("Advanced"), sub_item_table = advanced })
    return main
end

return AIMenu
