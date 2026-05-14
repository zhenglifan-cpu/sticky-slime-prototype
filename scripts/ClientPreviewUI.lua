-- ============================================================================
-- ClientPreviewUI.lua
-- 预览模式 UI 按钮（网格开关、编辑开关、地形开关、保存按钮、地图存档、操作提示切换）
-- 从 Client.lua 提取，不改变任何游戏行为
-- ============================================================================

local UI = require("urhox-libs/UI")

local ClientPreviewUI = {}

-- 由 Init() 注入的外部依赖
local hudLabels_
local getUIRoot             -- function() → uiRoot_
local MapPreviewCamera
local MapEditor
local TerrainEditor
---@type Scene
local scene_ = nil
local MapCloudSave = nil

-- 存档面板状态
local archivePanelVisible_ = false

-- 前置声明（定义在后面的存档面板区域）
local RefreshArchivePanel

-- 延时任务队列（避免使用全局 SubscribeToEvent/UnsubscribeFromEvent）
local pendingTimers_ = {}  -- { {remaining, callback}, ... }

--- 添加延时任务
---@param delay number 延迟秒数
---@param callback function 回调
local function AddTimer(delay, callback)
    pendingTimers_[#pendingTimers_ + 1] = { remaining = delay, callback = callback }
end

--- 由外部 Update 调用以驱动计时器
---@param dt number delta time
function ClientPreviewUI.Tick(dt)
    local i = 1
    while i <= #pendingTimers_ do
        local t = pendingTimers_[i]
        t.remaining = t.remaining - dt
        if t.remaining <= 0 then
            t.callback()
            table.remove(pendingTimers_, i)
        else
            i = i + 1
        end
    end
end

--- 初始化模块，注入外部依赖
---@param deps table { hudLabels, getUIRoot, MapPreviewCamera, MapEditor, TerrainEditor, scene, MapCloudSave }
function ClientPreviewUI.Init(deps)
    hudLabels_        = deps.hudLabels
    getUIRoot         = deps.getUIRoot
    MapPreviewCamera  = deps.MapPreviewCamera
    MapEditor         = deps.MapEditor
    TerrainEditor     = deps.TerrainEditor
    scene_            = deps.scene
    MapCloudSave      = deps.MapCloudSave
end

-- ============================================================================
-- 坐标网格开关按钮
-- ============================================================================

function ClientPreviewUI.CreateGridToggleButton()
    -- Design DNA: 蓝色面板堆叠、黑结构边框、底部强调、硬阴影、直角
    hudLabels_.gridTogglePanel = UI.Panel {
        id = "gridTogglePanel",
        position = "absolute",
        top = 10,
        right = 10,
        visible = false,
        -- 外层：黑结构边框 + 底部强调色加深
        backgroundColor = { 0, 0, 0, 255 },
        borderRadius = 0,
        padding = 2,
        paddingBottom = 4, -- 底部加厚 → 深度强调
        boxShadow = {
            { x = 0, y = 6, blur = 0, spread = 0, color = { 0, 0, 0, 64 } },
            { x = 0, y = 8, blur = 4, spread = 0, color = { 0, 0, 0, 64 } },
        },
        children = {
            UI.Button {
                id = "gridToggleBtn",
                text = "网格: 开",
                fontSize = 15,
                fontWeight = "bold",
                borderRadius = 0,
                backgroundColor = { 33, 69, 138, 255 },           -- Surface #21458A
                hoverBackgroundColor = { 45, 102, 200, 255 },     -- Hover  #2D66C8
                pressedBackgroundColor = { 34, 89, 183, 255 },    -- Pressed #2259B7
                fontColor = { 255, 255, 255, 255 },
                paddingLeft = 16,
                paddingRight = 16,
                paddingTop = 8,
                paddingBottom = 8,
                onClick = function(self)
                    local newState = not MapPreviewCamera.IsGridEnabled()
                    MapPreviewCamera.SetGridEnabled(newState)
                    self.text = newState and "网格: 开" or "网格: 关"
                end,
            },
        },
    }
    getUIRoot():AddChild(hudLabels_.gridTogglePanel)
end

-- ============================================================================
-- 俯瞰视角按钮
-- ============================================================================

function ClientPreviewUI.CreateOrthoToggleButton()
    hudLabels_.orthoTogglePanel = UI.Panel {
        id = "orthoTogglePanel",
        position = "absolute",
        top = 60,
        right = 10,
        visible = false,
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
                id = "orthoToggleBtn",
                text = "俯瞰: 关",
                fontSize = 15,
                fontWeight = "bold",
                borderRadius = 0,
                backgroundColor = { 40, 90, 110, 255 },
                hoverBackgroundColor = { 55, 120, 150, 255 },
                pressedBackgroundColor = { 48, 105, 130, 255 },
                fontColor = { 255, 255, 255, 255 },
                paddingLeft = 16,
                paddingRight = 16,
                paddingTop = 8,
                paddingBottom = 8,
                onClick = function(self)
                    local newState = not MapPreviewCamera.IsOrthoMode()
                    MapPreviewCamera.SetOrthoMode(newState)
                    if newState then
                        self.text = "俯瞰: 开"
                        self.backgroundColor = { 20, 140, 170, 255 }
                        self.hoverBackgroundColor = { 30, 170, 200, 255 }
                    else
                        self.text = "俯瞰: 关"
                        self.backgroundColor = { 40, 90, 110, 255 }
                        self.hoverBackgroundColor = { 55, 120, 150, 255 }
                    end
                end,
            },
        },
    }
    getUIRoot():AddChild(hudLabels_.orthoTogglePanel)
end

-- ============================================================================
-- 地图编辑器按钮
-- ============================================================================

function ClientPreviewUI.CreateEditToggleButton()
    hudLabels_.editTogglePanel = UI.Panel {
        id = "editTogglePanel",
        position = "absolute",
        top = 110,
        right = 10,
        visible = false,
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
                id = "editToggleBtn",
                text = "编辑: 关",
                fontSize = 15,
                fontWeight = "bold",
                borderRadius = 0,
                backgroundColor = { 90, 40, 40, 255 },
                hoverBackgroundColor = { 130, 50, 50, 255 },
                pressedBackgroundColor = { 110, 45, 45, 255 },
                fontColor = { 255, 255, 255, 255 },
                paddingLeft = 16,
                paddingRight = 16,
                paddingTop = 8,
                paddingBottom = 8,
                onClick = function(self)
                    if MapEditor.IsActive() then
                        MapEditor.Disable()
                        self.text = "编辑: 关"
                        self.backgroundColor = { 90, 40, 40, 255 }
                        self.hoverBackgroundColor = { 130, 50, 50, 255 }
                    else
                        -- 开启编辑前，自动关闭地形模式
                        if TerrainEditor.IsActive() then
                            TerrainEditor.Disable()
                            local tBtn = hudLabels_.terrainTogglePanel and hudLabels_.terrainTogglePanel:FindById("terrainToggleBtn")
                            if tBtn then
                                tBtn.text = "地形: 关"
                                tBtn.backgroundColor = { 70, 40, 100, 255 }
                                tBtn.hoverBackgroundColor = { 100, 55, 140, 255 }
                            end
                        end
                        MapEditor.Enable()
                        self.text = "编辑: 开"
                        self.backgroundColor = { 40, 120, 40, 255 }
                        self.hoverBackgroundColor = { 50, 150, 50, 255 }
                    end
                end,
            },
        },
    }
    getUIRoot():AddChild(hudLabels_.editTogglePanel)
end

-- ============================================================================
-- 地形规划按钮
-- ============================================================================

function ClientPreviewUI.CreateTerrainToggleButton()
    hudLabels_.terrainTogglePanel = UI.Panel {
        id = "terrainTogglePanel",
        position = "absolute",
        top = 160,
        right = 10,
        visible = false,
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
                id = "terrainToggleBtn",
                text = "地形: 关",
                fontSize = 15,
                fontWeight = "bold",
                borderRadius = 0,
                backgroundColor = { 70, 40, 100, 255 },
                hoverBackgroundColor = { 100, 55, 140, 255 },
                pressedBackgroundColor = { 85, 48, 120, 255 },
                fontColor = { 255, 255, 255, 255 },
                paddingLeft = 16,
                paddingRight = 16,
                paddingTop = 8,
                paddingBottom = 8,
                onClick = function(self)
                    if TerrainEditor.IsActive() then
                        TerrainEditor.Disable()
                        self.text = "地形: 关"
                        self.backgroundColor = { 70, 40, 100, 255 }
                        self.hoverBackgroundColor = { 100, 55, 140, 255 }
                    else
                        -- 开启地形前，自动关闭编辑模式
                        if MapEditor.IsActive() then
                            MapEditor.Disable()
                            local eBtn = hudLabels_.editTogglePanel and hudLabels_.editTogglePanel:FindById("editToggleBtn")
                            if eBtn then
                                eBtn.text = "编辑: 关"
                                eBtn.backgroundColor = { 90, 40, 40, 255 }
                                eBtn.hoverBackgroundColor = { 130, 50, 50, 255 }
                            end
                        end
                        TerrainEditor.Enable()
                        self.text = "地形: 开"
                        self.backgroundColor = { 120, 60, 180, 255 }
                        self.hoverBackgroundColor = { 140, 75, 200, 255 }
                    end
                end,
            },
        },
    }
    getUIRoot():AddChild(hudLabels_.terrainTogglePanel)
end

-- ============================================================================
-- 保存地图按钮 — 点击弹出栏位选择面板（保存/读取/删除 统一入口）
-- ============================================================================

function ClientPreviewUI.CreateSaveButton()
    hudLabels_.savePanel = UI.Panel {
        id = "savePanel",
        position = "absolute",
        top = 10,
        left = 10,
        visible = false,
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
                id = "saveBtn",
                text = "保存地图",
                fontSize = 15,
                fontWeight = "bold",
                borderRadius = 0,
                backgroundColor = { 33, 100, 33, 255 },
                hoverBackgroundColor = { 45, 140, 45, 255 },
                pressedBackgroundColor = { 34, 110, 34, 255 },
                fontColor = { 255, 255, 255, 255 },
                paddingLeft = 16,
                paddingRight = 16,
                paddingTop = 8,
                paddingBottom = 8,
                onClick = function(self)
                    -- 弹出/关闭栏位选择面板
                    archivePanelVisible_ = not archivePanelVisible_
                    if hudLabels_.archivePanel then
                        hudLabels_.archivePanel.visible = archivePanelVisible_
                    end
                    if archivePanelVisible_ then
                        RefreshArchivePanel()
                    end
                end,
            },
        },
    }
    getUIRoot():AddChild(hudLabels_.savePanel)
end

-- ============================================================================
-- 存档栏位面板（保存/读取/删除 统一入口，由"保存地图"按钮触发）
-- ============================================================================

--- 格式化时间戳为可读字符串
---@param ts number Unix 时间戳
---@return string
local function FormatTimestamp(ts)
    if ts <= 0 then return "空" end
    return os.date("%m/%d %H:%M", ts)
end

--- 创建单个存档栏位 UI
---@param slotIndex number 1|2|3
---@param slotInfo table {exists, ts}
---@return table UI.Panel
local function CreateSlotRow(slotIndex, slotInfo)
    local statusText = slotInfo.exists and FormatTimestamp(slotInfo.ts) or "空栏位"
    local statusColor = slotInfo.exists and { 200, 220, 255, 255 } or { 120, 120, 140, 255 }

    return UI.Panel {
        id = "slotRow_" .. slotIndex,
        flexDirection = "row",
        alignItems = "center",
        gap = 8,
        padding = 6,
        backgroundColor = { 20, 25, 40, 200 },
        borderRadius = 0,
        children = {
            -- 栏位标签
            UI.Label {
                id = "slotLabel_" .. slotIndex,
                text = "栏位 " .. slotIndex .. ": " .. statusText,
                fontSize = 13,
                fontWeight = "bold",
                fontColor = statusColor,
                flexGrow = 1,
            },
            -- 保存按钮
            UI.Button {
                id = "slotSave_" .. slotIndex,
                text = "保存",
                fontSize = 12,
                fontWeight = "bold",
                borderRadius = 0,
                backgroundColor = { 33, 100, 33, 255 },
                hoverBackgroundColor = { 45, 140, 45, 255 },
                pressedBackgroundColor = { 34, 110, 34, 255 },
                fontColor = { 255, 255, 255, 255 },
                paddingLeft = 10,
                paddingRight = 10,
                paddingTop = 4,
                paddingBottom = 4,
                onClick = function(self)
                    if not MapCloudSave or not scene_ then return end
                    self.text = "..."

                    -- 同时输出到日志
                    MapEditor.SaveToLog()
                    TerrainEditor.ExportToLog()

                    MapCloudSave.SaveToSlot(scene_, slotIndex, function(success, errMsg)
                        if success then
                            self.text = "OK"
                            local label = hudLabels_.archivePanel and hudLabels_.archivePanel:FindById("slotLabel_" .. slotIndex)
                            if label then
                                label.text = "栏位 " .. slotIndex .. ": " .. FormatTimestamp(os.time())
                                label.fontColor = { 200, 220, 255, 255 }
                            end
                        else
                            self.text = "失败"
                            print("[ClientPreviewUI] 栏位" .. slotIndex .. "保存失败: " .. tostring(errMsg))
                        end
                        AddTimer(1.5, function()
                            self.text = "保存"
                        end)
                    end)
                end,
            },
            -- 读取按钮
            UI.Button {
                id = "slotLoad_" .. slotIndex,
                text = "读取",
                fontSize = 12,
                fontWeight = "bold",
                borderRadius = 0,
                backgroundColor = { 33, 69, 138, 255 },
                hoverBackgroundColor = { 45, 102, 200, 255 },
                pressedBackgroundColor = { 34, 89, 183, 255 },
                fontColor = { 255, 255, 255, 255 },
                paddingLeft = 10,
                paddingRight = 10,
                paddingTop = 4,
                paddingBottom = 4,
                onClick = function(self)
                    if not MapCloudSave or not scene_ then return end
                    self.text = "..."
                    MapCloudSave.LoadFromSlot(slotIndex, function(success, result)
                        if success then
                            MapCloudSave.ApplyToScene(scene_, result, function(applyOk, applyResult)
                                if applyOk then
                                    self.text = "OK"
                                    local label = hudLabels_.archivePanel and hudLabels_.archivePanel:FindById("slotLabel_" .. slotIndex)
                                    if label and applyResult then
                                        label.text = "栏位 " .. slotIndex .. ": " .. applyResult
                                        label.fontColor = { 100, 255, 100, 255 }
                                    end
                                    print("[ClientPreviewUI] 栏位" .. slotIndex .. "已读取: " .. tostring(applyResult))
                                    AddTimer(3.0, function()
                                        if label then
                                            label.text = "栏位 " .. slotIndex .. ": " .. FormatTimestamp(os.time())
                                            label.fontColor = { 200, 220, 255, 255 }
                                        end
                                    end)
                                else
                                    self.text = "失败"
                                    print("[ClientPreviewUI] 应用存档失败: " .. tostring(applyResult))
                                end
                            end)
                        else
                            self.text = "空"
                            print("[ClientPreviewUI] 栏位" .. slotIndex .. "读取失败: " .. tostring(result))
                        end
                        AddTimer(1.5, function()
                            self.text = "读取"
                        end)
                    end)
                end,
            },
            -- 删除按钮
            UI.Button {
                id = "slotDel_" .. slotIndex,
                text = "删除",
                fontSize = 12,
                fontWeight = "bold",
                borderRadius = 0,
                backgroundColor = { 120, 30, 30, 255 },
                hoverBackgroundColor = { 160, 40, 40, 255 },
                pressedBackgroundColor = { 140, 35, 35, 255 },
                fontColor = { 255, 255, 255, 255 },
                paddingLeft = 10,
                paddingRight = 10,
                paddingTop = 4,
                paddingBottom = 4,
                onClick = function(self)
                    if not MapCloudSave then return end
                    self.text = "..."
                    MapCloudSave.DeleteSlot(slotIndex, function(success, errMsg)
                        if success then
                            self.text = "OK"
                            local label = hudLabels_.archivePanel and hudLabels_.archivePanel:FindById("slotLabel_" .. slotIndex)
                            if label then
                                label.text = "栏位 " .. slotIndex .. ": 空栏位"
                                label.fontColor = { 120, 120, 140, 255 }
                            end
                        else
                            self.text = "失败"
                            print("[ClientPreviewUI] 栏位" .. slotIndex .. "删除失败: " .. tostring(errMsg))
                        end
                        AddTimer(1.5, function()
                            self.text = "删除"
                        end)
                    end)
                end,
            },
        },
    }
end

--- 刷新存档面板内容（查询所有栏位后重建子元素）
function RefreshArchivePanel()
    if not hudLabels_.archivePanel then return end
    if not MapCloudSave then return end

    local contentPanel = hudLabels_.archivePanel:FindById("archiveContent")
    if not contentPanel then return end

    -- 清空并显示加载提示
    contentPanel:RemoveAllChildren()
    contentPanel:AddChild(UI.Label {
        text = "查询中...",
        fontSize = 13,
        fontColor = { 150, 150, 170, 255 },
        textAlign = "center",
    })

    MapCloudSave.QueryAllSlots(function(slots)
        contentPanel:RemoveAllChildren()

        -- 提示信息：WASM 平台存档不持久
        contentPanel:AddChild(UI.Label {
            text = "提示: 预览模式存档仅在当前会话有效，刷新页面后将丢失",
            fontSize = 11,
            fontColor = { 200, 160, 80, 200 },
            padding = 4,
        })

        -- 栏位 1-3
        for i = 1, 3 do
            contentPanel:AddChild(CreateSlotRow(i, slots[i]))
        end
    end)
end

--- 创建存档面板（由 CreateSaveButton 的弹窗触发显示）
function ClientPreviewUI.CreateArchiveButton()
    -- 存档面板（紧贴在"保存地图"按钮下方）
    hudLabels_.archivePanel = UI.Panel {
        id = "archivePanel",
        position = "absolute",
        top = 60,
        left = 10,
        width = 340,
        visible = false,
        backgroundColor = { 0, 0, 0, 230 },
        borderRadius = 0,
        padding = 2,
        boxShadow = {
            { x = 0, y = 6, blur = 0, spread = 0, color = { 0, 0, 0, 64 } },
            { x = 0, y = 8, blur = 4, spread = 0, color = { 0, 0, 0, 64 } },
        },
        children = {
            -- 标题栏
            UI.Panel {
                flexDirection = "row",
                justifyContent = "space-between",
                alignItems = "center",
                padding = 6,
                backgroundColor = { 20, 50, 20, 255 },
                children = {
                    UI.Label {
                        text = "选择存档栏位",
                        fontSize = 14,
                        fontWeight = "bold",
                        fontColor = { 180, 255, 180, 255 },
                    },
                    UI.Button {
                        text = "X",
                        fontSize = 12,
                        fontWeight = "bold",
                        borderRadius = 0,
                        backgroundColor = { 120, 30, 30, 255 },
                        hoverBackgroundColor = { 160, 40, 40, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        paddingLeft = 8,
                        paddingRight = 8,
                        paddingTop = 2,
                        paddingBottom = 2,
                        onClick = function()
                            archivePanelVisible_ = false
                            if hudLabels_.archivePanel then
                                hudLabels_.archivePanel.visible = false
                            end
                        end,
                    },
                },
            },
            -- 内容区域（栏位列表）
            UI.Panel {
                id = "archiveContent",
                flexDirection = "column",
                gap = 2,
                padding = 4,
                children = {
                    UI.Label {
                        text = "加载中...",
                        fontSize = 13,
                        fontColor = { 120, 120, 140, 255 },
                    },
                },
            },
        },
    }
    getUIRoot():AddChild(hudLabels_.archivePanel)
end

-- ============================================================================
-- 操作提示切换
-- ============================================================================

function ClientPreviewUI.UpdateControlHint()
    local isPreviewing = MapPreviewCamera.IsActive()

    -- 预览模式：隐藏底部操作提示，显示网格/编辑/地形按钮
    -- 游戏模式：显示底部操作提示，隐藏网格/编辑/地形按钮
    if hudLabels_.controlHint then
        hudLabels_.controlHint.text = "WASD 移动 | Shift 冲刺 | 空格 拍手 | E 撒面包 | 1-4 标记 | P 预览"
    end
    if hudLabels_.controlHintBar then
        hudLabels_.controlHintBar.visible = not isPreviewing
    end
    if hudLabels_.gridTogglePanel then
        hudLabels_.gridTogglePanel.visible = isPreviewing
    end
    if hudLabels_.orthoTogglePanel then
        hudLabels_.orthoTogglePanel.visible = isPreviewing
    end
    if hudLabels_.editTogglePanel then
        hudLabels_.editTogglePanel.visible = isPreviewing
    end
    if hudLabels_.terrainTogglePanel then
        hudLabels_.terrainTogglePanel.visible = isPreviewing
    end

    -- 保存按钮：预览模式下始终可见
    if hudLabels_.savePanel then
        hudLabels_.savePanel.visible = isPreviewing
    end

    -- 退出预览时隐藏存档面板
    if not isPreviewing then
        archivePanelVisible_ = false
        if hudLabels_.archivePanel then
            hudLabels_.archivePanel.visible = false
        end
    end

    -- 退出预览时自动关闭俯瞰模式
    if not isPreviewing and MapPreviewCamera.IsOrthoMode() then
        MapPreviewCamera.SetOrthoMode(false)
        local btn = hudLabels_.orthoTogglePanel and hudLabels_.orthoTogglePanel:FindById("orthoToggleBtn")
        if btn then
            btn.text = "俯瞰: 关"
            btn.backgroundColor = { 40, 90, 110, 255 }
            btn.hoverBackgroundColor = { 55, 120, 150, 255 }
        end
    end

    -- 退出预览时自动关闭编辑器
    if not isPreviewing and MapEditor.IsActive() then
        MapEditor.Disable()
        local btn = hudLabels_.editTogglePanel and hudLabels_.editTogglePanel:FindById("editToggleBtn")
        if btn then
            btn.text = "编辑: 关"
            btn.backgroundColor = { 90, 40, 40, 255 }
            btn.hoverBackgroundColor = { 130, 50, 50, 255 }
        end
    end

    -- 退出预览时自动关闭地形编辑器
    if not isPreviewing and TerrainEditor.IsActive() then
        TerrainEditor.Disable()
        local btn = hudLabels_.terrainTogglePanel and hudLabels_.terrainTogglePanel:FindById("terrainToggleBtn")
        if btn then
            btn.text = "地形: 关"
            btn.backgroundColor = { 70, 40, 100, 255 }
            btn.hoverBackgroundColor = { 100, 55, 140, 255 }
        end
    end
end

return ClientPreviewUI
