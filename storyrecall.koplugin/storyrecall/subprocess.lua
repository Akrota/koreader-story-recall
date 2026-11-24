--[[--
Cleaning up after request subprocesses, so no zombie processes or open pipe
handles are left behind on the e-reader (same approach as KOReader's Trapper).
--]]

local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local Subprocess = {}

local INTERVAL = 1 -- seconds between checks
local MAX_CHECKS = 120

local EINTR = 4 -- Linux: a signal interrupted the call, just try again

--- Write the whole answer into the pipe, then close it (in the subprocess).
-- KOReader's ffiutil.writeToFD writes only once; a large answer could arrive
-- cut off if the system writes it in parts.
function Subprocess.writeAll(fd, data)
    local ffi = require("ffi")
    local C = ffi.C
    local ptr = ffi.cast("const char *", data)
    local left, offset = #data, 0
    while left > 0 do
        local written = tonumber(C.write(fd, ptr + offset, left))
        if written and written > 0 then
            offset, left = offset + written, left - written
        elseif written == -1 and ffi.errno() == EINTR then -- luacheck: ignore
            -- interrupted before anything was written: try again
        else
            break -- the reader is gone: nothing more to do
        end
    end
    C.close(fd)
    return left == 0
end

--- Collect a subprocess that has finished or is about to finish.
function Subprocess.reap(pid)
    if not pid then return end
    local checks = 0
    local function check()
        checks = checks + 1
        if not ffiutil.isSubProcessDone(pid) and checks < MAX_CHECKS then
            UIManager:scheduleIn(INTERVAL, check)
        end
    end
    check()
end

--- Stop a subprocess, then collect it and close its pipe.
-- @param fd the pipe to read its answer from (closed by reading it), or nil
function Subprocess.cancel(pid, fd)
    if not pid then return end
    ffiutil.terminateSubProcess(pid)
    local checks = 0
    local function check()
        checks = checks + 1
        if ffiutil.isSubProcessDone(pid) then
            if fd then ffiutil.readAllFromFD(fd) end -- reads to the end and closes it
            return
        end
        -- If it started writing, drain the pipe so its write() stops blocking.
        if fd and ffiutil.getNonBlockingReadSize(fd) ~= 0 then
            ffiutil.readAllFromFD(fd)
            fd = nil
        end
        if checks < MAX_CHECKS then UIManager:scheduleIn(INTERVAL, check) end
    end
    check()
end

--- Run one request in a subprocess while the reader stays usable.
-- Shows `text` with "Tap to cancel"; a tap stops the request. Standby is
-- blocked while it runs. A crash in the subprocess comes back as an error
-- instead of an empty answer.
-- @param opts { work = function() returning a JSON-serialisable table,
--               text = waiting message (nil: quietly in the background),
--               on_done = function(result),
--               timeout = seconds (default 900) }
--   on_done gets work's table, or { err = { kind, message } }. It is not
--   called after a cancel (tap, or job:cancel() when the book is closed).
-- @return job with job:cancel()
function Subprocess.run(opts)
    local InfoMessage = require("ui/widget/infomessage")
    local json = require("json")
    local _ = require("storyrecall/i18n")
    local job = {}

    local function safeWork()
        local ok, result = pcall(opts.work)
        if ok and type(result) == "table" then return result end
        return { err = { kind = "crash", message = tostring(result) } }
    end
    local function release()
        if job.task then UIManager:unschedule(job.task) end
        job.task = nil
        if job.standby then UIManager:allowStandby() end
        job.standby = false
        if job.busy then UIManager:close(job.busy) end
    end
    local function finish(result)
        if job.done then return end
        job.done = true
        job.pid = nil
        release()
        opts.on_done(result)
    end
    function job.cancel()
        if job.done then return end
        job.done = true
        if job.pid then Subprocess.cancel(job.pid, job.fd) end
        release()
    end

    -- Without `text` the request runs quietly in the background (no message).
    if opts.text then
        job.busy = InfoMessage:new{
            text = opts.text .. "\n\n" .. _("Tap to cancel."),
            -- Also called when we close it ourselves; job.done tells them apart.
            dismiss_callback = function() job.cancel() end,
        }
        UIManager:show(job.busy)
    end

    if jit.os == "OSX" then
        -- Desktop emulator: a forked child must not use the network (see processor).
        job.task = function() job.task = nil; finish(safeWork()) end
        UIManager:scheduleIn(0.3, job.task)
        return job
    end
    local json_encode = json.encode
    job.pid, job.fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        Subprocess.writeAll(write_fd, json_encode(safeWork()))
    end, true)
    if not job.pid then
        finish({ err = { kind = "subprocess", message = "subprocess" } })
        return job
    end
    UIManager:preventStandby()
    job.standby = true
    local started = os.time()
    local timeout = opts.timeout or 900
    local function poll()
        job.task = nil
        if job.done then return end
        local has_data = ffiutil.getNonBlockingReadSize(job.fd) ~= 0
        local done = not has_data and ffiutil.isSubProcessDone(job.pid)
        -- It may have written its answer right before ending: look once more.
        if done then has_data = ffiutil.getNonBlockingReadSize(job.fd) ~= 0 end
        local result
        if has_data then
            local raw = ffiutil.readAllFromFD(job.fd)
            if not done then Subprocess.reap(job.pid) end
            local ok, decoded = pcall(json.decode, raw or "")
            result = ok and type(decoded) == "table" and decoded or { err = { kind = "format", message = "no answer" } }
        elseif done then
            ffiutil.readAllFromFD(job.fd)
            result = { err = { kind = "crash", message = "request ended without answer" } }
        elseif os.time() - started > timeout then
            Subprocess.cancel(job.pid, job.fd)
            result = { err = { kind = "timeout", message = "timeout" } }
        else
            job.task = poll
            UIManager:scheduleIn(INTERVAL, poll)
            return
        end
        finish(result)
    end
    job.task = poll
    UIManager:scheduleIn(INTERVAL, poll)
    return job
end

return Subprocess
