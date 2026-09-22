--[[--
A one-shot KOReader user patch that runs the audio probe on the device and
writes the result where a USB host can read it.

Why this exists: a Kobo in USB mass storage mode has handed its disk to the
host, so nothing on the device is running and nothing can be executed remotely.
The device has to run the probe itself, and a priority-2 user patch is the
supported way to get code to run after UIManager is ready without touching
KOReader's own files.

**It disables itself after one run** by renaming itself to `.done`, so it does
not fire on every launch. Delete the `.done` file to be rid of it, or rename it
back to re-run.

Everything is wrapped in pcall: a diagnostic must never be able to stop
KOReader from starting.
]]

local ok_outer, err_outer = pcall(function()
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local logger = require("logger")

    local SELF_PATH = debug.getinfo(1, "S").source:match("^@(.*)$")
    -- Overridable so this patch can be exercised in the KOReader emulator
    -- before being trusted on a device nobody can watch.
    local PROBE = os.getenv("KOBO_PROBE_SCRIPT") or "/mnt/onboard/probe-kobo.sh"
    local OUTPUT = os.getenv("KOBO_PROBE_OUTPUT") or "/mnt/onboard/probe-kobo-output.txt"

    -- Disable first, not last: if the probe itself wedges the device, a reboot
    -- must not run it again.
    local function disable_self()
        if SELF_PATH then
            os.rename(SELF_PATH, SELF_PATH .. ".done")
        end
    end

    local function device_section()
        local lines = { "", "=== KOReader's own view of this device ===" }
        local ok, Device = pcall(require, "device")
        if not ok then
            lines[#lines + 1] = "(could not load the device module)"
            return table.concat(lines, "\n") .. "\n"
        end
        local function flag(name)
            local fn = Device[name]
            if type(fn) ~= "function" then return name .. ": (absent)" end
            local called_ok, value = pcall(fn, Device)
            return string.format("%s: %s", name, called_ok and tostring(value) or "(error)")
        end
        lines[#lines + 1] = "model: " .. tostring(Device.model)
        -- isMTK is the authoritative MTK-vs-i.MX6 split, and therefore which
        -- audio route this device needs. Far better than parsing crash.log.
        for _, name in ipairs{ "isKobo", "isMTK", "isSDL", "hasNaturalLight" } do
            lines[#lines + 1] = flag(name)
        end
        return table.concat(lines, "\n") .. "\n"
    end

    UIManager:scheduleIn(2, function()
        local notice = InfoMessage:new{
            text = "Running the audio probe…\n\nThis takes a few seconds. "
                .. "The screen may pause.",
            timeout = 3,
        }
        UIManager:show(notice)

        -- One tick later, so the notice is actually painted before we block.
        UIManager:scheduleIn(0.5, function()
            disable_self()

            local ok, result = pcall(function()
                local pipe = io.popen("sh " .. PROBE .. " 2>&1")
                if not pipe then return nil, "could not run the probe" end
                local text = pipe:read("*a")
                pipe:close()
                return text
            end)

            local body
            if ok and result and result ~= "" then
                body = result
            else
                body = "PROBE FAILED: " .. tostring(result or "no output")
                    .. "\nIs " .. PROBE .. " present?\n"
            end

            local handle = io.open(OUTPUT, "w")
            if handle then
                handle:write(body, device_section())
                handle:close()
                logger.warn("audio probe written to " .. OUTPUT)
                UIManager:show(InfoMessage:new{
                    text = "Audio probe done.\n\nWritten to:\nprobe-kobo-output.txt\n\n"
                        .. "Connect USB and it will be at the root of the device.",
                })
            else
                UIManager:show(InfoMessage:new{
                    text = "Audio probe ran but could not write "
                        .. OUTPUT .. "\n\nIs the device still in USB mode?",
                })
            end
        end)
    end)
end)

if not ok_outer then
    -- Never fatal. Log and let KOReader carry on.
    pcall(function()
        require("logger").warn("2-probe-audio patch failed:", tostring(err_outer))
    end)
end
