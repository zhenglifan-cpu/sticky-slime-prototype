-- ============================================================================
-- MapEditorAddModel.lua — 地图编辑器·添加模型模块
-- 包含：模型选择面板、添加按钮、确认添加逻辑
-- ============================================================================

local MapEditorAddModel = {}

local Config = require("config.GameConfig")
local Shared = require("network.Shared")
local UI = require("urhox-libs/UI")
local AstroonTheme = require("config.AstroonTheme")

-- ============================================================================
-- 常量
-- ============================================================================

-- 模型中文显示名（key 对应 Config.Models）
local MODEL_DISPLAY_NAMES = {
    TreeTall    = "大树",       TreeMedium  = "中树",     TreeSmall   = "小树",
    Cabin       = "小屋",       HayBale     = "草堆",     WaterTrough = "饮水池",
    Crate       = "木箱",       Barrel      = "木桶",
    RockLarge   = "大岩石",     RockCluster = "石堆",     RockFlat    = "扁石",
    Bush        = "灌木",       LargeLeaf   = "大叶菜",   SmallFlower = "小花",
    SmallGrass  = "小草",       Fence       = "围栏段",   Wall        = "围墙段",
}

-- 模型列表有序显示
local MODEL_LIST_ORDER = {
    "Cabin", "Barrel", "Crate", "HayBale", "WaterTrough",
    "TreeTall", "TreeMedium", "TreeSmall",
    "RockLarge", "RockCluster", "RockFlat",
    "Bush", "LargeLeaf", "SmallFlower", "SmallGrass",
    "Fence", "Wall",
}

-- ============================================================================
-- 从宿主传入的常量
-- ============================================================================
local STATE_IDLE
local STATE_ADDING
local SNAP_SIZE

-- ============================================================================
-- 上下文与回调（由 Init 注入）
-- ============================================================================
local ctx           -- 共享状态表
local GetUIRoot          -- fn() -> UIElement
local CloseAllUI         -- fn()
local SendObsEdit        -- fn(action, obsName, extra, isDec)

--- 初始化模块
---@param sharedCtx table  宿主共享状态表
---@param helpers table    回调函数表
---@param consts table     常量表
function MapEditorAddModel.Init(sharedCtx, helpers, consts)
    ctx = sharedCtx
    GetUIRoot  = helpers.GetUIRoot
    CloseAllUI = helpers.CloseAllUI
    SendObsEdit = helpers.SendObsEdit

    STATE_IDLE   = consts.STATE_IDLE
    STATE_ADDING = consts.STATE_ADDING
    SNAP_SIZE    = consts.SNAP_SIZE
end

-- ============================================================================
-- 内部函数前置声明
-- ============================================================================
local GetScreenCenterGround
local ShowAddButton
local CloseAddButton
local ShowAddPanel
local CloseAddPanel
local ConfirmAdd

-- ============================================================================
-- 实现
-- ============================================================================

--- 画面中心射线投射到 Y=0 地面，返回网格对齐后的世界坐标
GetScreenCenterGround = function()
    if not ctx.cameraNode then return nil end
    local camera = ctx.cameraNode:GetComponent("Camera")
    if not camera then return nil end

    -- 画面正中心 (0.5, 0.5)
    local ray = camera:GetScreenRay(0.5, 0.5)
    if math.abs(ray.direction.y) < 0.0001 then return nil end
    local t = -ray.origin.y / ray.direction.y
    if t < 0 then return nil end

    local worldX = ray.origin.x + t * ray.direction.x
    local worldZ = ray.origin.z + t * ray.direction.z

    -- 按网格对齐
    local snappedX = math.floor(worldX / SNAP_SIZE + 0.5) * SNAP_SIZE
    local snappedZ = math.floor(worldZ / SNAP_SIZE + 0.5) * SNAP_SIZE
    return Vector3(snappedX, 0, snappedZ)
end

--- 显示左下角"添加模型"按钮
ShowAddButton = function()
    if ctx.addButton then return end
    local root = GetUIRoot()
    if not root then return end

    local T = AstroonTheme.Tokens
    ctx.addButton = UI.Panel {
        id = "addModelBtn",
        position = "absolute",
        bottom = 20,
        left = 20,
        backgroundColor = { 0, 0, 0, 255 },
        borderRadius = 0,
        padding = 2,
        paddingBottom = 4,
        boxShadow = {
            { x = 0, y = 6, blur = 0, spread = 0, color = { 0, 0, 0, 64 } },
            { x = 0, y = 8, blur = 4, spread = 0, color = { 0, 0, 0, 64 } },
        },
        children = {
            UI.Button {
                text = "+ 添加模型",
                fontSize = 15,
                fontWeight = "bold",
                borderRadius = 0,
                backgroundColor = { 40, 120, 40, 255 },
                hoverBackgroundColor = { 50, 150, 50, 255 },
                pressedBackgroundColor = { 35, 100, 35, 255 },
                fontColor = { 255, 255, 255, 255 },
                paddingLeft = 16,
                paddingRight = 16,
                paddingTop = 8,
                paddingBottom = 8,
                onClick = function()
                    ShowAddPanel()
                end,
            },
        },
    }
    root:AddChild(ctx.addButton)
end

--- 隐藏左下角按钮
CloseAddButton = function()
    if ctx.addButton then
        ctx.addButton:Remove()
        ctx.addButton = nil
    end
end

--- 显示模型选择面板
ShowAddPanel = function()
    CloseAddPanel()
    CloseAllUI()

    local root = GetUIRoot()
    if not root then return end

    ctx.state = STATE_ADDING
    ctx.addSelectedKey = nil

    local T = AstroonTheme.Tokens

    -- 构建模型按钮列表
    local modelButtons = {}
    for _, key in ipairs(MODEL_LIST_ORDER) do
        if Config.Models[key] then
            local displayName = MODEL_DISPLAY_NAMES[key] or key
            local modelKey = key
            table.insert(modelButtons, UI.Button {
                id = "modelItem_" .. modelKey,
                text = displayName,
                fontSize = 13,
                fontWeight = "normal",
                borderRadius = 4,
                width = "100%",
                paddingTop = 8,
                paddingBottom = 8,
                paddingLeft = 12,
                paddingRight = 12,
                backgroundColor = { 50, 50, 60, 255 },
                hoverBackgroundColor = { 70, 70, 90, 255 },
                fontColor = { 220, 220, 220, 255 },
                marginBottom = 4,
                onClick = function(self)
                    -- 取消之前选中项的高亮
                    if ctx.addSelectedKey and ctx.addPanel then
                        local prevBtn = ctx.addPanel:FindById("modelItem_" .. ctx.addSelectedKey)
                        if prevBtn then
                            prevBtn.backgroundColor = { 50, 50, 60, 255 }
                            prevBtn.fontColor = { 220, 220, 220, 255 }
                        end
                    end
                    -- 高亮当前
                    ctx.addSelectedKey = modelKey
                    self.backgroundColor = { 40, 120, 40, 255 }
                    self.fontColor = { 255, 255, 255, 255 }
                end,
            })
        end
    end

    ctx.addPanel = UI.Panel {
        id = "addModelPanel",
        position = "absolute",
        top = "50%",
        left = "50%",
        translateX = -1,
        translateY = -1,
        width = 260,
        maxHeight = 420,
        backgroundColor = { T.surface[1], T.surface[2], T.surface[3], 240 },
        borderRadius = 8,
        borderWidth = 1,
        borderColor = T.border,
        padding = 12,
        boxShadow = {
            { x = 0, y = 4, blur = 16, spread = 0, color = T.shadow },
        },
        children = {
            -- 标题
            UI.Label {
                text = "选择模型",
                fontSize = 16,
                fontWeight = "bold",
                fontColor = T.text,
                marginBottom = 10,
            },
            -- 滚动区域
            UI.ScrollView {
                width = "100%",
                maxHeight = 280,
                flexShrink = 1,
                children = {
                    UI.Panel {
                        width = "100%",
                        children = modelButtons,
                    },
                },
            },
            -- 底部按钮行
            UI.Panel {
                flexDirection = "row",
                gap = 8,
                marginTop = 10,
                justifyContent = "flex-end",
                width = "100%",
                children = {
                    UI.Button {
                        text = "确认添加",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 14, paddingRight = 14,
                        paddingTop = 7, paddingBottom = 7,
                        backgroundColor = { 40, 120, 40, 255 },
                        hoverBackgroundColor = { 50, 150, 50, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function()
                            ConfirmAdd()
                        end,
                    },
                    UI.Button {
                        text = "取消",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 14, paddingRight = 14,
                        paddingTop = 7, paddingBottom = 7,
                        backgroundColor = { 120, 40, 40, 255 },
                        hoverBackgroundColor = { 160, 50, 50, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function()
                            CloseAddPanel()
                            ctx.state = STATE_IDLE
                            ShowAddButton()
                        end,
                    },
                },
            },
        },
    }
    root:AddChild(ctx.addPanel)

    -- 隐藏左下角添加按钮（面板打开时不需要）
    CloseAddButton()
end

--- 关闭模型选择面板
CloseAddPanel = function()
    if ctx.addPanel then
        ctx.addPanel:Remove()
        ctx.addPanel = nil
    end
    ctx.addSelectedKey = nil
end

--- 确认添加模型到场景
ConfirmAdd = function()
    if not ctx.addSelectedKey then
        print("[MapEditor] 未选择模型")
        return
    end

    local modelInfo = Config.Models[ctx.addSelectedKey]
    if not modelInfo then
        print("[MapEditor] 模型信息不存在: " .. tostring(ctx.addSelectedKey))
        return
    end

    -- 获取画面中心地面坐标
    local groundPos = GetScreenCenterGround()
    if not groundPos then
        print("[MapEditor] 无法获取画面中心地面坐标")
        return
    end

    -- 自增计数，生成唯一名称
    ctx.addCounter = ctx.addCounter + 1
    local uniqueName = "Added_" .. ctx.addSelectedKey .. "_" .. ctx.addCounter

    -- 根据模型信息计算合理的 scale
    local msDefault = 1.0
    local obsScale
    if modelInfo and modelInfo.footprintRadius then
        local dia = modelInfo.footprintRadius * 2 * msDefault
        obsScale = Vector3(dia, 2, dia)
    else
        obsScale = Vector3(1, 1, 1)
    end

    -- 构造障碍物数据
    local newObs = {
        pos = Vector3(groundPos.x, 0, groundPos.z),
        scale = obsScale,
        name = uniqueName,
        modelKey = ctx.addSelectedKey,
        modelScale = msDefault,
    }

    -- 添加到配置并创建场景节点
    table.insert(Config.Level1.Obstacles, newObs)
    Shared.CreateObstacle(ctx.scene, newObs, false)
    Shared.MarkObstacleCollidersDirty()

    -- 网络同步：通知服务端添加障碍物
    SendObsEdit("add", uniqueName, {
        posX = groundPos.x,
        posZ = groundPos.z,
        modelKey = ctx.addSelectedKey,
        modelScale = msDefault,
        scaleX = obsScale.x, scaleY = obsScale.y, scaleZ = obsScale.z,
    })

    local displayName = MODEL_DISPLAY_NAMES[ctx.addSelectedKey] or ctx.addSelectedKey
    print(string.format("[MapEditor] 已添加: %s (%s) 在 (%.1f, %.1f)",
        displayName, uniqueName, groundPos.x, groundPos.z))

    -- 关闭面板，回到空闲状态
    CloseAddPanel()
    ctx.state = STATE_IDLE
    ShowAddButton()
end

-- ============================================================================
-- 导出
-- ============================================================================

MapEditorAddModel.ShowAddButton  = ShowAddButton
MapEditorAddModel.CloseAddButton = CloseAddButton
MapEditorAddModel.ShowAddPanel   = ShowAddPanel
MapEditorAddModel.CloseAddPanel  = CloseAddPanel
MapEditorAddModel.ConfirmAdd     = ConfirmAdd

return MapEditorAddModel
