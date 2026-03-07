-- =============================================================================
-- FarmlandBorderDisplay.lua
-- Draws colored polygon outlines around every farmland while the player is in
-- the building/shop placement menu.
--
-- Color legend:
--   Green  = owned by the local player's farm
--   Cyan   = leased by the local player's farm
--   Yellow = unowned (available for purchase)
--   Orange = owned by another player or AI
--
-- Console commands:
--   fbdToggle  – enable / disable the overlay
--   fbdAlways  – toggle "always on" mode (show outside build menu too)
-- =============================================================================

local MODNAME = g_currentModName or "FarmlandBorderDisplay"

-- =============================================================================
-- Module table
-- =============================================================================
FarmlandBorderDisplay = {}
local FBD = FarmlandBorderDisplay

FBD.isEnabled   = true   -- master on/off switch
FBD.alwaysShow  = false  -- if true, render outside build mode as well

-- cached list: { [farmlandId] = { farmland=<Farmland>, segs={{wx1,wy1,wz1, wx2,wy2,wz2}, ...} } }
FBD.cache       = {}
FBD.cacheBuilt  = false
FBD.terrainNode = nil

-- Display colours [r, g, b] (0-1 range)
FBD.COLORS = {
    OWNED   = { 0.10, 0.95, 0.10 },  -- bright green
    LEASED  = { 0.10, 0.80, 1.00 },  -- cyan
    UNOWNED = { 0.95, 0.95, 0.10 },  -- yellow
    FOREIGN = { 1.00, 0.50, 0.10 },  -- orange
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

    -- Register console commands so the player can toggle the mod at runtime.
    addConsoleCommand("fbdToggle", "Toggle Farmland Border Display on/off",    "cmdToggle",      FBD)
    addConsoleCommand("fbdAlways", "Show farmland borders even outside build mode", "cmdAlways", FBD)
end

--- Called when the map is unloaded (back to main menu / mission end).
function FBD:deleteMap()
    self.cache      = {}
    self.cacheBuilt = false
    self.terrainNode = nil

    removeConsoleCommand("fbdToggle")
    removeConsoleCommand("fbdAlways")
end

--- Called every render frame – this is where we draw the outlines.
function FBD:draw()
    if not self.isEnabled then return end
    if not self:_isPlacementActive() then return end
    if g_currentMission == nil then return end

    -- Grab terrain node lazily (it may not be set on the very first frame)
    if self.terrainNode == nil or self.terrainNode == 0 then
        self.terrainNode = g_currentMission.terrainRootNode
        if self.terrainNode == nil or self.terrainNode == 0 then return end
    end

    -- Build cache on first draw so the farmland manager is fully populated
    if not self.cacheBuilt then
        self:_buildCache()
    end

    local localFarmId = g_currentMission:getFarmId()

    for _, entry in pairs(self.cache) do
        if entry.farmland ~= nil then
            local color = self:_pickColor(entry.farmland, localFarmId)
            local r, g, b = color[1], color[2], color[3]
            for _, seg in ipairs(entry.segs) do
                -- FS25 signature: x0,y0,z0, r0,g0,b0, x1,y1,z1, r1,g1,b1 [,solid]
                drawDebugLine(seg[1], seg[2], seg[3], r, g, b, seg[4], seg[5], seg[6], r, g, b)
            end
        end
    end
end

-- =============================================================================
-- Console command handlers
-- =============================================================================

function FBD:cmdToggle()
    self.isEnabled = not self.isEnabled
    print(string.format("[%s] Overlay %s.", MODNAME, self.isEnabled and "ENABLED" or "DISABLED"))
end

function FBD:cmdAlways()
    self.alwaysShow = not self.alwaysShow
    print(string.format("[%s] Always-show mode %s.", MODNAME, self.alwaysShow and "ON" or "OFF"))
end

-- =============================================================================
-- Build mode / placement detection
-- =============================================================================

--- Returns true when the player is actively placing a building or has the
--- shop construction menu open.
function FBD:_isPlacementActive()
    if self.alwaysShow then return true end
    if g_currentMission == nil then return false end

    -- ── method 1: shop controller has a live preview node ─────────────────────
    local shop = g_currentMission.shopController
    if shop ~= nil then
        -- previewNode is non-nil / non-zero while an item is being dragged
        if shop.previewNode ~= nil and shop.previewNode ~= 0 then
            return true
        end
        -- activeItemClassName is set while the player is in placement mode
        if shop.activeItemClassName ~= nil then
            return true
        end
        -- Broader flag if the shop itself is visible
        if shop.isShopVisible == true then
            return true
        end
    end

    -- ── method 2: FS25 isBuildMode flag ───────────────────────────────────────
    if g_currentMission.isBuildMode == true then
        return true
    end

    -- ── method 3: check current GUI screen name ────────────────────────────────
    if g_gui ~= nil then
        local gui = g_gui.currentGui
        if gui ~= nil then
            local name = (gui.name or ""):lower()
            if name:find("shop")     ~= nil or
               name:find("construct") ~= nil or
               name:find("placement") ~= nil or
               name:find("build")     ~= nil then
                return true
            end
        end
    end

    return false
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

--- Returns the appropriate [r,g,b] color table for a given farmland.
function FBD:_pickColor(farmland, localFarmId)
    local fid = farmland.farmId or 0

    if fid == localFarmId then
        -- Distinguish leased vs fully owned if the game exposes that flag
        if farmland.isLeased == true then
            return FBD.COLORS.LEASED
        end
        return FBD.COLORS.OWNED
    elseif fid ~= 0 then
        -- Belongs to another farm (player or NPC/AI)
        return FBD.COLORS.FOREIGN
    else
        -- Unowned / purchasable
        return FBD.COLORS.UNOWNED
    end
end

-- =============================================================================
-- Register with the event system
-- =============================================================================
addModEventListener(FBD)
