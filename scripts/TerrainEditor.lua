-- ============================================================================
-- TerrainEditor.lua — 地形规划模式
-- 在预览模式下标注网格类型：空地(passable) / 障碍(blocked) / 目标区(target)
-- 支持可视化覆盖、左键选择、Ctrl 多选、类型转换、导出
-- 支持高度控制（-5m~10m）、预设高度、平滑过渡
-- ============================================================================

local TerrainEditor = {}

local Config = require("config.GameConfig")
local Shared = require("network.Shared")
local UI = require("urhox-libs/UI")
local AstroonTheme = require("config.AstroonTheme")

local EVENTS = Config.EVENTS

-- ============================================================================
-- 常量
-- ============================================================================

-- 地形类型
local CELL_OPEN     = "open"       -- 空地（可通行）
local CELL_BLOCKED  = "blocked"    -- 障碍（不可通行）
local CELL_TARGET   = "target"     -- 目标区

-- 覆盖颜色（空地不绘制填充，障碍/目标用较高不透明度确保清晰）
local COLOR_OPEN    = Color(0.3, 0.5, 1.0, 0.25)   -- 浅蓝（仅用于图例参考，不绘制填充）
local COLOR_BLOCKED = Color(1.0, 0.2, 0.2, 0.3)    -- 红色半透明
local COLOR_TARGET  = Color(0.7, 0.2, 1.0, 0.3)    -- 紫色半透明

-- 选中高亮
local COLOR_SELECTED = Color(1.0, 1.0, 0.2, 0.6)   -- 黄色高亮边框

-- 网格高度（depthTest=true，地面节点已隐藏，覆盖层贴近 Y=0 充当地面颜色）
local OVERLAY_Y     = -0.01   -- 覆盖层高度（略低于地面，确保被3D模型遮挡）
local SELECT_Y      =  0.005  -- 选中框高度（略高于覆盖层，但低于模型底部）

-- (填充改用 AddTriangle，无需线密度常量)

-- ============================================================================
-- 状态
-- ============================================================================

---@type Scene
local scene_ = nil
---@type Node
local cameraNode_ = nil
local uiRoot_ = nil
local uiRootGetter_ = nil

local active_ = false

-- 地面节点引用（地形模式下隐藏）
local hiddenGroundNodes_ = {}

-- 地形网格数据: grid_[x][z] = "open" | "blocked" | "target"
-- 坐标范围: x = gridMinX_..gridMaxX_-1, z = gridMinZ_..gridMaxZ_-1
local grid_ = {}
local mapW_ = 0       -- 农场宽度 (用于居中计算)
local mapH_ = 0       -- 农场高度
local gridMinX_ = 0   -- 网格最小 X (含外围)
local gridMaxX_ = 0   -- 网格最大 X (不含)
local gridMinZ_ = 0   -- 网格最小 Z (含外围)
local gridMaxZ_ = 0   -- 网格最大 Z (不含)

-- 选中的格子集合: { {x=N, z=N}, ... }
local selectedCells_ = {}

-- 高度网格: heightGrid_[x][z] = number (米，默认 0)
local heightGrid_ = {}

-- 平滑网格: smoothGrid_[x][z] = number (0~1，每格独立平滑因子)
local smoothGrid_ = {}

-- 当前平滑滑块值（用于 UI 显示和应用到选中格子）
local currentSmoothValue_ = 0

-- 当前高度滑块值（用于 UI 显示和应用）
local currentSliderHeight_ = 0

-- 撤销历史栈: { { cells = { {x,z, oldType, oldHeight, oldSmooth}, ... }, rebuildFloor=bool, rebuildTerrain=bool }, ... }
local undoStack_ = {}
local MAX_UNDO = 50  -- 最大撤销步数

-- 剪贴板: { anchor={x,z}, cells={ {dx,dz, type, height, smooth}, ... } }
local clipboard_ = nil

-- 粘贴模式状态
local pasteMode_ = false
local pastePreviewX_ = nil  -- 当前鼠标对应的锚点格子坐标
local pastePreviewZ_ = nil

-- 拖动多选状态
local dragging_ = false
local dragStartX_ = nil  -- 拖动起始格子坐标
local dragStartZ_ = nil
local dragEndX_ = nil    -- 拖动当前结束格子坐标
local dragEndZ_ = nil
local dragCtrl_ = false  -- 拖动开始时是否按住 Ctrl（追加模式）
local preDragSelection_ = {}  -- Ctrl 追加模式下保存拖动前的选择

-- UI
local menuPanel_ = nil         -- 左侧编辑菜单

-- ============================================================================
-- 前向声明（避免全局污染）
-- ============================================================================
local HideGroundNodes
local RestoreGroundNodes
local InitGridFromConfig
local IsCellBlocked
local HandleClickInput
local FindSelectedIndex
local SetSelectedType
local RaycastGroundPlane
local GetCellColor
local DrawFilledCell
local DrawCellBorder
local ShowMenu
local CloseMenu
local UpdateMenuState
local ApplyHeightToSelected
local ApplySmoothToSelected
local RebuildHeightTerrain
local SyncTerrainToServer
local PushUndo
local PerformUndo
local CopySelected
local EnterPasteMode
local ExitPasteMode
local PerformPaste
local UpdateDragSelection

-- ============================================================================
-- 撤销系统
-- ============================================================================

--- 保存指定格子的当前状态到撤销栈
---@param cells table  { {x=N, z=N}, ... } 受影响的格子列表
---@param rebuildFloor boolean  撤销时是否需要重建目标地面
---@param rebuildTerrain boolean  撤销时是否需要重建高度地形
PushUndo = function(cells, rebuildFloor, rebuildTerrain)
    local snapshot = {
        cells = {},
        rebuildFloor = rebuildFloor or false,
        rebuildTerrain = rebuildTerrain or false,
    }
    for _, cell in ipairs(cells) do
        local x, z = cell.x, cell.z
        table.insert(snapshot.cells, {
            x = x,
            z = z,
            oldType   = (grid_[x] and grid_[x][z]) or CELL_OPEN,
            oldHeight = (heightGrid_[x] and heightGrid_[x][z]) or 0,
            oldSmooth = (smoothGrid_[x] and smoothGrid_[x][z]) or 0,
        })
    end
    table.insert(undoStack_, snapshot)
    -- 超出上限时移除最早的记录
    if #undoStack_ > MAX_UNDO then
        table.remove(undoStack_, 1)
    end
end

--- 执行撤销：弹出最近一条记录并恢复格子状态
PerformUndo = function()
    if #undoStack_ == 0 then
        print("[TerrainEditor] 撤销栈为空，无操作可撤销")
        return
    end

    local snapshot = table.remove(undoStack_)
    for _, cell in ipairs(snapshot.cells) do
        local x, z = cell.x, cell.z
        if grid_[x] then
            grid_[x][z] = cell.oldType
        end
        if heightGrid_[x] then
            heightGrid_[x][z] = cell.oldHeight
        end
        if smoothGrid_[x] then
            smoothGrid_[x][z] = cell.oldSmooth
        end
    end

    -- 同步数据
    Shared.terrainGrid = grid_
    Shared.heightGrid = heightGrid_
    Shared.smoothGrid = smoothGrid_

    -- 按需重建
    if snapshot.rebuildFloor and scene_ then
        Shared.RebuildTargetFloor(scene_)
    end
    if snapshot.rebuildTerrain and scene_ then
        Shared.RebuildHeightTerrain(scene_)
    end

    SyncTerrainToServer()

    print(string.format("[TerrainEditor] 撤销成功，恢复了 %d 个格子", #snapshot.cells))
end

-- ============================================================================
-- 复制 / 粘贴系统
-- ============================================================================

--- 复制当前选中格子的数据到剪贴板
CopySelected = function()
    if #selectedCells_ == 0 then
        print("[TerrainEditor] 无选中格子，无法复制")
        return
    end

    -- 以第一个选中格子为锚点，记录相对偏移
    local anchorX = selectedCells_[1].x
    local anchorZ = selectedCells_[1].z

    clipboard_ = { cells = {} }
    for _, cell in ipairs(selectedCells_) do
        local x, z = cell.x, cell.z
        table.insert(clipboard_.cells, {
            dx     = x - anchorX,
            dz     = z - anchorZ,
            type   = (grid_[x] and grid_[x][z]) or CELL_OPEN,
            height = (heightGrid_[x] and heightGrid_[x][z]) or 0,
            smooth = (smoothGrid_[x] and smoothGrid_[x][z]) or 0,
        })
    end

    print(string.format("[TerrainEditor] 已复制 %d 个格子到剪贴板", #clipboard_.cells))
end

--- 进入粘贴模式
EnterPasteMode = function()
    if not clipboard_ or #clipboard_.cells == 0 then
        print("[TerrainEditor] 剪贴板为空，无法粘贴")
        return
    end
    pasteMode_ = true
    pastePreviewX_ = nil
    pastePreviewZ_ = nil
    selectedCells_ = {}  -- 清空选择，避免混淆
    UpdateMenuState()
    print("[TerrainEditor] 进入粘贴模式，点击放置 / ESC或右键取消")
end

--- 退出粘贴模式
ExitPasteMode = function()
    pasteMode_ = false
    pastePreviewX_ = nil
    pastePreviewZ_ = nil
    print("[TerrainEditor] 退出粘贴模式")
end

--- 执行粘贴：将剪贴板数据应用到锚点位置
PerformPaste = function(anchorX, anchorZ)
    if not clipboard_ or #clipboard_.cells == 0 then return end

    -- 计算目标格子列表
    local targetCells = {}
    for _, cell in ipairs(clipboard_.cells) do
        local tx = anchorX + cell.dx
        local tz = anchorZ + cell.dz
        -- 边界检查
        if tx >= gridMinX_ and tx < gridMaxX_ and tz >= gridMinZ_ and tz < gridMaxZ_ then
            table.insert(targetCells, { x = tx, z = tz, src = cell })
        end
    end

    if #targetCells == 0 then
        print("[TerrainEditor] 粘贴位置全部超出地图范围")
        return
    end

    -- 撤销：保存修改前的状态（类型和高度都可能改变）
    PushUndo(targetCells, true, true)

    -- 应用数据
    for _, t in ipairs(targetCells) do
        local x, z, src = t.x, t.z, t.src
        if grid_[x] then
            grid_[x][z] = src.type
        end
        if heightGrid_[x] then
            heightGrid_[x][z] = src.height
        end
        if smoothGrid_[x] then
            smoothGrid_[x][z] = src.smooth
        end
    end

    -- 同步 & 重建
    Shared.terrainGrid = grid_
    Shared.heightGrid = heightGrid_
    Shared.smoothGrid = smoothGrid_
    if scene_ then
        Shared.RebuildTargetFloor(scene_)
        Shared.RebuildHeightTerrain(scene_)
    end
    SyncTerrainToServer()

    print(string.format("[TerrainEditor] 已粘贴 %d 个格子到锚点(%d,%d)", #targetCells, anchorX, anchorZ))
end

-- ============================================================================
-- 高度控制
-- ============================================================================

--- 将指定高度应用到所有选中格子，并重建地形网格
ApplyHeightToSelected = function(height)
    if #selectedCells_ == 0 then
        print("[TerrainEditor] 无选中格子，跳过高度设置")
        return
    end

    -- 撤销：保存修改前的状态
    PushUndo(selectedCells_, false, true)

    for _, cell in ipairs(selectedCells_) do
        if heightGrid_[cell.x] then
            heightGrid_[cell.x][cell.z] = height
        end
    end

    print(string.format("[TerrainEditor] 已将 %d 个格子高度设为 %.2fm", #selectedCells_, height))

    -- 同步高度数据到 Shared
    Shared.heightGrid = heightGrid_
    Shared.smoothGrid = smoothGrid_

    -- 重建高度地形网格
    if scene_ then
        Shared.RebuildHeightTerrain(scene_)
    end

    -- 网络同步
    SyncTerrainToServer()
end

--- 将当前平滑值应用到所有选中格子，并重建地形网格
ApplySmoothToSelected = function(smooth)
    if #selectedCells_ == 0 then
        print("[TerrainEditor] 无选中格子，跳过平滑设置")
        return
    end

    -- 撤销：保存修改前的状态
    PushUndo(selectedCells_, false, true)

    for _, cell in ipairs(selectedCells_) do
        if smoothGrid_[cell.x] then
            smoothGrid_[cell.x][cell.z] = smooth
        end
    end

    print(string.format("[TerrainEditor] 已将 %d 个格子平滑设为 %.2f", #selectedCells_, smooth))

    -- 同步数据到 Shared 并重建
    Shared.heightGrid = heightGrid_
    Shared.smoothGrid = smoothGrid_
    if scene_ then
        Shared.RebuildHeightTerrain(scene_)
    end
    SyncTerrainToServer()
end

--- 触发地形重建
RebuildHeightTerrain = function()
    Shared.heightGrid = heightGrid_
    Shared.smoothGrid = smoothGrid_
    if scene_ then
        Shared.RebuildHeightTerrain(scene_)
    end
end

-- ============================================================================
-- 地形网络同步
-- ============================================================================

--- 将地形网格序列化并发送到服务端（包含类型 + 高度 + 平滑因子）
SyncTerrainToServer = function()
    if not grid_ then return end

    local serverConn = network:GetServerConnection()
    if not serverConn then return end

    -- 序列化地形类型为 "x,z,type;x,z,type;..." 格式
    local parts = {}
    for x, row in pairs(grid_) do
        for z, cellType in pairs(row) do
            parts[#parts + 1] = string.format("%d,%d,%s", x, z, cellType)
        end
    end
    local gridData = table.concat(parts, ";")

    -- 序列化高度数据为 "x,z,h;x,z,h;..." 格式（只发送非零高度）
    local heightParts = {}
    if heightGrid_ then
        for x, row in pairs(heightGrid_) do
            for z, h in pairs(row) do
                if h ~= 0 then
                    heightParts[#heightParts + 1] = string.format("%d,%d,%.3f", x, z, h)
                end
            end
        end
    end
    local heightData = table.concat(heightParts, ";")

    -- 序列化平滑网格为 "x,z,s;x,z,s;..." 格式（只发送非默认值）
    local smoothParts = {}
    if smoothGrid_ then
        for x, row in pairs(smoothGrid_) do
            for z, s in pairs(row) do
                if s ~= 0 then  -- 默认值 0 不需要发送
                    smoothParts[#smoothParts + 1] = string.format("%d,%d,%.3f", x, z, s)
                end
            end
        end
    end
    local smoothData = table.concat(smoothParts, ";")

    local vm = VariantMap()
    vm["GridData"] = Variant(gridData)
    vm["HeightData"] = Variant(heightData)
    vm["SmoothData"] = Variant(smoothData)
    serverConn:SendRemoteEvent(EVENTS.MAP_EDIT_TERRAIN, true, vm)
    print(string.format("[TerrainEditor->Server] 发送地形同步, 格子数: %d, 高度格子: %d, 平滑格子: %d",
        #parts, #heightParts, #smoothParts))
end

-- ============================================================================
-- API
-- ============================================================================

--- 初始化
---@param camNode Node
---@param scene Scene
---@param rootOrGetter any  UI root 面板或 getter 函数
function TerrainEditor.Init(camNode, scene, rootOrGetter)
    cameraNode_ = camNode
    scene_ = scene
    if type(rootOrGetter) == "function" then
        uiRootGetter_ = rootOrGetter
        uiRoot_ = rootOrGetter()
    else
        uiRoot_ = rootOrGetter
        uiRootGetter_ = nil
    end

    mapW_ = Config.Level1.MapWidth   -- 18
    mapH_ = Config.Level1.MapHeight  -- 12

    -- 计算覆盖整张地图的网格范围（与 MapPreviewCamera.DrawGrid 一致）
    local extW = Config.Exterior.GroundWidth   -- 50
    local extH = Config.Exterior.GroundHeight  -- 40
    gridMinX_ = math.floor(mapW_ / 2 - extW / 2)   -- -16
    gridMaxX_ = math.ceil(mapW_ / 2 + extW / 2)     --  34
    gridMinZ_ = math.floor(mapH_ / 2 - extH / 2)    -- -14
    gridMaxZ_ = math.ceil(mapH_ / 2 + extH / 2)     --  26

    -- 初始化网格数据（自动检测）
    InitGridFromConfig()

    local totalW = gridMaxX_ - gridMinX_
    local totalH = gridMaxZ_ - gridMinZ_
    print(string.format("[TerrainEditor] 初始化完成 (网格范围: X[%d..%d] Z[%d..%d], %dx%d)",
        gridMinX_, gridMaxX_ - 1, gridMinZ_, gridMaxZ_ - 1, totalW, totalH))
end

--- 获取当前有效的 UI root（优先使用 getter 动态获取）
local function GetUIRoot()
    if uiRootGetter_ then
        uiRoot_ = uiRootGetter_()
    end
    return uiRoot_
end

--- 开启地形模式
function TerrainEditor.Enable()
    active_ = true
    selectedCells_ = {}

    -- 防御性清理：强制移除 MapEditor 可能残留的菜单
    local root = GetUIRoot()
    if root then
        for _, menuId in ipairs({"editorMenu", "rotatePanel", "scalePanel", "editorStatusHint"}) do
            local panel = root:FindById(menuId)
            if panel then
                panel:Remove()
                print("[TerrainEditor] 强制移除残留的编辑菜单: " .. menuId)
            end
        end
    end

    HideGroundNodes()
    ShowMenu()
    print("[TerrainEditor] 地形规划模式已开启")
end

--- 关闭地形模式
function TerrainEditor.Disable()
    active_ = false
    selectedCells_ = {}
    RestoreGroundNodes()
    CloseMenu()
    print("[TerrainEditor] 地形规划模式已关闭")
end

--- 是否处于地形模式
---@return boolean
function TerrainEditor.IsActive()
    return active_
end

--- 每帧更新
---@param dt number
function TerrainEditor.Update(dt)
    if not active_ then return end

    -- Ctrl 组合键
    if input:GetKeyDown(KEY_CTRL) then
        -- Ctrl+Z 撤销
        if input:GetKeyPress(KEY_Z) then
            if pasteMode_ then ExitPasteMode() end
            PerformUndo()
            return
        end
        -- Ctrl+C 复制
        if input:GetKeyPress(KEY_C) then
            CopySelected()
            return
        end
        -- Ctrl+V 粘贴
        if input:GetKeyPress(KEY_V) then
            EnterPasteMode()
            return
        end
    end

    -- 粘贴模式：跟踪鼠标 + 点击放置 + ESC/右键取消
    if pasteMode_ then
        -- 更新预览位置
        local hitPos = RaycastGroundPlane()
        if hitPos then
            pastePreviewX_ = math.floor(hitPos.x)
            pastePreviewZ_ = math.floor(hitPos.z)
        end

        -- ESC 或右键取消粘贴模式
        if input:GetKeyPress(KEY_ESCAPE) or input:GetMouseButtonPress(MOUSEB_RIGHT) then
            ExitPasteMode()
            return
        end

        -- 左键点击放置（不在 UI 上时）
        if input:GetMouseButtonPress(MOUSEB_LEFT) and not UI.IsPointerOverUI() then
            if pastePreviewX_ and pastePreviewZ_ then
                PerformPaste(pastePreviewX_, pastePreviewZ_)
                -- 粘贴后不退出粘贴模式，允许连续粘贴
            end
            return
        end

        return  -- 粘贴模式下不处理普通点击选择
    end

    HandleClickInput()
end

--- 在 PostRenderUpdate 中绘制地形覆盖
function TerrainEditor.DrawOverlay()
    if not active_ or not scene_ then return end

    local debugRenderer = scene_:GetComponent("DebugRenderer")
    if not debugRenderer then return end

    -- 仅绘制障碍和目标区的填充色（空地不绘制填充，避免半透明蓝色笼罩整个场景）
    -- 网格线已由 MapPreviewCamera.DrawGrid 绘制，空地通过网格线即可辨识
    -- 有高度的格子（包括空地）也绘制蓝色填充以标示高度变化
    for x = gridMinX_, gridMaxX_ - 1 do
        if grid_[x] then
            for z = gridMinZ_, gridMaxZ_ - 1 do
                local cellType = grid_[x][z]
                local cellH = (heightGrid_[x] and heightGrid_[x][z]) or 0
                if cellType and cellType ~= CELL_OPEN then
                    local color = GetCellColor(cellType)
                    DrawFilledCell(debugRenderer, x, z, OVERLAY_Y + cellH, color)
                elseif cellH ~= 0 then
                    -- 空地但有高度 → 浅蓝标示
                    DrawFilledCell(debugRenderer, x, z, OVERLAY_Y + cellH, COLOR_OPEN)
                end
            end
        end
    end

    -- 绘制选中高亮边框
    for _, cell in ipairs(selectedCells_) do
        local cellH = (heightGrid_[cell.x] and heightGrid_[cell.x][cell.z]) or 0
        DrawCellBorder(debugRenderer, cell.x, cell.z, SELECT_Y + cellH, COLOR_SELECTED)
    end

    -- 拖动选择中：绘制拖动矩形边框
    if dragging_ and dragStartX_ and dragEndX_ then
        local minX = math.min(dragStartX_, dragEndX_)
        local maxX = math.max(dragStartX_, dragEndX_) + 1
        local minZ = math.min(dragStartZ_, dragEndZ_)
        local maxZ = math.max(dragStartZ_, dragEndZ_) + 1
        local dy = SELECT_Y + 0.02
        local dragColor = Color(0.2, 1.0, 1.0, 0.8)  -- 青色边框
        debugRenderer:AddLine(Vector3(minX, dy, minZ), Vector3(maxX, dy, minZ), dragColor, true)
        debugRenderer:AddLine(Vector3(maxX, dy, minZ), Vector3(maxX, dy, maxZ), dragColor, true)
        debugRenderer:AddLine(Vector3(maxX, dy, maxZ), Vector3(minX, dy, maxZ), dragColor, true)
        debugRenderer:AddLine(Vector3(minX, dy, maxZ), Vector3(minX, dy, minZ), dragColor, true)
    end

    -- 粘贴模式：绘制预览幽灵格子
    if pasteMode_ and clipboard_ and pastePreviewX_ and pastePreviewZ_ then
        local ghostFill   = Color(0.2, 1.0, 0.5, 0.25)  -- 半透明绿色填充
        local ghostBorder = Color(0.2, 1.0, 0.5, 0.7)    -- 绿色边框
        for _, cell in ipairs(clipboard_.cells) do
            local tx = pastePreviewX_ + cell.dx
            local tz = pastePreviewZ_ + cell.dz
            if tx >= gridMinX_ and tx < gridMaxX_ and tz >= gridMinZ_ and tz < gridMaxZ_ then
                local previewY = SELECT_Y + cell.height
                DrawFilledCell(debugRenderer, tx, tz, previewY, ghostFill)
                DrawCellBorder(debugRenderer, tx, tz, previewY + 0.01, ghostBorder)
            end
        end
    end
end

--- 获取地形数据（用于导出）
---@return string 格式化的地形数据文本
function TerrainEditor.ExportToLog()
    local totalW = gridMaxX_ - gridMinX_
    local totalH = gridMaxZ_ - gridMinZ_

    local output = "-- ============================================================\n"
    output = output .. "-- 地形规划导出 — " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n"
    output = output .. string.format("-- 网格范围: X[%d..%d] Z[%d..%d] (%dx%d, 1格=1m)\n",
        gridMinX_, gridMaxX_ - 1, gridMinZ_, gridMaxZ_ - 1, totalW, totalH)
    output = output .. string.format("-- 农场区域: X[0..%d] Z[0..%d]\n", mapW_ - 1, mapH_ - 1)
    output = output .. "-- 类型: open=空地, blocked=障碍, target=目标区\n"
    output = output .. "-- ============================================================\n\n"

    -- 统计
    local countOpen, countBlocked, countTarget = 0, 0, 0
    for x = gridMinX_, gridMaxX_ - 1 do
        if grid_[x] then
            for z = gridMinZ_, gridMaxZ_ - 1 do
                local t = grid_[x][z]
                if t == CELL_OPEN then countOpen = countOpen + 1
                elseif t == CELL_BLOCKED then countBlocked = countBlocked + 1
                elseif t == CELL_TARGET then countTarget = countTarget + 1
                end
            end
        end
    end
    output = output .. string.format("-- 统计: 空地=%d, 障碍=%d, 目标=%d, 总计=%d\n\n",
        countOpen, countBlocked, countTarget, countOpen + countBlocked + countTarget)

    -- 输出障碍格子列表
    output = output .. "TerrainData = {\n"
    output = output .. "    blocked = {\n"
    for x = gridMinX_, gridMaxX_ - 1 do
        if grid_[x] then
            for z = gridMinZ_, gridMaxZ_ - 1 do
                if grid_[x][z] == CELL_BLOCKED then
                    output = output .. string.format("        { x = %d, z = %d },\n", x, z)
                end
            end
        end
    end
    output = output .. "    },\n"

    -- 输出目标区格子列表
    output = output .. "    target = {\n"
    for x = gridMinX_, gridMaxX_ - 1 do
        if grid_[x] then
            for z = gridMinZ_, gridMaxZ_ - 1 do
                if grid_[x][z] == CELL_TARGET then
                    output = output .. string.format("        { x = %d, z = %d },\n", x, z)
                end
            end
        end
    end
    output = output .. "    },\n"
    output = output .. "}\n"

    -- 输出视觉地图（仅农场区域，Z 从高到低，方便阅读）
    output = output .. "\n-- 视觉地图 — 农场区域 (. = 空地, # = 障碍, T = 目标)\n"
    output = output .. "-- Z↑\n"
    for z = mapH_ - 1, 0, -1 do
        local row = string.format("-- %2d |", z)
        for x = 0, mapW_ - 1 do
            local t = grid_[x] and grid_[x][z] or CELL_OPEN
            if t == CELL_BLOCKED then
                row = row .. "#"
            elseif t == CELL_TARGET then
                row = row .. "T"
            else
                row = row .. "."
            end
        end
        row = row .. "|"
        output = output .. row .. "\n"
    end
    output = output .. "--    +"
    for x = 0, mapW_ - 1 do output = output .. "-" end
    output = output .. "+  → X\n"

    print("=== TERRAIN EDITOR EXPORT START ===")
    print(output)
    print("=== TERRAIN EDITOR EXPORT END ===")

    return output
end

--- 获取当前地形网格原始数据（用于云存档序列化）
--- 仅返回非 open 的格子以节省空间（地形类型）
--- 额外返回有非零高度的格子和非默认平滑值的格子
---@return table  { {x=N, z=N, t="blocked"|"target"}, ... }
---@return table  { {x=N, z=N, h=number}, ... }
---@return table  { {x=N, z=N, s=number}, ... }
function TerrainEditor.GetGridData()
    local data = {}
    local heightData = {}
    local smoothData = {}
    for x = gridMinX_, gridMaxX_ - 1 do
        if grid_[x] then
            for z = gridMinZ_, gridMaxZ_ - 1 do
                local t = grid_[x][z]
                if t and t ~= CELL_OPEN then
                    data[#data + 1] = { x = x, z = z, t = t }
                end
                -- 高度数据：仅保存非零高度
                local h = (heightGrid_[x] and heightGrid_[x][z]) or 0
                if h ~= 0 then
                    heightData[#heightData + 1] = { x = x, z = z, h = h }
                end
                -- 平滑数据：仅保存非默认值
                local s = (smoothGrid_[x] and smoothGrid_[x][z]) or 0
                if s ~= 0 then
                    smoothData[#smoothData + 1] = { x = x, z = z, s = s }
                end
            end
        end
    end
    return data, heightData, smoothData
end

--- 用外部数据替换整个地形网格（云存档加载时调用）
--- @param gridData table  { {x=N, z=N, t="blocked"|"target"}, ... }
--- @param heightData table|nil  { {x=N, z=N, h=number}, ... }
--- @param smoothData table|nil  { {x=N, z=N, s=number}, ... } 每格独立平滑值
function TerrainEditor.ReplaceGrid(gridData, heightData, smoothData)
    undoStack_ = {}  -- 重置撤销栈
    -- 先重置为全部 open
    for x = gridMinX_, gridMaxX_ - 1 do
        if not grid_[x] then grid_[x] = {} end
        if not heightGrid_[x] then heightGrid_[x] = {} end
        if not smoothGrid_[x] then smoothGrid_[x] = {} end
        for z = gridMinZ_, gridMaxZ_ - 1 do
            grid_[x][z] = CELL_OPEN
            heightGrid_[x][z] = 0
            smoothGrid_[x][z] = 0  -- 默认平滑值
        end
    end

    -- 应用地形类型数据
    local count = 0
    for _, cell in ipairs(gridData) do
        local x, z, t = cell.x, cell.z, cell.t
        if grid_[x] then
            grid_[x][z] = t
            count = count + 1
        end
    end

    -- 应用高度数据
    local hCount = 0
    if heightData then
        for _, cell in ipairs(heightData) do
            local x, z, h = cell.x, cell.z, cell.h
            if heightGrid_[x] then
                heightGrid_[x][z] = h
                hCount = hCount + 1
            end
        end
    end

    -- 恢复平滑网格数据
    local sCount = 0
    if smoothData then
        for _, cell in ipairs(smoothData) do
            local x, z, s = cell.x, cell.z, cell.s
            if smoothGrid_[x] then
                smoothGrid_[x][z] = s
                sCount = sCount + 1
            end
        end
    end

    -- 同步
    Shared.terrainGrid = grid_
    Shared.heightGrid = heightGrid_
    Shared.smoothGrid = smoothGrid_
    SyncTerrainToServer()

    if scene_ then
        Shared.RebuildTargetFloor(scene_)
        Shared.RebuildHeightTerrain(scene_)
    end

    print(string.format("[TerrainEditor] ReplaceGrid: 应用 %d 个非空格子, %d 个高度格子, %d 个平滑格子",
        count, hCount, sCount))
end

-- ============================================================================
-- 地面节点隐藏/恢复（地形模式下隐藏地面贴图以显示地形颜色）
-- ============================================================================

local GROUND_NODE_NAMES = { "Floor", "TargetFloor", "ExteriorFloor", "Road1", "Road2" }

--- 隐藏所有地面节点
HideGroundNodes = function()
    hiddenGroundNodes_ = {}
    if not scene_ then return end
    for _, name in ipairs(GROUND_NODE_NAMES) do
        local node = scene_:GetChild(name, true)
        if node and node.enabled then
            node.enabled = false
            table.insert(hiddenGroundNodes_, node)
            print("[TerrainEditor] 隐藏地面: " .. name)
        end
    end
end

--- 恢复所有隐藏的地面节点
RestoreGroundNodes = function()
    for _, node in ipairs(hiddenGroundNodes_) do
        if node then
            node.enabled = true
        end
    end
    hiddenGroundNodes_ = {}
    print("[TerrainEditor] 地面节点已恢复显示")
end

-- ============================================================================
-- 网格初始化：自动检测地形类型
-- ============================================================================

InitGridFromConfig = function()
    grid_ = {}
    undoStack_ = {}  -- 重置撤销栈

    -- 先全部初始化为空地（覆盖整张地图范围）
    for x = gridMinX_, gridMaxX_ - 1 do
        grid_[x] = {}
        for z = gridMinZ_, gridMaxZ_ - 1 do
            grid_[x][z] = CELL_OPEN
        end
    end

    -- 标记目标区格子
    local ta = Config.Level1.TargetArea
    local taMinX = ta.Center.x - ta.Size.x / 2
    local taMaxX = ta.Center.x + ta.Size.x / 2
    local taMinZ = ta.Center.z - ta.Size.z / 2
    local taMaxZ = ta.Center.z + ta.Size.z / 2

    for x = gridMinX_, gridMaxX_ - 1 do
        for z = gridMinZ_, gridMaxZ_ - 1 do
            -- 格子中心点
            local cx = x + 0.5
            local cz = z + 0.5
            if cx >= taMinX and cx <= taMaxX and cz >= taMinZ and cz <= taMaxZ then
                grid_[x][z] = CELL_TARGET
            end
        end
    end

    -- 边界围墙已有物理碰撞体（RigidBody+CollisionShape），无需标记 blocked
    -- 所有非目标区格子均为 open（空地），由用户手动编辑决定是否 blocked

    -- 初始化高度网格（所有格子默认 0 高度）
    heightGrid_ = {}
    smoothGrid_ = {}
    for x = gridMinX_, gridMaxX_ - 1 do
        heightGrid_[x] = {}
        smoothGrid_[x] = {}
        for z = gridMinZ_, gridMaxZ_ - 1 do
            heightGrid_[x][z] = 0
            smoothGrid_[x][z] = 0  -- 默认平滑值
        end
    end

    print("[TerrainEditor] 地形初始化完成（围墙+目标区+高度+平滑网格）")

    -- 同步地形网格到服务端（本地 + 网络）
    Shared.terrainGrid = grid_
    SyncTerrainToServer()

    -- 刷新目标区地面贴图
    if scene_ then
        Shared.RebuildTargetFloor(scene_)
    end
end

--- 判断格子中心是否被碰撞体覆盖
---@param cx number 格子中心 X
---@param cz number 格子中心 Z
---@param colliders table 碰撞体列表
---@return boolean
IsCellBlocked = function(cx, cz, colliders)
    -- 用一个较小半径做检测（格子中心点是否在碰撞体内或非常接近）
    local testRadius = 0.3
    for _, c in ipairs(colliders) do
        if c.isBox then
            -- 点在 AABB 内或紧邻
            local dx = math.abs(cx - c.x)
            local dz = math.abs(cz - c.z)
            if dx <= c.halfW + testRadius and dz <= c.halfH + testRadius then
                return true
            end
        else
            -- 点在圆内
            local dx = cx - c.x
            local dz = cz - c.z
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist <= c.radius + testRadius then
                return true
            end
        end
    end
    return false
end

-- ============================================================================
-- 点击输入
-- ============================================================================

HandleClickInput = function()
    if not active_ then return end

    -- 如果鼠标在 UI 控件上（如转换按钮），跳过地面点击处理
    -- 修复：点击"→ 障碍"等按钮时，左键同时触发地面选择导致 selectedCells_ 被重置
    if UI.IsPointerOverUI() then
        -- UI 上按下时终止拖动
        if dragging_ then
            dragging_ = false
        end
        return
    end

    -- 左键按下：开始拖动选择
    if input:GetMouseButtonPress(MOUSEB_LEFT) then
        local hitPos = RaycastGroundPlane()
        if hitPos then
            local cellX = math.floor(hitPos.x)
            local cellZ = math.floor(hitPos.z)
            if cellX >= gridMinX_ and cellX < gridMaxX_ and cellZ >= gridMinZ_ and cellZ < gridMaxZ_ then
                dragging_ = true
                dragStartX_ = cellX
                dragStartZ_ = cellZ
                dragEndX_ = cellX
                dragEndZ_ = cellZ
                dragCtrl_ = input:GetKeyDown(KEY_CTRL)

                -- Ctrl 模式保存当前已有选择
                if dragCtrl_ then
                    preDragSelection_ = {}
                    for _, cell in ipairs(selectedCells_) do
                        table.insert(preDragSelection_, { x = cell.x, z = cell.z })
                    end
                else
                    preDragSelection_ = {}
                end

                -- 立即更新选区预览
                UpdateDragSelection()
                UpdateMenuState()
            end
        end
    end

    -- 左键按住：更新拖动终点
    if dragging_ and input:GetMouseButtonDown(MOUSEB_LEFT) then
        local hitPos = RaycastGroundPlane()
        if hitPos then
            local cellX = math.floor(hitPos.x)
            local cellZ = math.floor(hitPos.z)
            cellX = math.max(gridMinX_, math.min(gridMaxX_ - 1, cellX))
            cellZ = math.max(gridMinZ_, math.min(gridMaxZ_ - 1, cellZ))
            if cellX ~= dragEndX_ or cellZ ~= dragEndZ_ then
                dragEndX_ = cellX
                dragEndZ_ = cellZ
                UpdateDragSelection()
                UpdateMenuState()
            end
        end
    end

    -- 左键释放：确认拖动选择
    if dragging_ and not input:GetMouseButtonDown(MOUSEB_LEFT) then
        -- 如果只拖了1格且无 Ctrl → 切换选择逻辑（点击）
        if dragStartX_ == dragEndX_ and dragStartZ_ == dragEndZ_ and not dragCtrl_ then
            local idx = FindSelectedIndex(dragStartX_, dragStartZ_)
            if idx and #selectedCells_ == 1 then
                -- 再次点击唯一已选中格子 → 取消
                selectedCells_ = {}
            end
            -- 否则保持单选（已在 UpdateDragSelection 中设置）
        end
        dragging_ = false
        dragStartX_ = nil
        dragStartZ_ = nil
        dragEndX_ = nil
        dragEndZ_ = nil
        preDragSelection_ = {}
        UpdateMenuState()
    end
end

--- 根据拖动区域更新选中格子
UpdateDragSelection = function()
    if not dragStartX_ or not dragEndX_ then return end

    local minX = math.min(dragStartX_, dragEndX_)
    local maxX = math.max(dragStartX_, dragEndX_)
    local minZ = math.min(dragStartZ_, dragEndZ_)
    local maxZ = math.max(dragStartZ_, dragEndZ_)

    if dragCtrl_ then
        -- Ctrl 模式：保留之前的选择 + 添加拖动区域
        -- 用 set 去重
        local set = {}
        for _, cell in ipairs(preDragSelection_) do
            local key = cell.x .. "," .. cell.z
            set[key] = true
        end
        -- 添加拖动区域的格子
        for x = minX, maxX do
            for z = minZ, maxZ do
                local key = x .. "," .. z
                set[key] = true
            end
        end
        -- 重建 selectedCells_
        selectedCells_ = {}
        for key, _ in pairs(set) do
            local cx, cz = key:match("^(-?%d+),(-?%d+)$")
            table.insert(selectedCells_, { x = tonumber(cx), z = tonumber(cz) })
        end
    else
        -- 普通模式：选中拖动矩形区域
        selectedCells_ = {}
        for x = minX, maxX do
            for z = minZ, maxZ do
                table.insert(selectedCells_, { x = x, z = z })
            end
        end
    end
end

--- 在选中列表中查找格子索引
---@return number|nil
FindSelectedIndex = function(x, z)
    for i, cell in ipairs(selectedCells_) do
        if cell.x == x and cell.z == z then
            return i
        end
    end
    return nil
end

-- ============================================================================
-- 地形转换
-- ============================================================================

--- 将选中格子设为指定类型
---@param newType string  "open" | "blocked" | "target"
SetSelectedType = function(newType)
    if #selectedCells_ == 0 then
        print("[TerrainEditor] 无选中格子，跳过转换")
        return
    end

    -- 撤销：保存修改前的状态（类型改变需要重建目标地面）
    PushUndo(selectedCells_, true, false)

    local typeNames = { open = "空地", blocked = "障碍", target = "目标" }
    local count = 0
    for _, cell in ipairs(selectedCells_) do
        if grid_[cell.x] and grid_[cell.x][cell.z] then
            local oldType = grid_[cell.x][cell.z]
            grid_[cell.x][cell.z] = newType
            count = count + 1
            print(string.format("[TerrainEditor] 格子(%d,%d): %s → %s",
                cell.x, cell.z, typeNames[oldType] or oldType, typeNames[newType] or newType))
        else
            print(string.format("[TerrainEditor] 格子(%d,%d): 数据不存在，跳过", cell.x, cell.z))
        end
    end

    print(string.format("[TerrainEditor] 已将 %d 个格子转换为 %s", count, typeNames[newType] or newType))

    -- 同步地形网格到服务端（本地 + 网络）
    Shared.terrainGrid = grid_
    SyncTerrainToServer()

    -- 刷新目标区地面贴图
    if scene_ then
        Shared.RebuildTargetFloor(scene_)
    end

    -- 转换完成后清空选择（不要清空，让用户能看到转换结果）
    selectedCells_ = {}
    UpdateMenuState()
end

-- ============================================================================
-- 鼠标射线
-- ============================================================================

---@return Vector3|nil
RaycastGroundPlane = function()
    if not cameraNode_ then return nil end
    local camera = cameraNode_:GetComponent("Camera")
    if not camera then return nil end

    local mousePos = input.mousePosition
    local screenW = graphics:GetWidth()
    local screenH = graphics:GetHeight()
    if screenW <= 0 or screenH <= 0 then return nil end

    local nx = mousePos.x / screenW
    local ny = mousePos.y / screenH
    local ray = camera:GetScreenRay(nx, ny)

    if math.abs(ray.direction.y) < 0.0001 then return nil end
    local t = -ray.origin.y / ray.direction.y
    if t < 0 then return nil end

    return Vector3(
        ray.origin.x + t * ray.direction.x,
        0,
        ray.origin.z + t * ray.direction.z
    )
end

-- ============================================================================
-- 绘制辅助
-- ============================================================================

--- 获取格子类型对应的颜色
---@param cellType string
---@return Color
GetCellColor = function(cellType)
    if cellType == CELL_BLOCKED then return COLOR_BLOCKED
    elseif cellType == CELL_TARGET then return COLOR_TARGET
    else return COLOR_OPEN
    end
end

--- 用两个三角形绘制实心填充格子
---@param debugRenderer DebugRenderer
---@param x number 格子X坐标 (整数)
---@param z number 格子Z坐标 (整数)
---@param y number 绘制高度
---@param color Color
DrawFilledCell = function(debugRenderer, x, z, y, color)
    -- 格子四个角（稍微内缩 0.02 避免与网格线完全重叠）
    local m = 0.02
    local v1 = Vector3(x + m,     y, z + m)      -- 左下
    local v2 = Vector3(x + 1 - m, y, z + m)      -- 右下
    local v3 = Vector3(x + 1 - m, y, z + 1 - m)  -- 右上
    local v4 = Vector3(x + m,     y, z + 1 - m)  -- 左上

    -- 两个三角形组成一个填充矩形（depthTest=true: 受深度测试，被3D模型正确遮挡）
    -- 顶点绕序：v1→v3→v2 / v1→v4→v3，使法线朝上 (0,1,0)，避免角度变化导致颜色忽明忽暗
    debugRenderer:AddTriangle(v1, v3, v2, color, true)
    debugRenderer:AddTriangle(v1, v4, v3, color, true)
end

--- 绘制格子边框
---@param debugRenderer DebugRenderer
---@param x number
---@param z number
---@param y number
---@param color Color
DrawCellBorder = function(debugRenderer, x, z, y, color)
    debugRenderer:AddLine(Vector3(x, y, z), Vector3(x + 1, y, z), color, true)
    debugRenderer:AddLine(Vector3(x + 1, y, z), Vector3(x + 1, y, z + 1), color, true)
    debugRenderer:AddLine(Vector3(x + 1, y, z + 1), Vector3(x, y, z + 1), color, true)
    debugRenderer:AddLine(Vector3(x, y, z + 1), Vector3(x, y, z), color, true)
end

-- ============================================================================
-- UI：左侧操作菜单
-- ============================================================================

ShowMenu = function()
    CloseMenu()
    local root = GetUIRoot()
    if not root then return end

    local T = AstroonTheme.Tokens

    menuPanel_ = UI.Panel {
        id = "terrainMenu",
        position = "absolute",
        top = 120,
        left = 10,
        width = 150,
        padding = 8,
        gap = 6,
        backgroundColor = { 0, 0, 0, 255 },
        borderRadius = 0,
        children = {
            UI.Panel {
                padding = 8,
                gap = 6,
                backgroundColor = { T.surface[1], T.surface[2], T.surface[3], 240 },
                borderRadius = 0,
                alignItems = "stretch",
                children = {
                    UI.Label {
                        id = "terrainMenuTitle",
                        text = "地形规划",
                        fontSize = 14,
                        fontWeight = "bold",
                        fontColor = T.text,
                        textAlign = "center",
                    },
                    UI.Label {
                        id = "terrainSelCount",
                        text = "未选中",
                        fontSize = 12,
                        fontColor = T.textMuted,
                        textAlign = "center",
                    },
                    -- 分隔线
                    UI.Panel {
                        width = "100%",
                        height = 1,
                        backgroundColor = T.border,
                    },
                    UI.Button {
                        id = "btnToOpen",
                        text = "→ 空地",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 0,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 40, 90, 170, 255 },
                        hoverBackgroundColor = { 55, 110, 200, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        visible = false,
                        onClick = function() SetSelectedType(CELL_OPEN) end,
                    },
                    UI.Button {
                        id = "btnToBlocked",
                        text = "→ 障碍",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 0,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 170, 50, 50, 255 },
                        hoverBackgroundColor = { 200, 65, 65, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        visible = false,
                        onClick = function() SetSelectedType(CELL_BLOCKED) end,
                    },
                    UI.Button {
                        id = "btnToTarget",
                        text = "→ 目标",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 0,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 120, 50, 170, 255 },
                        hoverBackgroundColor = { 145, 65, 200, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        visible = false,
                        onClick = function() SetSelectedType(CELL_TARGET) end,
                    },
                    UI.Button {
                        id = "btnClearSel",
                        text = "取消选择",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 0,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 80, 80, 80, 255 },
                        hoverBackgroundColor = { 110, 110, 110, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        visible = false,
                        onClick = function()
                            selectedCells_ = {}
                            UpdateMenuState()
                        end,
                    },
                    -- 图例
                    UI.Panel {
                        width = "100%",
                        height = 1,
                        backgroundColor = T.border,
                        marginTop = 4,
                    },
                    UI.Label {
                        text = "图例:",
                        fontSize = 11,
                        fontColor = T.textMuted,
                        marginTop = 2,
                    },
                    UI.Panel {
                        flexDirection = "row", alignItems = "center", gap = 4,
                        children = {
                            UI.Panel { width = 12, height = 12, backgroundColor = { 77, 128, 255, 46 }, borderRadius = 0 },
                            UI.Label { text = "空地", fontSize = 11, fontColor = T.textSecondary },
                        },
                    },
                    UI.Panel {
                        flexDirection = "row", alignItems = "center", gap = 4,
                        children = {
                            UI.Panel { width = 12, height = 12, backgroundColor = { 255, 77, 77, 56 }, borderRadius = 0 },
                            UI.Label { text = "障碍", fontSize = 11, fontColor = T.textSecondary },
                        },
                    },
                    UI.Panel {
                        flexDirection = "row", alignItems = "center", gap = 4,
                        children = {
                            UI.Panel { width = 12, height = 12, backgroundColor = { 179, 77, 255, 64 }, borderRadius = 0 },
                            UI.Label { text = "目标区", fontSize = 11, fontColor = T.textSecondary },
                        },
                    },
                    UI.Label {
                        text = "左键拖动框选\nCtrl+拖动追加",
                        fontSize = 10,
                        fontColor = T.textMuted,
                        textAlign = "center",
                        marginTop = 4,
                    },
                    -- ====== 高度控制区域 ======
                    UI.Panel {
                        width = "100%",
                        height = 1,
                        backgroundColor = T.border,
                        marginTop = 6,
                    },
                    UI.Label {
                        text = "高度控制",
                        fontSize = 13,
                        fontWeight = "bold",
                        fontColor = T.text,
                        textAlign = "center",
                        marginTop = 4,
                    },
                    UI.Label {
                        id = "heightValue",
                        text = "0.00 m",
                        fontSize = 12,
                        fontColor = T.textSecondary,
                        textAlign = "center",
                    },
                    UI.Slider {
                        id = "heightSlider",
                        value = 50, -- 映射: 0=-5m, 50=0m, 100=10m
                        min = 0,
                        max = 100,
                        step = 1,
                        height = 20,
                        onChange = function(self, v)
                            -- 映射 0~100 → -5~10
                            local h = -5 + v * 0.15
                            currentSliderHeight_ = math.floor(h * 100 + 0.5) / 100
                            local label = menuPanel_ and menuPanel_:FindById("heightValue")
                            if label then
                                label.text = string.format("%.2f m", currentSliderHeight_)
                            end
                            -- 实时应用高度到选中格子
                            if #selectedCells_ > 0 then
                                ApplyHeightToSelected(currentSliderHeight_)
                            end
                        end,
                    },
                    -- 预设高度按钮行1
                    UI.Panel {
                        flexDirection = "row",
                        gap = 3,
                        justifyContent = "center",
                        children = {
                            UI.Button {
                                text = "-0.5",
                                fontSize = 10,
                                paddingTop = 3, paddingBottom = 3,
                                paddingLeft = 4, paddingRight = 4,
                                borderRadius = 0,
                                backgroundColor = { 60, 60, 100, 255 },
                                hoverBackgroundColor = { 80, 80, 130, 255 },
                                fontColor = { 255, 255, 255, 255 },
                                onClick = function()
                                    currentSliderHeight_ = -0.5
                                    ApplyHeightToSelected(-0.5)
                                    UpdateMenuState()
                                end,
                            },
                            UI.Button {
                                text = "0.25",
                                fontSize = 10,
                                paddingTop = 3, paddingBottom = 3,
                                paddingLeft = 4, paddingRight = 4,
                                borderRadius = 0,
                                backgroundColor = { 60, 100, 60, 255 },
                                hoverBackgroundColor = { 80, 130, 80, 255 },
                                fontColor = { 255, 255, 255, 255 },
                                onClick = function()
                                    currentSliderHeight_ = 0.25
                                    ApplyHeightToSelected(0.25)
                                    UpdateMenuState()
                                end,
                            },
                            UI.Button {
                                text = "0.5",
                                fontSize = 10,
                                paddingTop = 3, paddingBottom = 3,
                                paddingLeft = 4, paddingRight = 4,
                                borderRadius = 0,
                                backgroundColor = { 60, 100, 60, 255 },
                                hoverBackgroundColor = { 80, 130, 80, 255 },
                                fontColor = { 255, 255, 255, 255 },
                                onClick = function()
                                    currentSliderHeight_ = 0.5
                                    ApplyHeightToSelected(0.5)
                                    UpdateMenuState()
                                end,
                            },
                        },
                    },
                    -- 预设高度按钮行2
                    UI.Panel {
                        flexDirection = "row",
                        gap = 3,
                        justifyContent = "center",
                        children = {
                            UI.Button {
                                text = "1m",
                                fontSize = 10,
                                paddingTop = 3, paddingBottom = 3,
                                paddingLeft = 6, paddingRight = 6,
                                borderRadius = 0,
                                backgroundColor = { 60, 100, 60, 255 },
                                hoverBackgroundColor = { 80, 130, 80, 255 },
                                fontColor = { 255, 255, 255, 255 },
                                onClick = function()
                                    currentSliderHeight_ = 1.0
                                    ApplyHeightToSelected(1.0)
                                    UpdateMenuState()
                                end,
                            },
                            UI.Button {
                                text = "2m",
                                fontSize = 10,
                                paddingTop = 3, paddingBottom = 3,
                                paddingLeft = 6, paddingRight = 6,
                                borderRadius = 0,
                                backgroundColor = { 60, 100, 60, 255 },
                                hoverBackgroundColor = { 80, 130, 80, 255 },
                                fontColor = { 255, 255, 255, 255 },
                                onClick = function()
                                    currentSliderHeight_ = 2.0
                                    ApplyHeightToSelected(2.0)
                                    UpdateMenuState()
                                end,
                            },
                            UI.Button {
                                text = "0m",
                                fontSize = 10,
                                paddingTop = 3, paddingBottom = 3,
                                paddingLeft = 6, paddingRight = 6,
                                borderRadius = 0,
                                backgroundColor = { 80, 80, 80, 255 },
                                hoverBackgroundColor = { 110, 110, 110, 255 },
                                fontColor = { 255, 255, 255, 255 },
                                onClick = function()
                                    currentSliderHeight_ = 0
                                    ApplyHeightToSelected(0)
                                    UpdateMenuState()
                                end,
                            },
                        },
                    },
                    -- 应用高度按钮（使用滑块值）
                    UI.Button {
                        id = "btnApplyHeight",
                        text = "应用高度",
                        fontSize = 12,
                        fontWeight = "bold",
                        borderRadius = 0,
                        paddingTop = 5, paddingBottom = 5,
                        backgroundColor = { 40, 130, 90, 255 },
                        hoverBackgroundColor = { 55, 160, 110, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        visible = false,
                        onClick = function()
                            ApplyHeightToSelected(currentSliderHeight_)
                        end,
                    },
                    -- ====== 平滑控制 ======
                    UI.Panel {
                        width = "100%",
                        height = 1,
                        backgroundColor = T.border,
                        marginTop = 6,
                    },
                    UI.Label {
                        text = "平滑过渡",
                        fontSize = 13,
                        fontWeight = "bold",
                        fontColor = T.text,
                        textAlign = "center",
                        marginTop = 4,
                    },
                    UI.Label {
                        id = "smoothValue",
                        text = string.format("%.2f", currentSmoothValue_),
                        fontSize = 12,
                        fontColor = T.textSecondary,
                        textAlign = "center",
                    },
                    UI.Slider {
                        id = "smoothSlider",
                        value = currentSmoothValue_ * 100,
                        min = 0,
                        max = 100,
                        step = 1,
                        height = 20,
                        onChange = function(self, v)
                            currentSmoothValue_ = v / 100
                            local label = menuPanel_ and menuPanel_:FindById("smoothValue")
                            if label then
                                label.text = string.format("%.2f", currentSmoothValue_)
                            end
                            -- 实时应用平滑到选中格子
                            if #selectedCells_ > 0 then
                                ApplySmoothToSelected(currentSmoothValue_)
                            end
                        end,
                    },
                    -- 平滑预设按钮
                    UI.Panel {
                        flexDirection = "row",
                        justifyContent = "space-between",
                        width = "100%",
                        marginTop = 2,
                        children = (function()
                            local presets = {0, 0.2, 0.5, 0.8, 1}
                            local btns = {}
                            for _, pv in ipairs(presets) do
                                btns[#btns + 1] = UI.Button {
                                    text = tostring(pv),
                                    fontSize = 10,
                                    height = 22,
                                    flexGrow = 1,
                                    marginLeft = 1,
                                    marginRight = 1,
                                    onClick = function()
                                        currentSmoothValue_ = pv
                                        local label = menuPanel_ and menuPanel_:FindById("smoothValue")
                                        if label then
                                            label.text = string.format("%.2f", pv)
                                        end
                                        local slider = menuPanel_ and menuPanel_:FindById("smoothSlider")
                                        if slider then
                                            slider:SetValue(pv * 100)
                                        end
                                        if #selectedCells_ > 0 then
                                            ApplySmoothToSelected(pv)
                                        end
                                    end,
                                }
                            end
                            return btns
                        end)(),
                    },
                },
            },
        },
    }

    root:AddChild(menuPanel_)
    UpdateMenuState()
end

CloseMenu = function()
    if menuPanel_ then
        menuPanel_:Remove()
        menuPanel_ = nil
    end
end

--- 地形类型中文名称
local TYPE_NAMES = { open = "空地", blocked = "障碍", target = "目标区" }

--- 根据选中状态更新菜单按钮可见性
UpdateMenuState = function()
    if not menuPanel_ then return end

    local hasSelection = #selectedCells_ > 0

    local selLabel = menuPanel_:FindById("terrainSelCount")
    if selLabel then
        if hasSelection then
            -- 统计选中格子的地形类型
            local typeCounts = {}
            for _, cell in ipairs(selectedCells_) do
                local t = (grid_[cell.x] and grid_[cell.x][cell.z]) or CELL_OPEN
                typeCounts[t] = (typeCounts[t] or 0) + 1
            end
            -- 构建类型描述
            local parts = {}
            for t, count in pairs(typeCounts) do
                table.insert(parts, string.format("%s×%d", TYPE_NAMES[t] or t, count))
            end
            selLabel.text = string.format("已选 %d 格\n%s", #selectedCells_, table.concat(parts, " "))
        else
            selLabel.text = "未选中"
        end
    end

    local btnOpen = menuPanel_:FindById("btnToOpen")
    local btnBlocked = menuPanel_:FindById("btnToBlocked")
    local btnTarget = menuPanel_:FindById("btnToTarget")
    local btnClear = menuPanel_:FindById("btnClearSel")
    local btnApplyH = menuPanel_:FindById("btnApplyHeight")

    if btnOpen then btnOpen.visible = hasSelection end
    if btnBlocked then btnBlocked.visible = hasSelection end
    if btnTarget then btnTarget.visible = hasSelection end
    if btnClear then btnClear.visible = hasSelection end
    if btnApplyH then btnApplyH.visible = hasSelection end
end

return TerrainEditor
