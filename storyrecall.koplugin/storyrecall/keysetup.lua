--[[--
Enter the API key from a phone: the e-reader serves a small web page on the
home Wi-Fi and shows its address as a QR code. The phone opens the page, the
key is pasted there and sent straight to the e-reader. No server outside the
home network is involved.

A random token in the address makes sure only the phone that scanned the
code can send a key. The page stops after 10 minutes or after one key.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local socket = require("socket")
local AI = require("storyrecall/ai")
local _ = require("storyrecall/i18n")
local T = require("ffi/util").template
local Screen = Device.screen

local FIRST_PORT = 8742
local PORT_TRIES = 10
local POLL_INTERVAL = 0.3
local LIFETIME = 600 -- seconds

-- How to get a key, per provider: link, free or paid, steps, what a key looks like.
local function providerGuides()
    return {
        gemini = {
            link = "https://aistudio.google.com/app/apikey",
            free = true,
            title = _("How to get a free Google Gemini key"),
            steps = {
                _("Tap the button below; Google AI Studio opens in a new tab."),
                _("Sign in with your Google account and tap \"Create API key\"."),
                _("Copy the key and come back to this tab."),
            },
            placeholder = "AIzaSy…",
        },
        anthropic = {
            link = "https://console.anthropic.com/settings/keys",
            title = _("How to get a Claude key"),
            steps = {
                _("Tap the button below; the Anthropic Console opens."),
                _("Sign in, add credit under Billing, then tap \"Create Key\"."),
                _("Copy the key and come back to this tab."),
            },
            placeholder = "sk-ant-…",
        },
        openai = {
            link = "https://platform.openai.com/api-keys",
            title = _("How to get an OpenAI key"),
            steps = {
                _("Tap the button below; the OpenAI platform opens."),
                _("Sign in, add credit under Billing, then tap \"Create new secret key\"."),
                _("Copy the key and come back to this tab."),
            },
            placeholder = "sk-proj-…",
        },
        openrouter = {
            link = "https://openrouter.ai/keys",
            title = _("How to get an OpenRouter key"),
            steps = {
                _("Tap the button below; OpenRouter opens."),
                _("Sign in and tap \"Create Key\". Some models are free (their name ends in \":free\")."),
                _("Copy the key, come back, and enter the model on the e-reader."),
            },
            placeholder = "sk-or-…",
        },
        mistral = {
            link = "https://console.mistral.ai/api-keys",
            title = _("How to get a Mistral key"),
            steps = {
                _("Tap the button below; the Mistral console opens."),
                _("Sign in, choose a plan (a free trial plan is available), then tap \"Create new key\"."),
                _("Copy the key and come back to this tab."),
            },
            placeholder = "…",
        },
        deepseek = {
            link = "https://platform.deepseek.com/api_keys",
            title = _("How to get a DeepSeek key"),
            steps = {
                _("Tap the button below; the DeepSeek platform opens."),
                _("Sign in, top up your balance, then tap \"Create new API key\"."),
                _("Copy the key and come back to this tab."),
            },
            placeholder = "sk-…",
        },
        custom = {
            title = _("Your own service"),
            steps = {
                _("Use the key of your OpenAI-compatible service (e.g. a local server or another provider)."),
                _("Below the key, also enter the service's address and the model name. You find both in the service's documentation."),
            },
            placeholder = "…",
        },
    }
end

local KeySetup = {}

-- The device's address on the local network. Connecting a UDP socket sends no
-- packet; it only makes the system pick the outgoing interface.
local function localIP()
    local udp = socket.udp()
    if not udp then return end
    udp:settimeout(0.5)
    pcall(udp.setpeername, udp, "8.8.8.8", 80)
    local ip = udp:getsockname()
    udp:close()
    if ip and ip ~= "0.0.0.0" and ip ~= "127.0.0.1" then return ip end
end

local function randomToken()
    local file = io.open("/dev/urandom", "rb")
    local bytes = file and file:read(12)
    if file then file:close() end
    if not bytes or #bytes < 12 then
        math.randomseed(os.time() + math.floor(os.clock() * 1e6))
        local parts = {}
        for i = 1, 12 do parts[i] = string.char(math.random(0, 255)) end
        bytes = table.concat(parts)
    end
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function htmlEscape(text)
    return (tostring(text):gsub("[&<>\"]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ["\""] = "&quot;" }))
end

local function urlDecode(text)
    text = text:gsub("+", " ")
    return (text:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

local function parseForm(body)
    local fields = {}
    for pair in body:gmatch("[^&]+") do
        local key, value = pair:match("^([^=]*)=(.*)$")
        if key then fields[urlDecode(key)] = urlDecode(value) end
    end
    return fields
end

local PAGE_STYLE = [[
body{font-family:-apple-system,system-ui,sans-serif;max-width:32rem;margin:0 auto;padding:1.4rem 1.1rem;color:#2b2622;background:#f6f1e7}
h1{font-family:Georgia,"Times New Roman",serif;font-weight:normal;font-size:1.7rem;margin:0 0 .2rem}h1 small{display:block;font-family:-apple-system,system-ui,sans-serif;font-size:.9rem;color:#7a6f63;margin-top:.2rem}
p{line-height:1.45}
.step{border-top:1px solid #d9cfbf;padding:1rem 0 .4rem;margin-top:.6rem}
.step h2{font-family:Georgia,"Times New Roman",serif;font-weight:normal;font-size:1.2rem;margin:0 0 .7rem}.num{color:#9a8a76;margin-right:.35rem}
.tiles{border:1px solid #d9cfbf;border-radius:.5rem;background:#fffdf8;overflow:hidden}.tiles input{display:none}
.tiles label{display:flex;align-items:center;justify-content:space-between;padding:.75rem .9rem;border-bottom:1px solid #eee5d6;font-size:1rem}
.tiles label:last-of-type{border-bottom:0}.tiles label::before{content:"";width:1rem;height:1rem;border:2px solid #9a8a76;border-radius:50%;margin-right:.7rem;flex:none}
.tiles input:checked+label{background:#f1e8d8}.tiles input:checked+label::before{background:#2b2622;border-color:#2b2622;box-shadow:inset 0 0 0 2px #f1e8d8}
.tiles label span:first-child{flex:1}.free{font-size:.75rem;color:#2f6b3f;border:1px solid #2f6b3f;border-radius:1rem;padding:.05rem .45rem}
.guide{margin-top:.9rem}.guide h3{font-size:.95rem;margin:0 0 .3rem;color:#4a4038}.guide ol{margin:.2rem 0;padding-left:1.2rem;line-height:1.5}
input[type=text]{width:100%;box-sizing:border-box;font-size:1rem;padding:.75rem;border:1px solid #b9ad9b;border-radius:.4rem;background:#fffdf8;font-family:ui-monospace,Menlo,monospace}
.btn{display:block;box-sizing:border-box;width:100%;margin-top:.8rem;font-size:1.05rem;padding:.85rem;border:0;border-radius:2rem;background:#2b2622;color:#f6f1e7;text-align:center;text-decoration:none}
.btn.light{background:transparent;color:#2b2622;border:1px solid #2b2622}.hint{color:#7a6f63;font-size:.88rem;margin:.5rem 0 0}
]]

function KeySetup:formPage()
    local guides = providerGuides()
    local tiles, blocks = {}, {}
    for _i, provider in ipairs(AI.PROVIDERS) do
        local guide = guides[provider.id] or {}
        table.insert(tiles, string.format(
            '<input type="radio" name="provider" id="p_%s" value="%s"%s><label for="p_%s"><span>%s</span>%s</label>',
            provider.id, provider.id, provider.id == self.provider_id and " checked" or "", provider.id,
            htmlEscape(_(provider.name)), guide.free and ('<span class="free">' .. htmlEscape(_("free")) .. '</span>') or ""))
        local steps = {}
        for _j, step in ipairs(guide.steps or {}) do
            table.insert(steps, "<li>" .. htmlEscape(step) .. "</li>")
        end
        table.insert(blocks, string.format(
            '<div class="guide" id="g_%s" data-ph="%s"><h3>%s</h3><ol>%s</ol>%s</div>',
            provider.id, htmlEscape(guide.placeholder or ""), htmlEscape(guide.title or provider.name), table.concat(steps),
            guide.link and string.format('<a class="btn" href="%s" target="_blank" rel="noopener">%s ↗</a>', guide.link, htmlEscape(_("Open the key page"))) or ""))
    end
    return table.concat{
        '<!doctype html><html><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width,initial-scale=1">',
        '<title>Story Recall</title><style>', PAGE_STYLE, '</style></head><body>',
        '<h1>Story Recall<small>', htmlEscape(_("Three steps, then your e-reader can create story notes.")), '</small></h1>',
        '<form method="post" action="/save">',
        '<input type="hidden" name="t" value="', self.token, '">',
        '<div class="step"><h2><span class="num">1</span>', htmlEscape(_("Choose a provider and get a key")), '</h2>',
        '<div class="tiles">', table.concat(tiles), '</div>', table.concat(blocks), '</div>',
        '<div class="step"><h2><span class="num">2</span>', htmlEscape(_("Paste the key")), '</h2>',
        '<input id="k" name="key" type="text" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" required>',
        '<p class="hint">', htmlEscape(_("Tap and hold the field, then Paste.")), '</p>',
        '<button type="button" id="paste" class="btn light" style="display:none">', htmlEscape(_("Paste from clipboard")), '</button>',
        '<div id="cx" style="display:none">',
        '<p class="hint" style="margin-top:1rem">', htmlEscape(_("Address (OpenAI-compatible)")), '</p>',
        '<input id="cu" name="url" type="text" inputmode="url" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="https://example.com/v1" value="', htmlEscape(self.custom_url or ""), '">',
        '<p class="hint" style="margin-top:1rem">', htmlEscape(_("Model")), '</p>',
        '<input id="cm" name="model" type="text" autocomplete="off" autocapitalize="off" autocorrect="off" spellcheck="false" placeholder="model-name" value="', htmlEscape(self.custom_model or ""), '">',
        '</div></div>',
        '<div class="step"><h2><span class="num">3</span>', htmlEscape(_("Send it")), '</h2>',
        '<button type="submit" class="btn">', htmlEscape(_("Send to e-reader")), '</button>',
        '<p class="hint">', htmlEscape(_("The key goes directly to your e-reader over your home Wi-Fi.")), '</p></div>',
        '</form>',
        '<script>',
        'var k=document.getElementById("k");',
        'function u(){var c=document.querySelector("input[name=provider]:checked");',
        'document.querySelectorAll(".guide").forEach(function(g){var on=c&&g.id=="g_"+c.value;g.style.display=on?"block":"none";if(on)k.placeholder=g.getAttribute("data-ph");});',
        'var cu=c&&c.value=="custom";document.getElementById("cx").style.display=cu?"block":"none";',
        'document.getElementById("cu").required=cu;document.getElementById("cm").required=cu;}',
        'document.querySelectorAll("input[name=provider]").forEach(function(r){r.onchange=u;});u();',
        'if(navigator.clipboard&&navigator.clipboard.readText&&window.isSecureContext){var b=document.getElementById("paste");b.style.display="block";',
        'b.onclick=function(){navigator.clipboard.readText().then(function(t){k.value=t.trim();});};}',
        '</script>',
        '</body></html>',
    }
end

local function messagePage(title, text)
    return table.concat{
        '<!doctype html><html><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width,initial-scale=1">',
        '<title>Story Recall</title><style>', PAGE_STYLE, '</style></head><body>',
        '<h1>', htmlEscape(title), '</h1><p>', htmlEscape(text), '</p></body></html>',
    }
end

local function respond(client, status, body)
    client:send(table.concat{
        "HTTP/1.1 ", status, "\r\n",
        "Content-Type: text/html; charset=utf-8\r\n",
        "Content-Length: ", tostring(#body), "\r\n",
        "Cache-Control: no-store\r\n",
        "Connection: close\r\n\r\n",
        body,
    })
end

-- This runs on the UI thread: a slow or hostile client on the network must
-- not be able to freeze the reader. Every read has a total time limit, the
-- whole request a deadline, and lines and headers are bounded.
local REQUEST_DEADLINE = 3 -- seconds for the whole request
local MAX_LINE = 2048
local MAX_HEADERS = 40

function KeySetup:handle(client)
    local deadline = socket.gettime() + REQUEST_DEADLINE
    local function readLine()
        local left = deadline - socket.gettime()
        if left <= 0 then return nil end
        client:settimeout(left, "t")
        local line = client:receive("*l")
        if line and #line > MAX_LINE then return nil end
        return line
    end
    local line = readLine()
    if not line then return end
    local method, path = line:match("^(%u+)%s+(%S+)")
    if not method then return end
    local content_length = 0
    local headers = 0
    while true do
        local header = readLine()
        headers = headers + 1
        if not header or headers > MAX_HEADERS then return end
        if header == "" then break end
        local name, value = header:match("^([^:]+):%s*(.*)$")
        if name and name:lower() == "content-length" then
            content_length = math.min(tonumber(value) or 0, 8192)
        end
    end

    if method == "GET" and path:match("^/%?") then
        local token = path:match("[?&]t=(%x+)")
        if token == self.token then
            return respond(client, "200 OK", self:formPage())
        end
        return respond(client, "403 Forbidden", messagePage(_("Link expired"), _("Scan the QR code on the e-reader again.")))
    end

    if method == "POST" and path == "/save" then
        local left = deadline - socket.gettime()
        if left <= 0 then return end
        client:settimeout(left, "t")
        local body = content_length > 0 and client:receive(content_length) or ""
        local fields = parseForm(body or "")
        local key = fields.key and fields.key:gsub("^%s+", ""):gsub("%s+$", "")
        if fields.t ~= self.token or not AI.getProvider(fields.provider) or not key or key == "" then
            return respond(client, "400 Bad Request", messagePage(_("Not saved"), _("Scan the QR code on the e-reader again.")))
        end
        local custom
        if fields.provider == "custom" then
            custom = KeySetup.cleanCustom(fields.url, fields.model)
            if not custom then
                return respond(client, "400 Bad Request", messagePage(_("Not saved"),
                    _("The address must start with https:// (http:// only for a server in your home network), and the model name must not be empty. Go back and check both.")))
            end
        end
        respond(client, "200 OK", messagePage(_("Saved"), _("The key is on your e-reader now. You can close this page.")))
        self:finish(fields.provider, key, custom)
        return
    end

    respond(client, "404 Not Found", messagePage(_("Not found"), _("Scan the QR code on the e-reader again.")))
end

function KeySetup:poll()
    self.poll_task = nil
    if not self.server then return end
    if os.time() - self.started > LIFETIME then
        self:stop()
        UIManager:show(InfoMessage:new{ text = _("The key setup page has been closed."), timeout = 3 })
        return
    end
    local client = self.server:accept()
    if client then
        local ok, err = pcall(self.handle, self, client)
        if not ok then logger.warn("StoryRecall key setup:", err) end
        client:close()
    end
    if self.server then
        self.poll_task = function() self:poll() end
        UIManager:scheduleIn(POLL_INTERVAL, self.poll_task)
    end
end

function KeySetup:stop()
    if self.poll_task then
        UIManager:unschedule(self.poll_task)
        self.poll_task = nil
    end
    if self.server then
        self.server:close()
        self.server = nil
    end
    if self.dialog then
        UIManager:close(self.dialog)
        self.dialog = nil
    end
end

--- Address and model of a custom service, or nil if unusable.
-- Accepts the full endpoint too (".../chat/completions"); requests add that part.
-- Unencrypted http:// only for addresses in the home network (a local server).
local function isLocalHost(host)
    host = host:lower()
    return host == "localhost" or host:match("%.local$") or host:match("^127%.") or host:match("^10%.")
        or host:match("^192%.168%.") or (host:match("^172%.(%d+)%.") and tonumber(host:match("^172%.(%d+)%.")) >= 16
            and tonumber(host:match("^172%.(%d+)%.")) <= 31)
end

--- Address of a custom service, or nil + reason.
-- Accepts the full endpoint too (".../chat/completions"); requests add that part.
function KeySetup.cleanUrl(url)
    url = (url or ""):gsub("^%s+", ""):gsub("%s+$", "")
    url = url:gsub("/+$", ""):gsub("/chat/completions$", "")
    local scheme, host = url:match("^(https?)://([^/:%s]+)")
    if not scheme then return nil, "invalid" end
    if scheme == "http" and not isLocalHost(host) then return nil, "http" end
    return url
end

--- Address and model of a custom service, or nil if unusable.
function KeySetup.cleanCustom(url, model)
    model = (model or ""):gsub("^%s+", ""):gsub("%s+$", "")
    url = KeySetup.cleanUrl(url)
    if not url or model == "" or model:find("%s") then return nil end
    return { url = url, model = model }
end

function KeySetup:finish(provider_id, key, custom)
    AI.setKey(provider_id, key)
    self:stop()
    local provider = AI.getProvider(provider_id)
    UIManager:show(InfoMessage:new{ text = T(_("API key for %1 saved."), _(provider.name)), timeout = 3 })
    if self.on_saved then self.on_saved(provider_id, custom) end
end

-- The dialog with the QR code.

local KeySetupDialog = InputContainer:extend{
    url = nil,
    on_close = nil,
}

function KeySetupDialog:init()
    local width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.85)
    local inner = width - 2 * Size.padding.large
    -- Leave room for title, text and button on short screens.
    local qr_size = math.floor(math.min(inner * 0.7, Screen:getHeight() * 0.38))
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            radius = Size.radius.window,
            padding = Size.padding.large,
            VerticalGroup:new{
                align = "center",
                TextBoxWidget:new{
                    text = _("Enter API key with your phone"),
                    face = Font:getFace("tfont"),
                    width = inner,
                    alignment = "center",
                },
                VerticalSpan:new{ width = Size.span.vertical_large },
                QRWidget:new{ text = self.url, width = qr_size, height = qr_size },
                VerticalSpan:new{ width = Size.span.vertical_large },
                TextBoxWidget:new{
                    text = _("Scan the code with your phone (same Wi-Fi), paste the key on the page and send it.") .. "\n\n" .. self.url,
                    face = Font:getFace("cfont", 16),
                    width = inner,
                    alignment = "center",
                },
                VerticalSpan:new{ width = Size.span.vertical_large },
                Button:new{
                    text = _("Cancel"),
                    width = math.floor(inner / 2),
                    callback = function() self:onClose() end,
                },
            },
        },
    }
end

function KeySetupDialog:onShow()
    UIManager:setDirty(self, "full")
end

function KeySetupDialog:onCloseWidget()
    -- Redraw everything below, so no part of the dialog stays on screen.
    UIManager:setDirty(nil, "full")
end

function KeySetupDialog:onClose()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

--- Start the key setup. Needs Wi-Fi.
-- @param provider_id provider preselected on the page
-- @param on_saved function(provider_id, custom) after a key was saved;
--        custom = { url, model } for the custom provider
-- @param custom current { url, model } of the custom provider, to prefill
function KeySetup.start(provider_id, on_saved, custom)
    local ip = localIP()
    if not ip then
        UIManager:show(InfoMessage:new{ text = _("No network address found. Is Wi-Fi on?") })
        return
    end
    local server, port
    for offset = 0, PORT_TRIES - 1 do
        server = socket.bind("*", FIRST_PORT + offset)
        if server then port = FIRST_PORT + offset break end
    end
    if not server then
        UIManager:show(InfoMessage:new{ text = _("Could not start the setup page. Please enter the key by hand.") })
        return
    end
    server:settimeout(0)

    local setup = setmetatable({
        server = server,
        token = randomToken(),
        provider_id = provider_id,
        on_saved = on_saved,
        custom_url = custom and custom.url,
        custom_model = custom and custom.model,
        started = os.time(),
    }, { __index = KeySetup })
    setup.url = string.format("http://%s:%d/?t=%s", ip, port, setup.token)
    setup.dialog = KeySetupDialog:new{
        url = setup.url,
        on_close = function()
            setup.dialog = nil
            setup:stop()
        end,
    }
    UIManager:show(setup.dialog)
    setup.poll_task = function() setup:poll() end
    UIManager:scheduleIn(POLL_INTERVAL, setup.poll_task)
    logger.dbg("StoryRecall: key setup page at", ip, port)
    return setup
end

return KeySetup
