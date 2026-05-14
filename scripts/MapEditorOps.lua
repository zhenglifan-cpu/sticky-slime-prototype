-- ============================================================================
-- MapEditorOps.lua — 地图编辑器操作模块
-- 包含：删除、移动、旋转、缩放操作 + 对应 UI 面板 + 辅助函数
-- ============================================================================

local MapEditorOps = {}

local Config = require("config.GameConfig")
local Shared = require("network.Shared")
local UI = require("urhox-libs/UI")
local AstroonTheme = require("config.AstroonTheme")

-- ============================================================================
-- 常量（从宿主模块传入）
-- ============================================================================
local STATE_IDLE
local STATE_SELECTED
local STATE_MOVING
local STATE_ROTATING
local STATE_SCALING
local SNAP_SIZE
local PRESET_ANGLES
local EVENTS

-- ============================================================================
-- 上下文与回调（由 Init 注入）
-- ============================================================================
local ctx           -- 共享状态表
local GetSelectedEntry   -- fn() -> table|nil
local GetSelectedName    -- fn() -> string
local GetUIRoot          -- fn() -> UIElement
local CloseAllUI         -- fn()
local ShowMenu           -- fn()
local UpdateMenuPosition -- fn()
local SendObsEdit        -- fn(action, obsName, extra, isDec)

--- 初始化模块
---@param sharedCtx table  宿主共享状态表
---@param helpers table    回调函数表
---@param consts table     常量表
function MapEditorOps.Init(sharedCtx, helpers, consts)
    ctx = sharedCtx
    GetSelectedEntry   = helpers.GetSelectedEntry
    GetSelectedName    = helpers.GetSelectedName
    GetUIRoot          = helpers.GetUIRoot
    CloseAllUI         = helpers.CloseAllUI
    ShowMenu           = helpers.ShowMenu
    UpdateMenuPosition = helpers.UpdateMenuPosition
    SendObsEdit        = helpers.SendObsEdit

    STATE_IDLE     = consts.STATE_IDLE
    STATE_SELECTED = consts.STATE_SELECTED
    STATE_MOVING   = consts.STATE_MOVING
    STATE_ROTATING = consts.STATE_ROTATING
    STATE_SCALING  = consts.STATE_SCALING
    SNAP_SIZE      = consts.SNAP_SIZE
    PRESET_ANGLES  = consts.PRESET_ANGLES
    EVENTS         = consts.EVENTS
end

-- ============================================================================
-- 内部函数前置声明
-- ============================================================================
local ShowRotatePanel
local CloseRotatePanel
local UpdateRotateLabels
local ShowScalePanel
local CloseScalePanel
local ShowStatusHint
local CloseStatusHint
local RaycastGround
local RealignVisual
local ApplyRotation
local ApplyScale

-- ============================================================================
-- 删除操作
-- ============================================================================

local function DeleteSelected()
    if not ctx.selectedNode then return end

    local name = GetSelectedName()

    if ctx.selectedType == "obstacle" and ctx.selectedObsIndex then
        print(string.format("[MapEditor] 删除障碍物: %s (索引 %d)", name, ctx.selectedObsIndex))
        ctx.selectedNode:Remove()
        table.remove(Config.Level1.Obstacles, ctx.selectedObsIndex)
        Shared.MarkObstacleCollidersDirty()
        SendObsEdit("delete", name)
        print(string.format("[MapEditor] 已删除: %s, 剩余障碍物: %d", name, #Config.Level1.Obstacles))
    elseif ctx.selectedType == "decoration" and ctx.selectedObsIndex then
        print(string.format("[MapEditor] 删除装饰物: %s (索引 %d)", name, ctx.selectedObsIndex))
        ctx.selectedNode:Remove()
        table.remove(Config.Exterior.Decorations, ctx.selectedObsIndex)
        SendObsEdit("delete", name, nil, true)
        print(string.format("[MapEditor] 已删除: %s, 剩余装饰物: %d", name, #Config.Exterior.Decorations))
    elseif ctx.selectedType == "structure" and ctx.selectedStructIndex then
        local struct = ctx.structureList[ctx.selectedStructIndex]
        local structType = struct.type  -- "Wall" or "Fence"
        local side = struct.side or ""  -- 围栏方向标识 (right/top/bottom)
        print(string.format("[MapEditor] 删除结构物: %s (索引 %d, 类型 %s, side=%s)", name, ctx.selectedStructIndex, structType, side))
        ctx.selectedNode:Remove()
        table.remove(ctx.structureList, ctx.selectedStructIndex)
        -- 向服务端发送结构物删除事件
        local serverConn = network:GetServerConnection()
        if serverConn then
            local vm = VariantMap()
            vm["Action"] = Variant("delete")
            vm["Label"]  = Variant(name)         -- 如 "围栏段1"
            vm["Type"]   = Variant(structType)    -- "Wall" or "Fence"
            vm["Side"]   = Variant(side)          -- 物理方向 (right/top/bottom)
            serverConn:SendRemoteEvent(EVENTS.MAP_EDIT_STRUCT, true, vm)
            print(string.format("[MapEditor->Server] 发送结构物删除: %s (%s, side=%s)", name, structType, side))
        end
        print(string.format("[MapEditor] 已删除: %s, 剩余结构物: %d", name, #ctx.structureList))
    end

    -- 清理状态
    ctx.selectedNode = nil
    ctx.selectedObsIndex = nil
    ctx.selectedType = nil
    ctx.selectedStructIndex = nil
    ctx.state = STATE_IDLE
    CloseAllUI()
end

-- ============================================================================
-- 移动操作
-- ============================================================================

local function StartMove()
    if not ctx.selectedNode then return end
    ctx.state = STATE_MOVING
    -- 结构段是子节点，用世界坐标；障碍物/装饰物是场景直接子节点，position 即世界坐标
    if ctx.selectedType == "structure" then
        local wp = ctx.selectedNode.worldPosition
        ctx.moveOrigPos = Vector3(wp.x, wp.y, wp.z)
    else
        ctx.moveOrigPos = Vector3(ctx.selectedNode.position.x, ctx.selectedNode.position.y, ctx.selectedNode.position.z)
    end
    ctx.moveCurrent = Vector3(ctx.moveOrigPos.x, ctx.moveOrigPos.y, ctx.moveOrigPos.z)
    CloseAllUI()

    ShowStatusHint("左键拖拽移动 | WASD 微调 0.1m | Enter 确认 | Esc 取消")
    print("[MapEditor] 开始移动: " .. GetSelectedName())
end

-- 吸附阈值：仅在距网格线很近时才吸附
local SNAP_THRESHOLD = 0.15  -- 距离网格线 <= 0.15m 时吸附
-- WASD 微调步长
local WASD_STEP = 0.1  -- 每次按键移动 0.1m

--- 可选吸附：仅在非常接近网格线时才对齐
---@param v number 原始坐标
---@return number 吸附后的坐标
local function SoftSnap(v)
    local snapped = math.floor(v / SNAP_SIZE + 0.5) * SNAP_SIZE
    if math.abs(v - snapped) <= SNAP_THRESHOLD then
        return snapped
    end
    return v
end

--- 应用移动位置（抽取公共逻辑）
local function ApplyMovePosition(posX, posZ)
    if not ctx.selectedNode then return end

    if (ctx.selectedType == "obstacle" or ctx.selectedType == "decoration") and ctx.selectedObsIndex then
        local entry = GetSelectedEntry()
        local terrainY = Shared.GetTerrainHeightAt(posX, posZ)
        local yOff = (entry.scale and entry.scale.y / 2 or 0) + terrainY
        ctx.moveCurrent = Vector3(posX, yOff, posZ)
        ctx.selectedNode.position = ctx.moveCurrent
        RealignVisual(ctx.selectedNode, entry)
    else
        -- 结构段：用世界坐标移动
        ctx.moveCurrent = Vector3(posX, ctx.moveOrigPos.y, posZ)
        ctx.selectedNode.worldPosition = ctx.moveCurrent
    end
end

local function HandleMoveInput(dt)
    if not ctx.selectedNode then return end

    -- 左键按住期间持续拖拽模型跟随鼠标（精确定位 + 软吸附）
    if input:GetMouseButtonDown(MOUSEB_LEFT) and not UI.IsPointerOverUI() then
        local hitPos = RaycastGround()
        if hitPos then
            local posX = SoftSnap(hitPos.x)
            local posZ = SoftSnap(hitPos.z)
            ApplyMovePosition(posX, posZ)
        end
    end

    -- WASD 微调（按一次移动一步）
    local dx, dz = 0, 0
    if input:GetKeyPress(KEY_A) then dx = -WASD_STEP end
    if input:GetKeyPress(KEY_D) then dx = WASD_STEP end
    if input:GetKeyPress(KEY_W) then dz = WASD_STEP end
    if input:GetKeyPress(KEY_S) then dz = -WASD_STEP end

    if dx ~= 0 or dz ~= 0 then
        local curX, curZ
        if ctx.selectedType == "structure" then
            curX = ctx.selectedNode.worldPosition.x
            curZ = ctx.selectedNode.worldPosition.z
        else
            curX = ctx.selectedNode.position.x
            curZ = ctx.selectedNode.position.z
        end
        ApplyMovePosition(curX + dx, curZ + dz)
    end
end

local function ConfirmMove()
    if not ctx.selectedNode then return end

    if ctx.selectedType == "obstacle" and ctx.selectedObsIndex then
        local obs = Config.Level1.Obstacles[ctx.selectedObsIndex]
        obs.pos = Vector3(ctx.selectedNode.position.x, 0, ctx.selectedNode.position.z)
        Shared.MarkObstacleCollidersDirty()
        SendObsEdit("move", obs.name, { posX = obs.pos.x, posZ = obs.pos.z })
        print(string.format("[MapEditor] 移动确认: %s -> (%.1f, %.1f)", obs.name, obs.pos.x, obs.pos.z))
    elseif ctx.selectedType == "decoration" and ctx.selectedObsIndex then
        local dec = Config.Exterior.Decorations[ctx.selectedObsIndex]
        dec.pos = Vector3(ctx.selectedNode.position.x, 0, ctx.selectedNode.position.z)
        SendObsEdit("move", dec.name, { posX = dec.pos.x, posZ = dec.pos.z }, true)
        print(string.format("[MapEditor] 移动确认(装饰): %s -> (%.1f, %.1f)", dec.name, dec.pos.x, dec.pos.z))
    else
        print(string.format("[MapEditor] 移动确认: %s -> (%.1f, %.1f)", GetSelectedName(), ctx.selectedNode.position.x, ctx.selectedNode.position.z))
    end

    ctx.state = STATE_SELECTED
    CloseAllUI()
    ShowMenu()
end

local function CancelMove()
    if ctx.selectedNode and ctx.moveOrigPos then
        if ctx.selectedType == "structure" then
            ctx.selectedNode.worldPosition = ctx.moveOrigPos
        else
            ctx.selectedNode.position = ctx.moveOrigPos
            if (ctx.selectedType == "obstacle" or ctx.selectedType == "decoration") and ctx.selectedObsIndex then
                local entry = GetSelectedEntry()
                if entry then RealignVisual(ctx.selectedNode, entry) end
            end
        end
    end
    ctx.state = STATE_SELECTED
    CloseAllUI()
    ShowMenu()
    print("[MapEditor] 移动取消")
end

-- ============================================================================
-- 旋转操作（角度输入面板，支持水平+垂直）
-- ============================================================================

local function StartRotate()
    if not ctx.selectedNode then return end
    ctx.state = STATE_ROTATING

    -- 保存原始旋转
    if ctx.selectedType == "structure" then
        -- 结构物：旋转根节点
        ctx.rotateOrigRot = Quaternion(ctx.selectedNode.rotation.w, ctx.selectedNode.rotation.x, ctx.selectedNode.rotation.y, ctx.selectedNode.rotation.z)
        ctx.rotateOrigModelRot = nil
        local euler = ctx.selectedNode.rotation:EulerAngles()
        ctx.rotatePitch = math.floor(euler.x + 0.5)
        ctx.rotateYaw = math.floor(euler.y + 0.5)
    else
        -- 障碍物：旋转 Visual 子节点
        local visual = ctx.selectedNode:GetChild("Visual")
        if visual then
            ctx.rotateOrigModelRot = Quaternion(visual.rotation.w, visual.rotation.x, visual.rotation.y, visual.rotation.z)
            ctx.rotateOrigRot = nil
            local euler = visual.rotation:EulerAngles()
            ctx.rotatePitch = math.floor(euler.x + 0.5)
            ctx.rotateYaw = math.floor(euler.y + 0.5)
        else
            ctx.rotateOrigRot = Quaternion(ctx.selectedNode.rotation.w, ctx.selectedNode.rotation.x, ctx.selectedNode.rotation.y, ctx.selectedNode.rotation.z)
            ctx.rotateOrigModelRot = nil
            local euler = ctx.selectedNode.rotation:EulerAngles()
            ctx.rotatePitch = math.floor(euler.x + 0.5)
            ctx.rotateYaw = math.floor(euler.y + 0.5)
        end
    end

    CloseAllUI()
    ShowRotatePanel()
    print("[MapEditor] 开始旋转: " .. GetSelectedName())
end

--- 应用旋转角度到模型
ApplyRotation = function()
    if not ctx.selectedNode then return end
    local newRot = Quaternion(ctx.rotatePitch, ctx.rotateYaw, 0)

    if ctx.selectedType == "structure" then
        ctx.selectedNode.rotation = newRot
    else
        local visual = ctx.selectedNode:GetChild("Visual")
        if visual then
            visual.rotation = newRot
        else
            ctx.selectedNode.rotation = newRot
        end
        -- 重新对齐底部（障碍物/装饰物）
        if ctx.selectedObsIndex then
            local entry = GetSelectedEntry()
            if entry then RealignVisual(ctx.selectedNode, entry) end
        end
    end
end

local function ConfirmRotate()
    if not ctx.selectedNode then return end

    if (ctx.selectedType == "obstacle" or ctx.selectedType == "decoration") and ctx.selectedObsIndex then
        local entry = GetSelectedEntry()
        local visual = ctx.selectedNode:GetChild("Visual")
        if visual and entry then
            entry.modelRotation = Quaternion(visual.rotation.w, visual.rotation.x, visual.rotation.y, visual.rotation.z)
        end
        print(string.format("[MapEditor] 旋转确认: %s, 水平=%d° 垂直=%d°", GetSelectedName(), ctx.rotateYaw, ctx.rotatePitch))
    else
        print(string.format("[MapEditor] 旋转确认: %s, 水平=%d° 垂直=%d°", GetSelectedName(), ctx.rotateYaw, ctx.rotatePitch))
    end

    ctx.state = STATE_SELECTED
    CloseAllUI()
    ShowMenu()
end

local function CancelRotate()
    if ctx.selectedType == "structure" then
        if ctx.selectedNode and ctx.rotateOrigRot then
            ctx.selectedNode.rotation = ctx.rotateOrigRot
        end
    else
        local visual = ctx.selectedNode and ctx.selectedNode:GetChild("Visual")
        if visual and ctx.rotateOrigModelRot then
            visual.rotation = ctx.rotateOrigModelRot
        elseif ctx.selectedNode and ctx.rotateOrigRot then
            ctx.selectedNode.rotation = ctx.rotateOrigRot
        end
        -- 重新对齐（障碍物/装饰物）
        if ctx.selectedNode and ctx.selectedObsIndex then
            local entry = GetSelectedEntry()
            if entry then RealignVisual(ctx.selectedNode, entry) end
        end
    end

    ctx.state = STATE_SELECTED
    CloseAllUI()
    ShowMenu()
    print("[MapEditor] 旋转取消")
end

-- ============================================================================
-- 旋转面板 UI
-- ============================================================================

ShowRotatePanel = function()
    CloseRotatePanel()
    local root = GetUIRoot()
    if not root then return end

    local T = AstroonTheme.Tokens
    local displayName = GetSelectedName()

    -- 预设按钮构建辅助函数
    local function MakePresetBtn(angle, applyFn)
        return UI.Button {
            text = angle .. "°",
            fontSize = 12,
            fontWeight = "bold",
            borderRadius = 4,
            paddingLeft = 8, paddingRight = 8,
            paddingTop = 4, paddingBottom = 4,
            backgroundColor = { 50, 50, 80, 255 },
            hoverBackgroundColor = { 70, 70, 110, 255 },
            fontColor = { 255, 255, 255, 255 },
            onClick = function() applyFn(angle) end,
        }
    end

    -- 水平旋转预设按钮
    local yawPresetChildren = {}
    for _, angle in ipairs(PRESET_ANGLES) do
        table.insert(yawPresetChildren, MakePresetBtn(angle, function(a)
            ctx.rotateYaw = a
            ApplyRotation()
            UpdateRotateLabels()
        end))
    end

    -- 垂直旋转预设按钮
    local pitchPresetChildren = {}
    for _, angle in ipairs(PRESET_ANGLES) do
        table.insert(pitchPresetChildren, MakePresetBtn(angle, function(a)
            ctx.rotatePitch = a
            ApplyRotation()
            UpdateRotateLabels()
        end))
    end

    ctx.rotatePanel = UI.Panel {
        id = "rotatePanel",
        position = "absolute",
        top = 0,
        left = 0,
        translateX = -1,
        translateY = -1,
        width = 360,
        padding = 12,
        backgroundColor = { T.surface[1], T.surface[2], T.surface[3], 230 },
        borderRadius = 8,
        borderWidth = 1,
        borderColor = T.border,
        boxShadow = {
            { x = 0, y = 4, blur = 12, spread = 0, color = T.shadow },
        },
        alignItems = "center",
        gap = 8,
        children = {
            UI.Label {
                text = "旋转: " .. displayName,
                fontSize = 14,
                fontWeight = "bold",
                fontColor = T.text,
            },
            -- 水平旋转 (Yaw)
            UI.Panel {
                width = "100%",
                gap = 4,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        gap = 8,
                        children = {
                            UI.Label {
                                text = "水平:",
                                fontSize = 13,
                                fontWeight = "bold",
                                fontColor = T.text,
                                width = 40,
                            },
                            UI.Slider {
                                id = "yawSlider",
                                value = ctx.rotateYaw + 180,
                                min = 0, max = 360, step = 1,
                                flexGrow = 1,
                                onChange = function(self, v)
                                    ctx.rotateYaw = math.floor(v - 180 + 0.5)
                                    ApplyRotation()
                                    UpdateRotateLabels()
                                end,
                            },
                            UI.Label {
                                id = "yawValueLabel",
                                text = ctx.rotateYaw .. "°",
                                fontSize = 14,
                                fontWeight = "bold",
                                fontColor = T.primary,
                                width = 45,
                                textAlign = "right",
                            },
                        },
                    },
                    UI.Panel {
                        flexDirection = "row",
                        flexWrap = "wrap",
                        gap = 4,
                        alignItems = "center",
                        justifyContent = "center",
                        children = {
                            yawPresetChildren[1],
                            yawPresetChildren[2],
                            yawPresetChildren[3],
                            yawPresetChildren[4],
                            UI.TextField {
                                id = "yawInput",
                                value = tostring(ctx.rotateYaw),
                                placeholder = "角度",
                                width = 60,
                                height = 28,
                                fontSize = 12,
                                textAlign = "center",
                                onSubmit = function(self, v)
                                    local num = tonumber(v)
                                    if num then
                                        ctx.rotateYaw = math.floor(num + 0.5)
                                        ApplyRotation()
                                        UpdateRotateLabels()
                                    end
                                end,
                            },
                        },
                    },
                },
            },
            -- 垂直旋转 (Pitch)
            UI.Panel {
                width = "100%",
                gap = 4,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        gap = 8,
                        children = {
                            UI.Label {
                                text = "垂直:",
                                fontSize = 13,
                                fontWeight = "bold",
                                fontColor = T.text,
                                width = 40,
                            },
                            UI.Slider {
                                id = "pitchSlider",
                                value = ctx.rotatePitch + 180,
                                min = 0, max = 360, step = 1,
                                flexGrow = 1,
                                onChange = function(self, v)
                                    ctx.rotatePitch = math.floor(v - 180 + 0.5)
                                    ApplyRotation()
                                    UpdateRotateLabels()
                                end,
                            },
                            UI.Label {
                                id = "pitchValueLabel",
                                text = ctx.rotatePitch .. "°",
                                fontSize = 14,
                                fontWeight = "bold",
                                fontColor = T.primary,
                                width = 45,
                                textAlign = "right",
                            },
                        },
                    },
                    UI.Panel {
                        flexDirection = "row",
                        flexWrap = "wrap",
                        gap = 4,
                        alignItems = "center",
                        justifyContent = "center",
                        children = {
                            pitchPresetChildren[1],
                            pitchPresetChildren[2],
                            pitchPresetChildren[3],
                            pitchPresetChildren[4],
                            UI.TextField {
                                id = "pitchInput",
                                value = tostring(ctx.rotatePitch),
                                placeholder = "角度",
                                width = 60,
                                height = 28,
                                fontSize = 12,
                                textAlign = "center",
                                onSubmit = function(self, v)
                                    local num = tonumber(v)
                                    if num then
                                        ctx.rotatePitch = math.floor(num + 0.5)
                                        ApplyRotation()
                                        UpdateRotateLabels()
                                    end
                                end,
                            },
                        },
                    },
                },
            },
            -- 操作按钮
            UI.Panel {
                flexDirection = "row",
                gap = 10,
                children = {
                    UI.Button {
                        text = "确认",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 16, paddingRight = 16,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 40, 120, 40, 255 },
                        hoverBackgroundColor = { 50, 150, 50, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() ConfirmRotate() end,
                    },
                    UI.Button {
                        text = "取消",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 16, paddingRight = 16,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 120, 40, 40, 255 },
                        hoverBackgroundColor = { 150, 50, 50, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() CancelRotate() end,
                    },
                },
            },
        },
    }

    root:AddChild(ctx.rotatePanel)
    UpdateMenuPosition()
end

CloseRotatePanel = function()
    if ctx.rotatePanel then
        ctx.rotatePanel:Remove()
        ctx.rotatePanel = nil
    end
end

--- 更新旋转面板中的角度数值标签
UpdateRotateLabels = function()
    if not ctx.rotatePanel then return end
    local yawLabel = ctx.rotatePanel:FindById("yawValueLabel")
    if yawLabel then yawLabel.text = ctx.rotateYaw .. "°" end
    local pitchLabel = ctx.rotatePanel:FindById("pitchValueLabel")
    if pitchLabel then pitchLabel.text = ctx.rotatePitch .. "°" end
end

-- ============================================================================
-- 缩放操作
-- ============================================================================

local function StartScale()
    if not ctx.selectedNode then return end
    ctx.state = STATE_SCALING

    if (ctx.selectedType == "obstacle" or ctx.selectedType == "decoration") and ctx.selectedObsIndex then
        local entry = GetSelectedEntry()
        ctx.scaleOrigScale = entry and entry.modelScale or 1.0
    else
        -- 结构物：使用根节点 scale
        ctx.scaleOrigScale = ctx.selectedNode.scale.x
    end
    ctx.scaleCurrent = ctx.scaleOrigScale

    CloseAllUI()
    ShowScalePanel()
    print("[MapEditor] 开始缩放: " .. GetSelectedName() .. " 当前: " .. ctx.scaleOrigScale)
end

local function HandleScaleInput(dt)
    -- 缩放由 UI Slider 驱动
end

ApplyScale = function(value)
    if not ctx.selectedNode then return end
    ctx.scaleCurrent = value

    if ctx.selectedType == "structure" then
        -- 结构物：缩放根节点
        ctx.selectedNode.scale = Vector3(value, value, value)
    else
        -- 障碍物/装饰物：缩放 Visual 子节点
        local visual = ctx.selectedNode:GetChild("Visual")
        if visual then
            visual.scale = Vector3(value, value, value)
        end
        if ctx.selectedObsIndex then
            local entry = GetSelectedEntry()
            if entry then RealignVisual(ctx.selectedNode, entry) end
        end
    end
end

local function ConfirmScale()
    if not ctx.selectedNode then return end

    if ctx.selectedType == "obstacle" and ctx.selectedObsIndex then
        local obs = Config.Level1.Obstacles[ctx.selectedObsIndex]
        obs.modelScale = ctx.scaleCurrent
        Shared.MarkObstacleCollidersDirty()
        SendObsEdit("scale", obs.name, { modelScale = ctx.scaleCurrent })
        print(string.format("[MapEditor] 缩放确认: %s -> %.2f", obs.name, ctx.scaleCurrent))
    elseif ctx.selectedType == "decoration" and ctx.selectedObsIndex then
        local dec = Config.Exterior.Decorations[ctx.selectedObsIndex]
        dec.modelScale = ctx.scaleCurrent
        SendObsEdit("scale", dec.name, { modelScale = ctx.scaleCurrent }, true)
        print(string.format("[MapEditor] 缩放确认(装饰): %s -> %.2f", dec.name, ctx.scaleCurrent))
    else
        print(string.format("[MapEditor] 缩放确认: %s -> %.2f", GetSelectedName(), ctx.scaleCurrent))
    end

    ctx.state = STATE_SELECTED
    CloseAllUI()
    ShowMenu()
end

local function CancelScale()
    if ctx.selectedNode then
        if ctx.selectedType == "structure" then
            if ctx.scaleOrigScale then
                ctx.selectedNode.scale = Vector3(ctx.scaleOrigScale, ctx.scaleOrigScale, ctx.scaleOrigScale)
            end
        else
            local visual = ctx.selectedNode:GetChild("Visual")
            if visual and ctx.scaleOrigScale then
                visual.scale = Vector3(ctx.scaleOrigScale, ctx.scaleOrigScale, ctx.scaleOrigScale)
            end
            if ctx.selectedObsIndex then
                local entry = GetSelectedEntry()
                if entry then RealignVisual(ctx.selectedNode, entry) end
            end
        end
    end

    ctx.state = STATE_SELECTED
    CloseAllUI()
    ShowMenu()
    print("[MapEditor] 缩放取消")
end

-- ============================================================================
-- 缩放面板 UI
-- ============================================================================

ShowScalePanel = function()
    CloseScalePanel()
    local root = GetUIRoot()
    if not root then return end

    local T = AstroonTheme.Tokens
    local displayName = GetSelectedName()

    ctx.scalePanel = UI.Panel {
        id = "scalePanel",
        position = "absolute",
        top = 0,
        left = 0,
        translateX = -1,
        translateY = -1,
        width = 320,
        padding = 12,
        backgroundColor = { T.surface[1], T.surface[2], T.surface[3], 230 },
        borderRadius = 8,
        borderWidth = 1,
        borderColor = T.border,
        boxShadow = {
            { x = 0, y = 4, blur = 12, spread = 0, color = T.shadow },
        },
        alignItems = "center",
        gap = 8,
        children = {
            UI.Label {
                text = "缩放: " .. displayName,
                fontSize = 14,
                fontWeight = "bold",
                fontColor = T.text,
            },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                alignItems = "center",
                gap = 8,
                children = {
                    UI.Label {
                        text = "0.1x",
                        fontSize = 11,
                        fontColor = T.textMuted,
                    },
                    UI.Slider {
                        id = "scaleSlider",
                        value = ctx.scaleCurrent * 10,
                        min = 1, max = 100, step = 1,
                        flexGrow = 1,
                        onChange = function(self, v)
                            local realValue = v / 10.0
                            ApplyScale(realValue)
                            local label = ctx.scalePanel and ctx.scalePanel:FindById("scaleValueLabel")
                            if label then
                                label.text = string.format("%.1fx", realValue)
                            end
                        end,
                    },
                    UI.Label {
                        text = "10x",
                        fontSize = 11,
                        fontColor = T.textMuted,
                    },
                },
            },
            UI.Label {
                id = "scaleValueLabel",
                text = string.format("%.1fx", ctx.scaleCurrent),
                fontSize = 16,
                fontWeight = "bold",
                fontColor = T.primary,
            },
            -- 操作按钮
            UI.Panel {
                flexDirection = "row",
                gap = 10,
                children = {
                    UI.Button {
                        text = "✓ 确认",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 16, paddingRight = 16,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 40, 120, 40, 255 },
                        hoverBackgroundColor = { 50, 150, 50, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() ConfirmScale() end,
                    },
                    UI.Button {
                        text = "✗ 取消",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 16, paddingRight = 16,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 120, 40, 40, 255 },
                        hoverBackgroundColor = { 150, 50, 50, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() CancelScale() end,
                    },
                },
            },
        },
    }

    root:AddChild(ctx.scalePanel)
    UpdateMenuPosition()
end

CloseScalePanel = function()
    if ctx.scalePanel then
        ctx.scalePanel:Remove()
        ctx.scalePanel = nil
    end
end

-- ============================================================================
-- 状态提示 UI
-- ============================================================================

ShowStatusHint = function(text)
    CloseStatusHint()
    local root = GetUIRoot()
    if not root then return end

    local T = AstroonTheme.Tokens

    ctx.statusHintPanel = UI.Panel {
        id = "editorStatusHint",
        position = "absolute",
        bottom = 50,
        left = "50%",
        translateX = -1,
        padding = 10,
        paddingLeft = 20,
        paddingRight = 20,
        backgroundColor = { T.surface[1], T.surface[2], T.surface[3], 220 },
        borderRadius = 9999,
        borderWidth = 1,
        borderColor = T.border,
        children = {
            UI.Label {
                text = text,
                fontSize = 14,
                fontColor = T.text,
                textAlign = "center",
            },
        },
    }

    root:AddChild(ctx.statusHintPanel)
end

CloseStatusHint = function()
    if ctx.statusHintPanel then
        ctx.statusHintPanel:Remove()
        ctx.statusHintPanel = nil
    end
end

-- ============================================================================
-- 辅助函数
-- ============================================================================

--- 射线与地面 Y=0 求交
---@return Vector3|nil
RaycastGround = function()
    if not ctx.cameraNode then return nil end
    local camera = ctx.cameraNode:GetComponent("Camera")
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

--- 重新计算 Visual 子节点的底部对齐
---@param node Node
---@param obs table
RealignVisual = function(node, obs)
    if not obs then return end
    local visual = node:GetChild("Visual")
    if not visual then return end

    local model = visual:GetComponent("StaticModel")
    if not model then return end

    visual.position = Vector3(visual.position.x, 0, visual.position.z)

    local worldBB = model.worldBoundingBox
    local worldMinY = worldBB.min.y
    visual.position = Vector3(
        visual.position.x,
        visual.position.y + (node.position.y - obs.scale.y / 2) - worldMinY,
        visual.position.z
    )
end

-- ============================================================================
-- 导出
-- ============================================================================

MapEditorOps.DeleteSelected   = DeleteSelected
MapEditorOps.StartMove        = StartMove
MapEditorOps.HandleMoveInput  = HandleMoveInput
MapEditorOps.ConfirmMove      = ConfirmMove
MapEditorOps.CancelMove       = CancelMove
MapEditorOps.StartRotate      = StartRotate
MapEditorOps.ConfirmRotate    = ConfirmRotate
MapEditorOps.CancelRotate     = CancelRotate
MapEditorOps.StartScale       = StartScale
MapEditorOps.HandleScaleInput = HandleScaleInput
MapEditorOps.ConfirmScale     = ConfirmScale
MapEditorOps.CancelScale      = CancelScale
MapEditorOps.CloseRotatePanel = CloseRotatePanel
MapEditorOps.CloseScalePanel  = CloseScalePanel
MapEditorOps.ShowStatusHint   = ShowStatusHint
MapEditorOps.CloseStatusHint  = CloseStatusHint
MapEditorOps.RaycastGround    = RaycastGround
MapEditorOps.RealignVisual    = RealignVisual

return MapEditorOps
