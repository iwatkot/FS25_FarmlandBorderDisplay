-- =============================================================================
-- FarmlandBorderDisplay.lua
-- Draws colored polygon outlines around every farmland.
--
-- Color legend:
--   Cyan  = owned by the local player's farm
--   White = unowned (available for purchase)
--   Red   = owned by another player or AI
--
-- Settings are available in the in-game menu (ESC → Settings).
-- =============================================================================

local MODNAME = g_currentModName or "FarmlandBorderDisplay"

-- =============================================================================
-- Module table
-- =============================================================================
FarmlandBorderDisplay = {}
local FBD = FarmlandBorderDisplay

FBD.isEnabled   = true   -- master on/off switch
-- Runtime settings (persisted to XML, editable in InGameMenu)
FBD.showInBuildMenu = true   -- show when ConstructionScreen / ShopMenu is open
FBD.showInGame      = false  -- show during normal gameplay
FBD.showOnlyOwned   = false  -- when true, hide unowned and foreign farmlands

FBD.CONTROLS     = {}    -- UI element references for the settings menu
FBD.menuInjected = false -- guard: inject the settings UI only once

-- cached list: { [farmlandId] = { farmland=<Farmland>, segs={{wx1,wy1,wz1, wx2,wy2,wz2}, ...} } }
FBD.cache       = {}
FBD.cacheBuilt  = false
FBD.terrainNode = nil

-- Display colours [r, g, b] (0-1 range)
FBD.COLORS = {
    OWNED   = { 0.00, 0.90, 1.00 },  -- cyan
    UNOWNED = { 1.00, 1.00, 1.00 },  -- white
    FOREIGN = { 1.00, 0.10, 0.15 },  -- red
}

FBD.BORDER_Y_OFFSET = 0.4  -- metres above terrain so lines are always visible

-- =============================================================================
-- addModEventListener callbacks
-- =============================================================================

--- Called once the map has been loaded and g_farmlandManager is ready.
function FBD:loadMap(_filename)
    self.terrainNode = g_currentMission and g_currentMission.terrainRootNode
    self.cache       = {}
    self.cacheBuilt  = false

    -- Register a proxy with g_debugManager so that borders are also drawn
    -- while the ConstructionScreen / ShopMenu is open (the normal mission
    -- draw() callback is not invoked during those screens).
    if g_debugManager ~= nil then
        local proxy = {}
        proxy.getShouldBeDrawn = function()
            if not FBD.isEnabled then return false end
            if not FBD.showInBuildMenu then return false end
            if g_gui == nil or not g_gui:getIsGuiVisible() then return false end
            local name = g_gui.currentGuiName
            return name == "ConstructionScreen"
                or name == "ShopMenu"
                or name == "ShopConfigScreen"
        end
        proxy.draw = function()
            FBD:_renderBorders()
        end
        g_debugManager:addElement(proxy, MODNAME)
    end

    FBD.readSettings()
    FBD.injectMenu()
end

--- Called when the map is unloaded (back to main menu / mission end).
function FBD:deleteMap()
    self.cache      = {}
    self.cacheBuilt = false
    self.terrainNode = nil

    if g_debugManager ~= nil then
        g_debugManager:removeGroup(MODNAME)
    end

    FBD.writeSettings()
end

--- Called every render frame during normal gameplay (not during full-screen GUIs).
--- The DebugManager proxy registered in loadMap handles ConstructionScreen / ShopMenu.
function FBD:draw()
    if not self.isEnabled then return end
    if not FBD.showInGame then return end
    -- When a full-screen GUI is open the proxy handles rendering; skip to avoid double-drawing.
    if g_gui ~= nil and g_gui:getIsGuiVisible() then return end
    if g_currentMission == nil then return end

    -- Grab terrain node lazily (it may not be set on the very first frame)
    if self.terrainNode == nil or self.terrainNode == 0 then
        self.terrainNode = g_currentMission.terrainRootNode
        if self.terrainNode == nil or self.terrainNode == 0 then return end
    end

    self:_renderBorders()
end

--- Shared rendering path used by both draw() and the DebugManager proxy.
function FBD:_renderBorders()
    if g_currentMission == nil then return end

    if self.terrainNode == nil or self.terrainNode == 0 then
        self.terrainNode = g_currentMission.terrainRootNode
        if self.terrainNode == nil or self.terrainNode == 0 then return end
    end

    if not self.cacheBuilt then
        self:_buildCache()
    end

    local localFarmId  = g_currentMission:getFarmId()
    local mapping       = g_farmlandManager ~= nil and g_farmlandManager.farmlandMapping
    local showOnlyOwned = FBD.showOnlyOwned

    for id, entry in pairs(self.cache) do
        if entry.farmland ~= nil then
            local fid = (mapping and mapping[id]) or 0
            if not showOnlyOwned or fid == localFarmId then
                local color = self:_pickColor(fid, localFarmId)
                local r, g, b = color[1], color[2], color[3]
                for _, seg in ipairs(entry.segs) do
                    drawDebugLine(seg[1], seg[2], seg[3], r, g, b, seg[4], seg[5], seg[6], r, g, b)
                end
            end
        end
    end
end

-- =============================================================================
-- Farmland polygon cache
-- =============================================================================

--- Builds the border cache by scanning the farmland BitVectorMap.
--- Each pixel in the map holds a farmland ID.  Wherever two adjacent pixels
--- have different IDs (or a pixel is at the map edge) we emit a world-space
--- line segment that forms part of that farmland's visible border.
---
--- Segment coordinates are fully pre-baked (including terrain Y) so that
--- draw() is as light as possible.
function FBD:_buildCache()
    self.cacheBuilt = true
    self.cache = {}

    if g_farmlandManager == nil then
        print(string.format("[%s] WARNING: g_farmlandManager is nil.", MODNAME))
        return
    end

    local fm      = g_farmlandManager
    local localMap = fm.localMap
    if localMap == nil or localMap == 0 then
        print(string.format("[%s] WARNING: g_farmlandManager.localMap is nil. Cannot draw borders.", MODNAME))
        return
    end

    local mapW    = fm.localMapWidth
    local mapH    = fm.localMapHeight
    local numBits = fm.numberOfBits
    local notBuy  = (2 ^ numBits) - 1
    local terrain = self.terrainNode
    local tsz     = g_currentMission.terrainSize
    local tf      = tsz / mapW          -- metres per pixel
    local hW      = mapW * 0.5
    local hH      = mapH * 0.5
    local yOff    = FBD.BORDER_Y_OFFSET

    -- Pre-bake one segment into the cache for a valid farmland ID.
    local function addSeg(id, wx1, wz1, wx2, wz2)
        if id == 0 or id == notBuy then return end
        local farmland = fm.farmlands[id]
        if farmland == nil then return end
        local wy1 = getTerrainHeightAtWorldPos(terrain, wx1, 0, wz1) + yOff
        local wy2 = getTerrainHeightAtWorldPos(terrain, wx2, 0, wz2) + yOff
        if self.cache[id] == nil then
            self.cache[id] = { farmland = farmland, segs = {} }
        end
        local s = self.cache[id].segs
        s[#s + 1] = {wx1, wy1, wz1, wx2, wy2, wz2}
    end

    local edgeCount = 0

    for py = 0, mapH - 1 do
        for px = 0, mapW - 1 do
            local id    = getBitVectorMapPoint(localMap, px, py, 0, numBits)
            local valid = (id > 0 and id ~= notBuy)

            -- Vertical edge with right neighbour (or right map boundary)
            local rid = (px + 1 < mapW) and getBitVectorMapPoint(localMap, px + 1, py, 0, numBits) or 0
            if rid ~= id then
                local wx  = (px + 1 - hW) * tf
                local wz1 = (py     - hH) * tf
                local wz2 = (py + 1 - hH) * tf
                if valid then
                    addSeg(id,  wx, wz1, wx, wz2)
                    edgeCount = edgeCount + 1
                end
                if rid > 0 and rid ~= notBuy then
                    addSeg(rid, wx, wz1, wx, wz2)
                end
            end

            -- Horizontal edge with bottom neighbour (or bottom map boundary)
            local bid = (py + 1 < mapH) and getBitVectorMapPoint(localMap, px, py + 1, 0, numBits) or 0
            if bid ~= id then
                local wx1 = (px     - hW) * tf
                local wx2 = (px + 1 - hW) * tf
                local wz  = (py + 1 - hH) * tf
                if valid then
                    addSeg(id,  wx1, wz, wx2, wz)
                    edgeCount = edgeCount + 1
                end
                if bid > 0 and bid ~= notBuy then
                    addSeg(bid, wx1, wz, wx2, wz)
                end
            end

            -- Left map boundary
            if px == 0 and valid then
                local wx  = (0 - hW) * tf
                local wz1 = (py     - hH) * tf
                local wz2 = (py + 1 - hH) * tf
                addSeg(id, wx, wz1, wx, wz2)
                edgeCount = edgeCount + 1
            end

            -- Top map boundary
            if py == 0 and valid then
                local wx1 = (px     - hW) * tf
                local wx2 = (px + 1 - hW) * tf
                local wz  = (0 - hH) * tf
                addSeg(id, wx1, wz, wx2, wz)
                edgeCount = edgeCount + 1
            end
        end
    end

    local farmCount = 0
    for _ in pairs(self.cache) do farmCount = farmCount + 1 end

    if farmCount == 0 then
        print(string.format("[%s] WARNING: No farmland borders found in the density map.", MODNAME))
    else
        print(string.format("[%s] Border cache built: %d farmland(s), %d edge segment(s).",
            MODNAME, farmCount, edgeCount))
    end
end

-- =============================================================================
-- Color selection
-- =============================================================================

--- Returns the appropriate [r,g,b] color for a farmland given its owner farm ID.
--- @param fid         current owner farm ID from g_farmlandManager.farmlandMapping
--- @param localFarmId the local player's farm ID
function FBD:_pickColor(fid, localFarmId)
    if fid == localFarmId and localFarmId ~= 0 then
        return FBD.COLORS.OWNED
    elseif fid ~= 0 then
        return FBD.COLORS.FOREIGN
    else
        return FBD.COLORS.UNOWNED
    end
end

-- =============================================================================
-- Settings persistence
-- =============================================================================

function FBD.readSettings()
    local path = Utils.getFilename("modSettings/FarmlandBorderDisplay.xml", getUserProfileAppPath())
    if not fileExists(path) then
        FBD.writeSettings()
        return
    end
    local xmlFile = loadXMLFile("FBD_cfg", path)
    if xmlFile ~= 0 then
        local b = "farmlandBorderDisplay"
        local v = getXMLBool(xmlFile, b .. ".showInBuildMenu#v") ; if v ~= nil then FBD.showInBuildMenu = v end
        local w = getXMLBool(xmlFile, b .. ".showInGame#v")      ; if w ~= nil then FBD.showInGame      = w end
        local x = getXMLBool(xmlFile, b .. ".showOnlyOwned#v")   ; if x ~= nil then FBD.showOnlyOwned   = x end
        delete(xmlFile)
    end
end

function FBD.writeSettings()
    local path = Utils.getFilename("modSettings/FarmlandBorderDisplay.xml", getUserProfileAppPath())
    local xmlFile = createXMLFile("FBD_cfg", path, "farmlandBorderDisplay")
    if xmlFile ~= 0 then
        local b = "farmlandBorderDisplay"
        setXMLBool(xmlFile, b .. ".showInBuildMenu#v", FBD.showInBuildMenu)
        setXMLBool(xmlFile, b .. ".showInGame#v",      FBD.showInGame)
        setXMLBool(xmlFile, b .. ".showOnlyOwned#v",   FBD.showOnlyOwned)
        saveXMLFile(xmlFile)
        delete(xmlFile)
    end
end

-- =============================================================================
-- InGameMenu settings injection
-- =============================================================================

-- Named callback target required by FS25's UI callback dispatch.
FBD_Controls = {}

function FBD_Controls:onOptionChanged(state, menuOption)
    local id  = menuOption.id
    local val = (state == 2)
    if     id == "fbd_buildMenu"   then FBD.showInBuildMenu = val
    elseif id == "fbd_inGame"      then FBD.showInGame      = val
    elseif id == "fbd_onlyOwned"   then FBD.showOnlyOwned   = val
    end
    FBD.writeSettings()
end

function FBD.injectMenu()
    if FBD.menuInjected then return end

    local inGameMenu = g_gui ~= nil and g_gui.screenControllers[InGameMenu]
    if inGameMenu == nil then return end
    local page = inGameMenu.pageSettings
    if page == nil then return end

    FBD.menuInjected  = true
    FBD_Controls.name = page.name  -- required by FS25 focus/callback system

    -- Use the wood-harvester binary option as the clone template (standard FS25 element).
    local templateBox = page.checkWoodHarvesterAutoCutBox
    if templateBox == nil then
        print(string.format("[%s] WARNING: settings template element not found; UI not injected.", MODNAME))
        return
    end

    local function updateFocusIds(elem)
        if not elem then return end
        elem.focusId = FocusManager:serveAutoFocusId()
        for _, child in pairs(elem.elements) do updateFocusIds(child) end
    end

    local function addBinary(id, label, tooltip, getValue)
        local box    = templateBox:clone(page.generalSettingsLayout)
        box.id       = id .. "_box"
        local opt    = box.elements[1]
        opt.id       = id
        opt.target   = FBD_Controls
        opt:setCallback("onClickCallback", "onOptionChanged")
        opt:setDisabled(false)
        opt:setTexts({ g_i18n:getText("ui_off"), g_i18n:getText("ui_on") })
        opt:setState(getValue() and 2 or 1)
        if opt.elements[1]  ~= nil then opt.elements[1]:setText(tooltip) end
        if box.elements[2]  ~= nil then box.elements[2]:setText(label)   end
        FBD.CONTROLS[id] = opt
        updateFocusIds(box)
        table.insert(page.controlsList, box)
    end

    -- Section header
    local header = nil
    for _, elem in ipairs(page.generalSettingsLayout.elements) do
        if elem.name == "sectionHeader" then
            header = elem:clone(page.generalSettingsLayout)
            break
        end
    end
    if header ~= nil then
        header:setText("Farmland Border Display")
        header.focusId = FocusManager:serveAutoFocusId()
        table.insert(page.controlsList, header)
        FBD.CONTROLS["fbd_header"] = header
    end

    addBinary("fbd_buildMenu", "Show in build menu",
        "Show farmland borders in Construction / Shop screens",
        function() return FBD.showInBuildMenu end)
    addBinary("fbd_inGame",   "Show in game",
        "Show farmland borders during normal gameplay",
        function() return FBD.showInGame end)
    addBinary("fbd_onlyOwned", "Show only owned",
        "Hide unowned and foreign farmlands",
        function() return FBD.showOnlyOwned end)

    page.generalSettingsLayout:invalidateLayout()

    -- Refresh toggle states whenever the settings page is opened.
    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
        InGameMenuSettingsFrame.onFrameOpen,
        function()
            if FBD.CONTROLS.fbd_buildMenu  ~= nil then FBD.CONTROLS.fbd_buildMenu:setState( FBD.showInBuildMenu and 2 or 1) end
            if FBD.CONTROLS.fbd_inGame     ~= nil then FBD.CONTROLS.fbd_inGame:setState(    FBD.showInGame      and 2 or 1) end
            if FBD.CONTROLS.fbd_onlyOwned  ~= nil then FBD.CONTROLS.fbd_onlyOwned:setState( FBD.showOnlyOwned   and 2 or 1) end
        end)

    -- Allow keyboard / controller navigation through our controls.
    FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
        if gui == "ingameMenuSettings" then
            for _, ctrl in pairs(FBD.CONTROLS) do
                if ctrl.focusId and not FocusManager.currentFocusData.idToElementMapping[ctrl.focusId] then
                    FocusManager:loadElementFromCustomValues(ctrl, nil, nil, false, false)
                end
            end
            page.generalSettingsLayout:invalidateLayout()
        end
    end)
end

-- =============================================================================
-- Register with the event system
-- =============================================================================
addModEventListener(FBD)
