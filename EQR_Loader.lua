-- EQR Hub Loader  (share THIS file publicly, not the main script)
local URLS = {
    "https://raw.githubusercontent.com/dwitty19/EQRHub-/main/EQR_Rayfield.lua",
    "https://rawgithub.com/dwitty19/EQRHub-/main/EQR_Rayfield.lua",
}

local function notify(msg)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification",{
            Title = "EQR Hub", Text = msg, Duration = 6,
        })
    end)
end

local loaded = false
for attempt = 1, 3 do
    for i, url in ipairs(URLS) do
        print(string.format("[EQR Loader] Attempt %d — source %d: %s", attempt, i, url))
        local ok, src = pcall(function() return game:HttpGet(url, true) end)
        if not ok or type(src) ~= "string" or #src < 500 then
            print("[EQR Loader] Fetch failed or response too short, skipping.")
            task.wait(2)
        else
            local fn, err = loadstring(src)
            if not fn then
                print("[EQR Loader] loadstring error: " .. tostring(err))
                task.wait(2)
            else
                local runOk, runErr = pcall(fn)
                if runOk then
                    print("[EQR Loader] ✅ Loaded from source " .. i)
                    loaded = true; break
                else
                    print("[EQR Loader] Runtime error: " .. tostring(runErr))
                    notify("❌ EQR error: " .. tostring(runErr):sub(1,80))
                    loaded = true; break
                end
            end
        end
    end
    if loaded then break end
    notify("⚠️ EQR Hub loading... (attempt " .. attempt .. "/3)")
    task.wait(3)
end

if not loaded then
    notify("❌ EQR Hub failed after 3 attempts. Check GitHub URL or retry.")
    warn("[EQR Loader] All sources exhausted.")
end
