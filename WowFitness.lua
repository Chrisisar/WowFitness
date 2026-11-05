-- Namespace & SavedVariables initialization
local addonName, addon = ...
WoWFitnessDB = WoWFitnessDB or {
    workoutsQueue = {}, -- Stores pending exercises: { {exercise = "Pushups", count = 20, done = false}, ... }
    lastHourlyCheck = time()
}

-- Configuration: Map game events to workouts and repetitions
local WORKOUT_MAPPING = {
	WAITING_QUEUE = { exercise = "Mobility", count = 1 },
	SERVER_DC = { exercise = "Push-up, Sit-up", count = 10 },
    PLAYER_LEVEL_UP = { exercise = "Burpees/Squat-jump", count = 5 },
    BAG_FULL = { exercise = "Biceps curls/squat lunges", count = 10 },
    LEVEL_CAP = { exercise = "row/walk", count = 30 },
    QUEST_TURNED_IN = { exercise = "Plank (seconds)", count = 30 },
    DUNGEON_COMPLETE = { exercise = "Reach side plank/kickback", count = 10 },
    RAID_COMPLETE = { exercise = "arm circles (F+B) + pike plank/RDL", count = 10 },
    PLAYER_DEAD = { exercise = "Burpees/Squat-jump", count = 20 },
}
local WORKOUT_MAPPING_ORDER = {
    "WAITING_QUEUE",
    "SERVER_DC",
    "PLAYER_LEVEL_UP",
    "BAG_FULL",
    "LEVEL_CAP",
    "QUEST_TURNED_IN",
    "DUNGEON_COMPLETE",
    "RAID_COMPLETE",
    "PLAYER_DEAD"
}

WoWFitnessDB.workoutMapping = WoWFitnessDB.workoutMapping or {}
for eventType, default in pairs(WORKOUT_MAPPING) do
    local saved = WoWFitnessDB.workoutMapping[eventType]
    if type(saved) == "table"
        and type(saved.exercise) == "string"
        and type(saved.count) == "number"
        and saved.count > 0
        and saved.count == math.floor(saved.count) then
        WORKOUT_MAPPING[eventType] = {
            exercise = saved.exercise,
            count = saved.count
        }
    else
        WoWFitnessDB.workoutMapping[eventType] = {
            exercise = default.exercise,
            count = default.count
        }
    end
end

-- Create main frame for event handling
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("BAG_UPDATE") -- Used to check if bags are full
frame:RegisterEvent("PLAYER_REGEN_DISABLED") -- Fired when entering combat
frame:RegisterEvent("PLAYER_REGEN_ENABLED")  -- Fired when leaving combat
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")

local lastBagFullCheck = 0

-- UI Frame for the Hourly Notification Popup
local workoutFrame = nil
local configFrame = nil

local function CreateWorkoutConfigUI()
    if configFrame then return configFrame end

    configFrame = CreateFrame("Frame", "WoWFitnessConfig", UIParent, "BasicFrameTemplateWithInset")
    configFrame:SetSize(500, 460)
    configFrame:SetPoint("CENTER")
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", configFrame.StartMoving)
    configFrame:SetScript("OnDragStop", configFrame.StopMovingOrSizing)
    configFrame:Hide()

    configFrame.title = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    configFrame.title:SetPoint("TOP", configFrame, "TOP", 0, -5)
    configFrame.title:SetText("Workout Mapping")

    local instruction = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    instruction:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 18, -34)
    instruction:SetText("Edit the exercise and repetition count for each event.")

    local eventHeader = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    eventHeader:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 18, -54)
    eventHeader:SetWidth(135)
    eventHeader:SetText("Event")

    local exerciseHeader = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    exerciseHeader:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 158, -54)
    exerciseHeader:SetText("Exercise")

    local countHeader = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    countHeader:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 405, -54)
    countHeader:SetText("Reps")

    configFrame.rows = {}
    for rowIndex, eventType in ipairs(WORKOUT_MAPPING_ORDER) do
        local data = WORKOUT_MAPPING[eventType]
        local row = CreateFrame("Frame", nil, configFrame)
        row:SetSize(464, 30)
        row:SetPoint("TOPLEFT", configFrame, "TOPLEFT", 18, -72 - ((rowIndex - 1) * 38))

        row.eventLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.eventLabel:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.eventLabel:SetWidth(135)
        row.eventLabel:SetJustifyH("LEFT")
        row.eventLabel:SetText(eventType)

        row.exercise = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        row.exercise:SetSize(235, 24)
        row.exercise:SetPoint("LEFT", row, "LEFT", 140, 0)
        row.exercise:SetAutoFocus(false)
        row.exercise:SetText(data.exercise)

        row.count = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        row.count:SetSize(55, 24)
        row.count:SetPoint("LEFT", row.exercise, "RIGHT", 12, 0)
        row.count:SetAutoFocus(false)
        row.count:SetNumeric(true)
        row.count:SetMaxLetters(5)
        row.count:SetText(tostring(data.count))

        row.eventType = eventType
        table.insert(configFrame.rows, row)
    end

    local saveButton = CreateFrame("Button", nil, configFrame, "GameMenuButtonTemplate")
    saveButton:SetSize(120, 25)
    saveButton:SetPoint("BOTTOM", configFrame, "BOTTOM", 0, 12)
    saveButton:SetText("Save")
    saveButton:SetScript("OnClick", function()
        local updated = {}
        for _, row in ipairs(configFrame.rows) do
            local exercise = row.exercise:GetText()
            local count = tonumber(row.count:GetText())
            if not exercise or not string.match(exercise, "%S") then
                print("|cFFFF0000[WoW Fitness]:|r Exercise names cannot be empty.")
                row.exercise:SetFocus()
                return
            end
            if not count or count < 1 or count ~= math.floor(count) then
                print("|cFFFF0000[WoW Fitness]:|r Repetition counts must be positive whole numbers.")
                row.count:SetFocus()
                return
            end
            updated[row.eventType] = { exercise = exercise, count = count }
        end

        for eventType, data in pairs(updated) do
            WORKOUT_MAPPING[eventType] = data
            WoWFitnessDB.workoutMapping[eventType] = {
                exercise = data.exercise,
                count = data.count
            }
        end
        print("|cFF00FF00[WoW Fitness]:|r Workout mapping saved.")
        configFrame:Hide()
    end)

    return configFrame
end

local function CreateWorkoutUI()
    if workoutFrame then return workoutFrame end

    -- Main Window
    workoutFrame = CreateFrame("Frame", "WoWFitnessModal", UIParent, "BasicFrameTemplateWithInset")
    workoutFrame:SetSize(350, 400)
    workoutFrame:SetPoint("CENTER")
    workoutFrame:SetMovable(true)
    workoutFrame:EnableMouse(true)
    workoutFrame:RegisterForDrag("LeftButton")
    workoutFrame:SetScript("OnDragStart", workoutFrame.StartMoving)
	workoutFrame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing() -- Essential: anchors the frame at its new coordinates
		self:SetUserPlaced(true)   -- Optional: tells WoW to save this position in its layout cache
	end)
    workoutFrame:Hide()

    -- Title
    workoutFrame.title = workoutFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    workoutFrame.title:SetPoint("TOP", workoutFrame, "TOP", 0, -5)
    workoutFrame.title:SetText("Hourly Workout Check-in!")

    -- Scrollable area or content container
    workoutFrame.content = CreateFrame("Frame", nil, workoutFrame)
    workoutFrame.content:SetPoint("TOPLEFT", 10, -30)
    workoutFrame.content:SetPoint("BOTTOMRIGHT", -10, 40)

    -- Close / Acknowledge Button
    workoutFrame.closeBtn = CreateFrame("Button", nil, workoutFrame, "GameMenuButtonTemplate")
    workoutFrame.closeBtn:SetSize(120, 25)
    workoutFrame.closeBtn:SetPoint("BOTTOMRIGHT", workoutFrame, "BOTTOMRIGHT", -10, 10)
    workoutFrame.closeBtn:SetText("Confirm / Close")
    workoutFrame.closeBtn:SetScript("OnClick", function()
        -- Clean up completed workouts from database
        local remaining = {}
        for _, item in ipairs(WoWFitnessDB.workoutsQueue) do
            if not item.done then
                table.insert(remaining, item)
            end
        end
        WoWFitnessDB.workoutsQueue = remaining
        workoutFrame:Hide()
    end)

    workoutFrame.configureBtn = CreateFrame("Button", nil, workoutFrame, "GameMenuButtonTemplate")
    workoutFrame.configureBtn:SetSize(100, 25)
    workoutFrame.configureBtn:SetPoint("BOTTOMLEFT", workoutFrame, "BOTTOMLEFT", 10, 10)
    workoutFrame.configureBtn:SetText("Configure")
    workoutFrame.configureBtn:SetScript("OnClick", function()
        CreateWorkoutConfigUI():Show()
    end)

    return workoutFrame
end

local function RefreshWorkoutUI()
    local ui = CreateWorkoutUI()
    
    -- Clear previous checkboxes if any
    if ui.checkboxes then
        for _, cb in ipairs(ui.checkboxes) do cb:Hide() end
    end
    ui.checkboxes = {}

    local yOffset = -10
    if #WoWFitnessDB.workoutsQueue == 0 then
        local lbl = ui.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("TOPLEFT", 10, yOffset)
        lbl:SetText("No pending workouts! Great job!")
        table.insert(ui.checkboxes, lbl)
        return
    end-- 1. Group and sum workouts by exercise name for display purposes
    local displayMap = {}
    for _, item in ipairs(WoWFitnessDB.workoutsQueue) do
        if not item.done then
            if displayMap[item.exercise] then
                displayMap[item.exercise].count = displayMap[item.exercise].count + item.count
            else
                displayMap[item.exercise] = {
                    exercise = item.exercise,
                    count = item.count,
                    done = false
                }
            end
        end
    end

    -- Convert the map back into a temporary list for rendering
    local displayList = {}
    for _, item in pairs(displayMap) do
        table.insert(displayList, item)
    end

    if #displayList == 0 then
        local lbl = ui.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        lbl:SetPoint("TOPLEFT", 10, yOffset)
        lbl:SetText("No pending workouts! Great job!")
        table.insert(ui.checkboxes, lbl)
        return
    end

    -- 2. Render the grouped list
    for i, entry in ipairs(displayList) do
        local cb = CreateFrame("CheckButton", "WoWFitnessCheck"..i, ui.content, "InterfaceOptionsCheckButtonTemplate")
        cb:SetPoint("TOPLEFT", 10, yOffset)
        cb.Text:SetText(entry.count .. "x " .. entry.exercise)
        cb:SetChecked(entry.done)
        
        -- When checked, mark all underlying database items matching this exercise as done
        cb:SetScript("OnClick", function(self)
            local isChecked = self:GetChecked()
            entry.done = isChecked
            for _, dbItem in ipairs(WoWFitnessDB.workoutsQueue) do
                if dbItem.exercise == entry.exercise then
                    dbItem.done = isChecked
                end
            end
        end)

        table.insert(ui.checkboxes, cb)
        yOffset = yOffset - 35
    end
end

-- Function to queue workouts triggered by events
local function AddWorkout(eventType)
    local data = WORKOUT_MAPPING[eventType]
    if data then
        table.insert(WoWFitnessDB.workoutsQueue, {
            exercise = data.exercise,
            count = data.count,
            done = false
        })
        print("|cFF00FF00[WoW Fitness]:|r Fitness event: " .. eventType .. ". Workout added: " .. data.count .. "x " .. data.exercise)
    end
end

local heartbeatTimer = 0
-- Event Handler
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonLoaded = ...
        if addonLoaded == addonName then
            print("|cFF00FF00WoW Fitness Forever loaded successfully!|r")
            CreateWorkoutUI()
        end
	elseif event == "PLAYER_ENTERING_WORLD" then
        -- Give the game 5 seconds after loading into the world to stabilize bag caches
        C_Timer.After(5, function()
            isLoggedIn = true
        end)
		-- local isInitialLogin, isReloadingUi = ...
        
        -- -- If it's not a reload, check if the previous session ended abruptly
        -- if not isReloadingUi then
            -- local currentTime = time()
            -- local timeSinceLastHeartbeat = currentTime - (WoWFitnessDB.lastHeartbeat or currentTime)
            
            -- -- If last heartbeat was between 2 minutes and 24 hours ago, 
            -- -- it means you were abruptly cut off (disconnected/crashed/Alt+F4).
            -- -- (Adjust the 120 seconds threshold if needed)
            -- if timeSinceLastHeartbeat > 60 and timeSinceLastHeartbeat < 86400 then
                -- print("|cFFFF0000[WoW Fitness]:|r Unclean disconnect detected! Penalty added.")
                -- table.insert(WoWFitnessDB.workoutsQueue, {
                    -- exercise = "Disconnect Penalty (Burpees)",
                    -- count = 10,
                    -- done = false
                -- })
            -- end
        -- end
        
        -- -- Reset heartbeat on successful entry
        -- WoWFitnessDB.lastHeartbeat = time()

    -- elseif event == "PLAYER_LOGOUT" then
        -- -- Set heartbeat to 0 on clean logout so it doesn't trigger a false positive next login
        -- WoWFitnessDB.lastHeartbeat = 0
    elseif event == "PLAYER_DEAD" then
        AddWorkout("PLAYER_DEAD")
    elseif event == "PLAYER_LEVEL_UP" then
        AddWorkout("PLAYER_LEVEL_UP")
    elseif event == "QUEST_TURNED_IN" then
        AddWorkout("QUEST_TURNED_IN")
    elseif event == "BAG_UPDATE" then
		-- Ignore bag updates entirely until the game has fully loaded in
        if not isLoggedIn then return end
        -- Throttle bag checks to avoid performance hits
        local currentTime = GetTime()
        if currentTime - lastBagFullCheck > 5 then
            lastBagFullCheck = currentTime
            local isFull = true
            for bag = 0, 4 do
                local freeSlots = C_Container.GetContainerNumFreeSlots(bag)
                if freeSlots and freeSlots > 0 then
                    isFull = false
                    break
                end
            end
            if isFull then
                AddWorkout("BAG_FULL")
            end
        end
	elseif event == "PLAYER_REGEN_DISABLED" then
        -- Automatically hide the workout window when entering combat
        if workoutFrame and workoutFrame:IsShown() then
            workoutFrame:Hide()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Optional: You can leave this blank if you want it to stay hidden 
        -- until you manually type /wf or the hourly timer triggers.
    end
end)

-- Hourly Timer Check (Runs every second, triggers every 3600 seconds)
local elapsedTimer = 0
-- local updateTicker = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    elapsedTimer = elapsedTimer + elapsed
    if elapsedTimer >= 10 then -- Check every 10 seconds (change to 3600 for production hourly checks)
		if not InCombatLockdown() then
			elapsedTimer = 0
			
			-- Check if 1 hour (3600 seconds) has passed since last notification
			if time() - WoWFitnessDB.lastHourlyCheck >= 3600 then
				WoWFitnessDB.lastHourlyCheck = time()
				if #WoWFitnessDB.workoutsQueue > 0 then
					RefreshWorkoutUI()
					workoutFrame:Show()
					PlaySound(SOUNDKIT.RAID_WARNING)
				end
			end
		end
    end
	-- -- Heartbeat loop
    -- updateTicker = updateTicker + elapsed
    -- if updateTicker >= 30 then
        -- updateTicker = 0
        -- if UnitAffectingCombat("player") == false or UnitAffectingCombat("player") == true then
            -- -- Keep updating the timestamp as long as the game is running normally
            -- WoWFitnessDB.lastHeartbeat = time()
        -- end
    -- end
end)

-- Slash command to manually open the window (/wf or /wowfitness)
SLASH_WOWFITNESS1 = "/wowfitness"
SLASH_WOWFITNESS2 = "/wf"
SlashCmdList["WOWFITNESS"] = function(msg)
    RefreshWorkoutUI()
    workoutFrame:Show()
end