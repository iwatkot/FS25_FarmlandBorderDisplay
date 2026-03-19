-- =============================================================================
-- FarmlandBorderDisplay.lua
-- Draws colored polygon outlines around every farmland.
--
-- Color legend:
--   Green = owned by the local player's farm
--   Gray  = unowned (available for purchase)
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
FBD.pointSizePercent = 100   -- marker size percentage
FBD.heightPercent    = 200   -- marker height-above-ground percentage

FBD.CONTROLS     = {}    -- UI element references for the settings menu
FBD.menuInjected = false -- guard: inject the settings UI only once

-- cached list: { [farmlandId] = { farmland=<Farmland>, segs={{wx1,wy1,wz1, wx2,wy2,wz2}, ...} } }
FBD.cache       = {}
FBD.cacheBuilt  = false
FBD.terrainNode = nil
FBD.meshRoot    = nil
FBD.meshProtoRoot = nil
FBD.meshProtoNode = nil
FBD.visuals     = {}
FBD.visualStatsLogged = false

-- Display colours [r, g, b] (0-1 range)
FBD.COLORS = {
    OWNED   = { 0.10, 0.95, 0.10 },  -- green
    UNOWNED = { 0.55, 0.55, 0.55 },  -- gray
    FOREIGN = { 1.00, 0.10, 0.15 },  -- red
}

FBD.BORDER_BASE_Y_OFFSET = 0.8
FBD.BORDER_BASE_POINT_SIZE = 0.10
FBD.BORDER_POINT_MULTIPLIER = 40
FBD.PERCENT_MIN = 10
FBD.PERCENT_MAX = 200
FBD.PERCENT_STEP = 10

-- =============================================================================
-- addModEventListener callbacks
-- =============================================================================

--- Called once the map has been loaded and g_farmlandManager is ready.
function FBD:loadMap(_filename)
    self.terrainNode = g_currentMission and g_currentMission.terrainRootNode
    self.cache       = {}
    self.cacheBuilt  = false
    self.visuals     = {}
    self.visualStatsLogged = false

    self:_ensureMeshRoot()

    -- Load a tiny generic mesh once and clone it per segment.
    -- This avoids per-frame debug drawing and allows visible thickness.
    local relProtoPath = "data/placeables/brandless/animalHusbandries/doghouse/dogball.i3d"
    local candidates = {
        relProtoPath,
    }
    if Utils ~= nil and Utils.getFilename ~= nil then
        local p = Utils.getFilename(relProtoPath, nil)
        if p ~= nil and p ~= "" then
            candidates[#candidates + 1] = p
        end
    end
    if getAppBasePath ~= nil then
        local base = getAppBasePath()
        if base ~= nil and base ~= "" then
            candidates[#candidates + 1] = base .. relProtoPath
        end
    end

    local protoRoot = 0
    local usedPath = nil
    for _, path in ipairs(candidates) do
        protoRoot = loadI3DFile(path, false, false, false)
        if protoRoot ~= nil and protoRoot ~= 0 then
            usedPath = path
            break
        end
    end

    if protoRoot ~= nil and protoRoot ~= 0 then
        self.meshProtoRoot = protoRoot
        local n = getNumOfChildren(protoRoot)
        self.meshProtoNode = (n > 0) and getChildAt(protoRoot, 0) or protoRoot
        print(string.format("[%s] Prototype mesh loaded from '%s'.", MODNAME, usedPath or "<unknown>"))
    else
        print(string.format("[%s] WARNING: Could not load prototype mesh from any known path.", MODNAME))
    end

    -- Register a proxy with g_debugManager so that borders are also drawn
    -- while the ConstructionScreen / ShopMenu is open (the normal mission
    -- draw() callback is not invoked during those screens).
    if g_debugManager ~= nil then
        local proxy = {}
        proxy.getShouldBeDrawn = function()
            if not FBD.isEnabled then
                FBD:_setMeshVisible(false)
                return false
            end
            if not FBD.showInBuildMenu then
                FBD:_setMeshVisible(false)
                return false
            end
            if g_gui == nil or not g_gui:getIsGuiVisible() then
                FBD:_setMeshVisible(false)
                return false
            end
            local name = g_gui.currentGuiName
            local isBuildScreen = name == "ConstructionScreen"
                or name == "ShopMenu"
                or name == "ShopConfigScreen"
            if not isBuildScreen then
                FBD:_setMeshVisible(false)
            end
            return isBuildScreen
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
    self:_clearVisuals()

    self.cache      = {}
    self.cacheBuilt = false
    self.terrainNode = nil

    if g_debugManager ~= nil then
        g_debugManager:removeGroup(MODNAME)
    end

    FBD.writeSettings()
end

function FBD:_deleteVisualNodes()
    for _, visual in pairs(self.visuals) do
        if visual.rootNode ~= nil and visual.rootNode ~= 0 then
            delete(visual.rootNode)
        end
    end
    self.visuals = {}
    self.visualStatsLogged = false
end

function FBD:_sanitizePercent(v)
    local minV = FBD.PERCENT_MIN
    local maxV = FBD.PERCENT_MAX
    local step = FBD.PERCENT_STEP
    if v == nil then return minV end
    local n = math.floor((v + step * 0.5) / step) * step
    if n < minV then n = minV end
    if n > maxV then n = maxV end
    return n
end

function FBD:_getPercentValues()
    local values = {}
    for p = FBD.PERCENT_MIN, FBD.PERCENT_MAX, FBD.PERCENT_STEP do
        values[#values + 1] = p
    end
    return values
end

function FBD:_getPercentState(percent)
    local values = self:_getPercentValues()
    local p = self:_sanitizePercent(percent)
    for i, v in ipairs(values) do
        if v == p then return i end
    end
    return 1
end

function FBD:_getPercentFromState(state)
    local values = self:_getPercentValues()
    local i = math.max(1, math.min(state or 1, #values))
    return values[i]
end

function FBD:_applyVisualSettingsChange(needsCacheRebuild)
    if needsCacheRebuild then
        self.cacheBuilt = false
    end
    self:_deleteVisualNodes()
end

--- Called every render frame during normal gameplay (not during full-screen GUIs).
--- The DebugManager proxy registered in loadMap handles ConstructionScreen / ShopMenu.
function FBD:draw()
    if not self.isEnabled then
        self:_setMeshVisible(false)
        return
    end
    if not FBD.showInGame then
        self:_setMeshVisible(false)
        return
    end
    -- When a full-screen GUI is open the proxy handles rendering; skip to avoid double-drawing.
    if g_gui ~= nil and g_gui:getIsGuiVisible() then
        self:_setMeshVisible(false)
        return
    end
    if g_currentMission == nil then
        self:_setMeshVisible(false)
        return
    end

    -- Grab terrain node lazily (it may not be set on the very first frame)
    if self.terrainNode == nil or self.terrainNode == 0 then
        self.terrainNode = g_currentMission.terrainRootNode
        if self.terrainNode == nil or self.terrainNode == 0 then
            self:_setMeshVisible(false)
            return
        end
    end

    self:_renderBorders()
end

--- Shared rendering path used by both draw() and the DebugManager proxy.
function FBD:_renderBorders()
    if g_currentMission == nil then
        self:_setMeshVisible(false)
        return
    end

    if self.terrainNode == nil or self.terrainNode == 0 then
        self.terrainNode = g_currentMission.terrainRootNode
        if self.terrainNode == nil or self.terrainNode == 0 then
            self:_setMeshVisible(false)
            return
        end
    end

    self:_ensureMeshRoot()
    if self.meshRoot == nil or self.meshRoot == 0 then
        self:_setMeshVisible(false)
        return
    end

    if not self.cacheBuilt then
        self:_buildCache()
    end

    self:_ensureVisualsBuilt()

    local localFarmId  = g_currentMission:getFarmId()
    local mapping       = g_farmlandManager ~= nil and g_farmlandManager.farmlandMapping
    local showOnlyOwned = FBD.showOnlyOwned

    for id, entry in pairs(self.cache) do
        if entry.farmland ~= nil and self.visuals[id] ~= nil then
            local fid = (mapping and mapping[id]) or 0
            local visual = self.visuals[id]

            -- Ownership can change at runtime; rebuild this farmland's meshes on change.
            if visual.ownerFarmId ~= fid then
                self:_rebuildFarmlandVisual(id, entry, fid, localFarmId)
                visual = self.visuals[id]
            end

            setVisibility(visual.rootNode, (not showOnlyOwned or fid == localFarmId))
        end
    end

    self:_setMeshVisible(true)
end

function FBD:_setMeshVisible(visible)
    if self.meshRoot ~= nil and self.meshRoot ~= 0 then
        setVisibility(self.meshRoot, visible)
    end
end

function FBD:_ensureMeshRoot()
    if self.meshRoot ~= nil and self.meshRoot ~= 0 then
        return
    end

    if self.terrainNode == nil or self.terrainNode == 0 then
        if g_currentMission ~= nil then
            self.terrainNode = g_currentMission.terrainRootNode
        end
    end

    if self.terrainNode ~= nil and self.terrainNode ~= 0 then
        self.meshRoot = createTransformGroup("fbd_borderMeshRoot")
        link(self.terrainNode, self.meshRoot)
        setVisibility(self.meshRoot, false)
    end
end

function FBD:_clearVisuals()
    self:_deleteVisualNodes()

    if self.meshRoot ~= nil and self.meshRoot ~= 0 then
        delete(self.meshRoot)
    end
    if self.meshProtoRoot ~= nil and self.meshProtoRoot ~= 0 then
        delete(self.meshProtoRoot)
    end
    self.meshRoot = nil
    self.meshProtoRoot = nil
    self.meshProtoNode = nil
end

function FBD:_ensureVisualsBuilt()
    if self.meshRoot == nil or self.meshRoot == 0 or self.meshProtoNode == nil or self.meshProtoNode == 0 then
        return
    end
    if next(self.visuals) ~= nil then
        return
    end

    local localFarmId  = g_currentMission:getFarmId()
    local mapping = g_farmlandManager ~= nil and g_farmlandManager.farmlandMapping
    local farmlandCount = 0
    local segTotal = 0
    local cloneFailTotal = 0
    for id, entry in pairs(self.cache) do
        farmlandCount = farmlandCount + 1
        local fid = (mapping and mapping[id]) or 0
        local built, cloneFails = self:_rebuildFarmlandVisual(id, entry, fid, localFarmId)
        segTotal = segTotal + (built or 0)
        cloneFailTotal = cloneFailTotal + (cloneFails or 0)
    end

    if not self.visualStatsLogged then
        self.visualStatsLogged = true
        print(string.format("[%s] Visual mesh build: %d farmland roots, %d segment nodes, %d clone failures.",
            MODNAME, farmlandCount, segTotal, cloneFailTotal))
    end
end

function FBD:_rebuildFarmlandVisual(id, entry, fid, localFarmId)
    if self.meshRoot == nil or self.meshRoot == 0 or self.meshProtoNode == nil or self.meshProtoNode == 0 then
        return
    end

    local oldVisual = self.visuals[id]
    if oldVisual ~= nil and oldVisual.rootNode ~= nil and oldVisual.rootNode ~= 0 then
        delete(oldVisual.rootNode)
    end

    local rootNode = createTransformGroup(string.format("fbd_farmland_%d", id))
    link(self.meshRoot, rootNode)

    local color = self:_pickColor(fid, localFarmId)
    local r, g, b = color[1], color[2], color[3]
    local pointSize = FBD.BORDER_BASE_POINT_SIZE
        * FBD.BORDER_POINT_MULTIPLIER
        * (FBD.pointSizePercent / 100)
    local builtCount = 0
    local cloneFailures = 0

    for _, seg in ipairs(entry.segs) do
        local x1, y1, z1 = seg[1], seg[2], seg[3]
        local x2, y2, z2 = seg[4], seg[5], seg[6]
        local dx = x2 - x1
        local dz = z2 - z1
        local len = math.sqrt(dx * dx + dz * dz)

        if len > 0.0001 then
            local node = clone(self.meshProtoNode, false, false, false)
            if node == nil or node == 0 then
                -- Fallback: some i3d roots clone reliably only from loaded root.
                node = clone(self.meshProtoRoot, false, false, false)
            end
            if node == nil or node == 0 then
                cloneFailures = cloneFailures + 1
            else
            link(rootNode, node)

            local mx = (x1 + x2) * 0.5
            local my = (y1 + y2) * 0.5
            local mz = (z1 + z2) * 0.5
            setWorldTranslation(node, mx, my, mz)
            setWorldRotation(node, 0, 0, 0)
            -- Transform API uses x,y,z; keep all equal for true point blocks.
            setScale(node, pointSize, pointSize, pointSize)

            -- dogball uses vehicle shader material with colorScale custom parameter.
            setShaderParameterRecursive(node, "colorScale", r, g, b, 1, false)
            builtCount = builtCount + 1
            end
        end
    end

    self.visuals[id] = {
        rootNode = rootNode,
        ownerFarmId = fid,
    }

    return builtCount, cloneFailures
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
    self:_deleteVisualNodes()

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
    local yOff    = FBD.BORDER_BASE_Y_OFFSET * (FBD.heightPercent / 100)

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
        local p = getXMLInt(xmlFile,  b .. ".pointSizePercent#v") ; if p ~= nil then FBD.pointSizePercent = FBD:_sanitizePercent(p) end
        local h = getXMLInt(xmlFile,  b .. ".heightPercent#v")    ; if h ~= nil then FBD.heightPercent    = FBD:_sanitizePercent(h) end
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
        setXMLInt(xmlFile,  b .. ".pointSizePercent#v", FBD.pointSizePercent)
        setXMLInt(xmlFile,  b .. ".heightPercent#v",    FBD.heightPercent)
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
    elseif id == "fbd_pointSizePct" then
        FBD.pointSizePercent = FBD:_getPercentFromState(state)
        FBD:_applyVisualSettingsChange(false)
    elseif id == "fbd_heightPct" then
        FBD.heightPercent = FBD:_getPercentFromState(state)
        FBD:_applyVisualSettingsChange(true)
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
    local multiTemplateBox = page.multiVolumeVoiceBox

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

    local function addPercent(id, label, tooltip, getValue)
        local source = multiTemplateBox or templateBox
        local box    = source:clone(page.generalSettingsLayout)
        box.id       = id .. "_box"
        local opt    = box.elements[1]
        opt.id       = id
        opt.target   = FBD_Controls
        opt:setCallback("onClickCallback", "onOptionChanged")
        opt:setDisabled(false)

        local values = FBD:_getPercentValues()
        local texts = {}
        for _, v in ipairs(values) do
            texts[#texts + 1] = string.format("%d%%", v)
        end
        opt:setTexts(texts)
        opt:setState(FBD:_getPercentState(getValue()))

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
    addPercent("fbd_pointSizePct", "Point size (%)",
        "Choose the size of markers",
        function() return FBD.pointSizePercent end)
    addPercent("fbd_heightPct", "Height offset (%)",
        "How high the markers are above the ground",
        function() return FBD.heightPercent end)

    page.generalSettingsLayout:invalidateLayout()

    -- Refresh toggle states whenever the settings page is opened.
    InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(
        InGameMenuSettingsFrame.onFrameOpen,
        function()
            if FBD.CONTROLS.fbd_buildMenu  ~= nil then FBD.CONTROLS.fbd_buildMenu:setState( FBD.showInBuildMenu and 2 or 1) end
            if FBD.CONTROLS.fbd_inGame     ~= nil then FBD.CONTROLS.fbd_inGame:setState(    FBD.showInGame      and 2 or 1) end
            if FBD.CONTROLS.fbd_onlyOwned  ~= nil then FBD.CONTROLS.fbd_onlyOwned:setState( FBD.showOnlyOwned   and 2 or 1) end
            if FBD.CONTROLS.fbd_pointSizePct ~= nil then FBD.CONTROLS.fbd_pointSizePct:setState(FBD:_getPercentState(FBD.pointSizePercent)) end
            if FBD.CONTROLS.fbd_heightPct    ~= nil then FBD.CONTROLS.fbd_heightPct:setState(FBD:_getPercentState(FBD.heightPercent)) end
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
