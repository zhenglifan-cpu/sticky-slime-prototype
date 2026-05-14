-- ============================================================================
-- MapEditor.lua — 地图编辑模式
-- 在预览模式下编辑障碍物：选中、移动、旋转、缩放、删除、保存
-- ============================================================================

local MapEditor = {}

local Config = require("config.GameConfig")
local Shared = require("network.Shared")
local UI = require("urhox-libs/UI")
local AstroonTheme = require("config.AstroonTheme")
local MapEditorOps = require("MapEditorOps")
local MapEditorAddModel = require("MapEditorAddModel")

-- ============================================================================
-- 常量
-- ============================================================================

-- 编辑器状态
local STATE_IDLE     = "idle"       -- 等待选中
local STATE_SELECTED = "selected"   -- 已选中，显示菜单
local STATE_MOVING   = "moving"     -- 移动中
local STATE_ROTATING = "rotating"   -- 旋转面板中
local STATE_SCALING  = "scaling"    -- 缩放中
local STATE_ADDING   = "adding"     -- 添加模型中

-- 右键双击检测参数
local DOUBLE_CLICK_TIME = 0.4    -- 两次点击间隔 (s)
local CLICK_MOVE_THRESH = 5      -- 像素移动超过此值视为拖拽

-- 网格对齐
local SNAP_SIZE = 1.0            -- 移动对齐网格边缘 (m)

-- 高亮颜色
local HIGHLIGHT_COLOR = Color(0.0, 1.0, 0.5, 0.8)
local MOVING_COLOR    = Color(0.2, 0.6, 1.0, 0.8)
local GHOST_COLOR     = Color(0.2, 1.0, 0.4, 0.6)

-- 预设旋转角度
local PRESET_ANGLES = { 45, 90, 135, 180 }

-- ============================================================================
-- 共享上下文（所有子模块通过 ctx 访问共享状态）
-- ============================================================================

local ctx = {
    ---@type Scene
    scene = nil,
    ---@type Node
    cameraNode = nil,

    active = false,
    state = STATE_IDLE,

    -- 选中的对象
    ---@type Node
    selectedNode = nil,
    selectedObsIndex = nil,      -- obstacle/decoration 时在对应数组中的索引
    selectedType = nil,          -- "obstacle" / "decoration" / "structure"
    selectedStructIndex = nil,   -- 在 ctx.structureList 中的索引（structure 类型时）

    -- 结构物列表（围墙/围栏，运行时扫描）
    structureList = {},          -- { {node=Node, type="Wall"|"Fence", label=string}, ... }

    -- 左键双击检测
    leftClickCount = 0,
    leftClickTimer = 0,
    leftDownPos = nil,           -- 左键按下时的鼠标位置
    leftWasDrag = false,         -- 本次左键按下期间是否拖拽

    -- 移动操作
    moveOrigPos = nil,           -- 移动前原始位置
    moveCurrent = nil,           -- 当前移动目标位置

    -- 旋转操作
    rotateOrigModelRot = nil,    -- 旋转前原始模型旋转
    rotateOrigRot = nil,
    rotateYaw = 0,               -- 当前水平旋转角度
    rotatePitch = 0,             -- 当前垂直旋转角度

    -- 缩放操作
    scaleOrigScale = nil,        -- 缩放前原始 modelScale
    scaleCurrent = 1.0,          -- 当前缩放值

    -- UI
    uiRoot = nil,                -- 外部传入的 UI root（或通过 getter 动态获取）
    uiRootGetter = nil,          -- UI root getter 函数
    menuPanel = nil,             -- 操作菜单面板（跟随模型位置）
    rotatePanel = nil,           -- 旋转面板
    scalePanel = nil,            -- 缩放滑条面板
    statusHintPanel = nil,       -- 状态提示
    addButton = nil,             -- 左下角"添加模型"按钮
    addPanel = nil,              -- 模型选择面板
    addSelectedKey = nil,        -- 当前选中的模型 key
    addCounter = 0,              -- 添加模型自增计数
}

--- 获取当前选中的配置项（obstacle 或 decoration）
---@return table|nil
local function GetSelectedEntry()
    if ctx.selectedType == "obstacle" and ctx.selectedObsIndex then
        return Config.Level1.Obstacles[ctx.selectedObsIndex]
    elseif ctx.selectedType == "decoration" and ctx.selectedObsIndex then
        return Config.Exterior.Decorations[ctx.selectedObsIndex]
    end
    return nil
end

-- 模型剪贴板: { modelKey, modelScale, modelRotation, obsScale, noCollision }
local modelClipboard_ = nil

-- 虚影粘贴模式
local pasteMode_ = false
---@type Node
local ghostNode_ = nil
local EnterModelPasteMode   -- 前向声明
local ExitModelPasteMode    -- 前向声明

-- ============================================================================
-- 内部函数前置声明（允许互相调用）
-- ============================================================================
local WorldToScreen
local MergeChildBoundingBoxes
local GetSelectedTopPos
local DetectLeftDoubleClick
local TrySelectAtMouse
local FindSelectableRoot
local SelectNode
local DeselectNode
local CloseAllUI
local ShowMenu
local CloseMenu
local UpdateMenuPosition
-- 以下由 MapEditorOps 模块提供，在文件末尾赋值
local DeleteSelected
local StartMove
local HandleMoveInput
local ConfirmMove
local CancelMove
local StartRotate
local ConfirmRotate
local CancelRotate
local CloseRotatePanel
local StartScale
local HandleScaleInput
local ConfirmScale
local CancelScale
local CloseScalePanel
local ShowStatusHint
local CloseStatusHint
local RaycastGround
local RealignVisual
-- 以下由 MapEditorAddModel 模块提供，在文件末尾赋值
local ShowAddButton
local CloseAddButton
local ShowAddPanel
local CloseAddPanel
local ConfirmAdd

-- ============================================================================
-- 网络同步：将编辑操作发送到服务端
-- ============================================================================

local EVENTS = Config.EVENTS

--- 向服务端发送障碍物/装饰物编辑事件
---@param action string "add"|"move"|"scale"|"delete"
---@param obsName string 名称（唯一标识）
---@param extra table|nil 附加数据
---@param isDec boolean|nil 是否为装饰物（默认 false = 障碍物）
local function SendObsEdit(action, obsName, extra, isDec)
    local serverConn = network:GetServerConnection()
    if not serverConn then return end

    local vm = VariantMap()
    vm["Action"] = Variant(action)
    vm["Name"]   = Variant(obsName)
    if isDec then vm["IsDec"] = Variant(true) end

    if extra then
        if extra.posX then vm["PosX"] = Variant(extra.posX) end
        if extra.posZ then vm["PosZ"] = Variant(extra.posZ) end
        if extra.modelScale then vm["ModelScale"] = Variant(extra.modelScale) end
        if extra.modelKey then vm["ModelKey"] = Variant(extra.modelKey) end
        if extra.scaleX then vm["ScaleX"] = Variant(extra.scaleX) end
        if extra.scaleY then vm["ScaleY"] = Variant(extra.scaleY) end
        if extra.scaleZ then vm["ScaleZ"] = Variant(extra.scaleZ) end
    end

    serverConn:SendRemoteEvent(EVENTS.MAP_EDIT_OBS, true, vm)
    print(string.format("[MapEditor->Server] 发送 %s: %s (dec=%s)", action, obsName, tostring(isDec or false)))
end

--- 向服务端发送地形网格同步事件
---@param gridData string 序列化的地形网格数据
local function SendTerrainSync(gridData)
    local serverConn = network:GetServerConnection()
    if not serverConn then return end

    local vm = VariantMap()
    vm["GridData"] = Variant(gridData)
    serverConn:SendRemoteEvent(EVENTS.MAP_EDIT_TERRAIN, true, vm)
    print("[MapEditor->Server] 发送地形网格同步")
end

-- 导出给 TerrainEditor 使用
MapEditor.SendTerrainSync = SendTerrainSync

-- ============================================================================
-- API
-- ============================================================================

--- 初始化
---@param camNode Node
---@param scene Scene
---@param rootOrGetter any  UI root 面板或 getter 函数
function MapEditor.Init(camNode, scene, rootOrGetter)
    ctx.cameraNode = camNode
    ctx.scene = scene
    if type(rootOrGetter) == "function" then
        ctx.uiRootGetter = rootOrGetter
        ctx.uiRoot = rootOrGetter()
    else
        ctx.uiRoot = rootOrGetter
        ctx.uiRootGetter = nil
    end
end

--- 获取当前有效的 UI root（优先使用 getter 动态获取）
local function GetUIRoot()
    if ctx.uiRootGetter then
        ctx.uiRoot = ctx.uiRootGetter()
    end
    return ctx.uiRoot
end

--- 扫描场景中的围墙和围栏的每个子段节点，建立结构物列表（单段可编辑）
local function ScanStructures()
    ctx.structureList = {}
    if not ctx.scene then return end

    local wallSegCount = 0
    local fenceSegCount = 0

    for i = 0, ctx.scene:GetNumChildren(false) - 1 do
        local child = ctx.scene:GetChild(i)
        if child.name == "Wall" or child.name == "Fence" then
            local typeName = child.name
            if typeName == "Wall" then
                -- 围墙：按子段（WallSeg）逐个编辑
                for j = 0, child:GetNumChildren(false) - 1 do
                    local seg = child:GetChild(j)
                    if seg:GetComponent("StaticModel") then
                        wallSegCount = wallSegCount + 1
                        table.insert(ctx.structureList, {
                            node = seg,
                            parentNode = child,
                            type = "Wall",
                            label = "围墙段" .. wallSegCount,
                        })
                    end
                end
            else
                -- 围栏：整个 Fence 父节点作为一个可编辑单元（包含多个 FenceSeg 子模型）
                -- 用位置识别方向（避免依赖创建顺序）
                local ta = Config.Level1.TargetArea
                local cx, cz = ta.Center.x, ta.Center.z
                local hw, hh = ta.Size.x / 2, ta.Size.z / 2
                local fp = child.position
                local side = "unknown"
                if fp.x > cx + hw * 0.5 then
                    side = "right"
                elseif fp.z > cz + hh * 0.5 then
                    side = "top"
                elseif fp.z < cz - hh * 0.5 then
                    side = "bottom"
                end
                fenceSegCount = fenceSegCount + 1
                local label = "围栏段" .. fenceSegCount
                table.insert(ctx.structureList, {
                    node = child,           -- 整个 Fence 父节点
                    parentNode = nil,       -- 顶层节点，无父级
                    type = "Fence",
                    label = label,
                    side = side,            -- 物理方向标识
                })
                print(string.format("[MapEditor] 围栏段: %s → side=%s pos=(%.1f,%.1f,%.1f)",
                    label, side, fp.x, fp.y, fp.z))
            end
        end
    end

    print(string.format("[MapEditor] 扫描到 %d 个围墙段, %d 个围栏段", wallSegCount, fenceSegCount))
end

--- 获取当前选中对象的名称
local function GetSelectedName()
    if (ctx.selectedType == "obstacle" or ctx.selectedType == "decoration") and ctx.selectedObsIndex then
        local entry = GetSelectedEntry()
        return entry and entry.name or "Unknown"
    elseif ctx.selectedType == "structure" and ctx.selectedStructIndex then
        return ctx.structureList[ctx.selectedStructIndex].label
    end
    return "Unknown"
end

--- 开启编辑模式
function MapEditor.Enable()
    ctx.active = true
    ctx.state = STATE_IDLE
    ctx.selectedNode = nil
    ctx.selectedObsIndex = nil
    ctx.selectedType = nil
    ctx.selectedStructIndex = nil
    rightClickCount_ = 0
    rightClickTimer_ = 0
    ScanStructures()
    CloseAllUI()

    -- 防御性清理：强制移除 TerrainEditor 可能残留的菜单
    local root = GetUIRoot()
    if root then
        local terrainMenu = root:FindById("terrainMenu")
        if terrainMenu then
            terrainMenu:Remove()
            print("[MapEditor] 强制移除残留的地形菜单")
        end
    end

    ShowAddButton()
    print(string.format("[MapEditor] 编辑模式已开启, ctx.uiRoot=%s", tostring(GetUIRoot())))
end

--- 关闭编辑模式
function MapEditor.Disable()
    -- 退出粘贴模式
    if pasteMode_ then
        ExitModelPasteMode()
    end
    -- 如果正在操作中，取消操作
    if ctx.state == STATE_MOVING then
        CancelMove()
    elseif ctx.state == STATE_ROTATING then
        CancelRotate()
    elseif ctx.state == STATE_SCALING then
        CancelScale()
    elseif ctx.state == STATE_ADDING then
        CloseAddPanel()
    end
    ctx.active = false
    ctx.state = STATE_IDLE
    ctx.selectedNode = nil
    ctx.selectedObsIndex = nil
    ctx.selectedType = nil
    ctx.selectedStructIndex = nil
    CloseAllUI()
    CloseAddButton()
    CloseAddPanel()
    print("[MapEditor] 编辑模式已关闭")
end

--- 是否处于编辑模式
---@return boolean
function MapEditor.IsActive()
    return ctx.active
end

--- 是否正在添加模型（面板打开中）
function MapEditor.IsAddingModel()
    return ctx.state == STATE_ADDING
end

--- 是否正在进行需要屏蔽左键的操作（移动时左键点击设置位置、粘贴模式）
---@return boolean
function MapEditor.IsOperating()
    return ctx.active and (ctx.state == STATE_MOVING or pasteMode_)
end

-- ============================================================================
-- 复制 / 粘贴模型
-- ============================================================================

--- 复制当前选中模型的数据到剪贴板
local function CopySelectedModel()
    if not ctx.selectedNode then return end

    if ctx.selectedType == "structure" then
        -- 结构物（围墙/围栏）：从节点读取模型信息
        local struct = ctx.structureList[ctx.selectedStructIndex]
        if not struct then
            print("[MapEditor] 结构物数据无效")
            return
        end

        local modelKey = struct.type  -- "Wall" or "Fence"
        local modelInfo = Config.Models[modelKey]
        if not modelInfo then
            print(string.format("[MapEditor] 未找到结构物模型配置: %s", modelKey))
            return
        end

        -- 围墙段：直接在节点上有 StaticModel 和 scale
        -- 围栏：整个 Fence 节点（含多个 FenceSeg），复制时取第一个子段的缩放
        local currentScale = 1.0
        local modelRot = nil

        if struct.type == "Wall" then
            -- WallSeg 节点直接有缩放和旋转
            currentScale = ctx.selectedNode.scale.x
            local angle = ctx.selectedNode.rotation:EulerAngles()
            if math.abs(angle.x) > 0.1 or math.abs(angle.y) > 0.1 or math.abs(angle.z) > 0.1 then
                modelRot = Quaternion(angle.x, angle.y, angle.z)
            end
        else
            -- Fence 节点：取第一个 FenceSeg 子节点的缩放
            for i = 0, ctx.selectedNode:GetNumChildren(false) - 1 do
                local seg = ctx.selectedNode:GetChild(i)
                if seg.name == "FenceSeg" then
                    currentScale = seg.scale.x
                    local angle = seg.rotation:EulerAngles()
                    if math.abs(angle.x) > 0.1 or math.abs(angle.y) > 0.1 or math.abs(angle.z) > 0.1 then
                        modelRot = Quaternion(angle.x, angle.y, angle.z)
                    end
                    break
                end
            end
        end

        -- 用模型的包围盒估算 obsScale（碰撞体大小）
        local bbSize = Vector3(1, 1, 1)
        local sm = ctx.selectedNode:GetComponent("StaticModel")
        if sm then
            bbSize = sm.worldBoundingBox.size
        elseif ctx.selectedNode:GetNumChildren(false) > 0 then
            -- Fence: 从第一个 FenceSeg 获取
            for i = 0, ctx.selectedNode:GetNumChildren(false) - 1 do
                local seg = ctx.selectedNode:GetChild(i)
                local segModel = seg:GetComponent("StaticModel")
                if segModel then
                    bbSize = segModel.worldBoundingBox.size
                    break
                end
            end
        end

        modelClipboard_ = {
            modelKey      = modelKey,
            modelScale    = currentScale,
            modelRotation = modelRot,
            obsScale      = Vector3(bbSize.x, bbSize.y, bbSize.z),
            noCollision   = true,  -- 复制的结构物段默认无碰撞（避免与原碰撞体冲突）
        }

        print(string.format("[MapEditor] 已复制结构物: %s (缩放 %.2f)", modelKey, currentScale))
    else
        -- 障碍物/装饰物
        local entry = GetSelectedEntry()
        if not entry or not entry.modelKey then
            print("[MapEditor] 当前选中模型无法复制（缺少 modelKey）")
            return
        end

        -- 从 Visual 节点读取实际旋转
        local modelRot = nil
        local visualNode = ctx.selectedNode:GetChild("Visual")
        if visualNode then
            local angle = visualNode.rotation:EulerAngles()
            if math.abs(angle.x) > 0.1 or math.abs(angle.y) > 0.1 or math.abs(angle.z) > 0.1 then
                modelRot = Quaternion(angle.x, angle.y, angle.z)
            end
        end

        -- 从 Visual 节点读取实际缩放
        local currentScale = entry.modelScale or 1.0
        if visualNode then
            currentScale = visualNode.scale.x  -- 统一缩放
        end

        modelClipboard_ = {
            modelKey      = entry.modelKey,
            modelScale    = currentScale,
            modelRotation = modelRot,
            obsScale      = Vector3(entry.scale.x, entry.scale.y, entry.scale.z),
            noCollision   = entry.noCollision or false,
        }

        print(string.format("[MapEditor] 已复制模型: %s (缩放 %.2f)", entry.modelKey, currentScale))
    end

    -- 自动进入虚影粘贴模式
    EnterModelPasteMode()
end

--- 退出虚影粘贴模式
ExitModelPasteMode = function()
    if ghostNode_ then
        ghostNode_:Remove()
        ghostNode_ = nil
    end
    pasteMode_ = false
    CloseStatusHint()
    print("[MapEditor] 退出粘贴模式")
end

--- 进入虚影粘贴模式：创建半透明虚影跟随鼠标
EnterModelPasteMode = function()
    if not modelClipboard_ or not ctx.scene then return end

    -- 先退出之前可能存在的粘贴模式
    ExitModelPasteMode()

    -- 取消当前选中
    if ctx.selectedNode then
        DeselectNode()
    end

    -- 创建虚影节点（使用 CreateObstacle 然后替换材质为半透明）
    local ghostObs = {
        pos           = Vector3(0, 0, 0),
        scale         = Vector3(modelClipboard_.obsScale.x, modelClipboard_.obsScale.y, modelClipboard_.obsScale.z),
        name          = "__ghost_preview__",
        modelKey      = modelClipboard_.modelKey,
        modelScale    = modelClipboard_.modelScale,
        modelRotation = modelClipboard_.modelRotation,
        noCollision   = true,
    }

    Shared.CreateObstacle(ctx.scene, ghostObs, false)
    ghostNode_ = ctx.scene:GetChild("__ghost_preview__")

    if not ghostNode_ then
        print("[MapEditor] 创建虚影节点失败")
        return
    end

    -- 替换 Visual 子节点的材质为半透明绿色
    local visualNode = ghostNode_:GetChild("Visual")
    if visualNode then
        local model = visualNode:GetComponent("StaticModel")
        if model then
            local ghostMat = Material:new()
            ghostMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            ghostMat:SetShaderParameter("MatDiffColor", Variant(Color(0.2, 0.9, 0.3, 0.35)))
            ghostMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.1, 0.4, 0.15, 1.0)))
            -- 替换所有材质槽
            for slot = 0, model.numGeometries - 1 do
                model:SetMaterial(slot, ghostMat)
            end
        end
    end

    pasteMode_ = true
    ctx.state = STATE_IDLE
    CloseAllUI()
    ShowStatusHint("左键点击放置模型 | 右键或 Esc 取消")
    print(string.format("[MapEditor] 进入粘贴模式: %s", modelClipboard_.modelKey))
end

--- 每帧更新虚影位置（跟随鼠标）
local function UpdateGhostPosition()
    if not ghostNode_ then return end

    local hitPos = RaycastGround()
    if not hitPos then return end

    local snappedX = math.floor(hitPos.x / SNAP_SIZE + 0.5) * SNAP_SIZE
    local snappedZ = math.floor(hitPos.z / SNAP_SIZE + 0.5) * SNAP_SIZE
    local terrainY = Shared.GetTerrainHeightAt(snappedX, snappedZ)
    local yOff = (modelClipboard_.obsScale.y / 2) + terrainY

    ghostNode_.position = Vector3(snappedX, yOff, snappedZ)

    -- 重新对齐 Visual 底部
    local visualNode = ghostNode_:GetChild("Visual")
    if visualNode then
        local model = visualNode:GetComponent("StaticModel")
        if model then
            visualNode.position = Vector3(0, 0, 0)
            local worldBB = model.worldBoundingBox
            local worldMinY = worldBB.min.y
            visualNode.position = Vector3(
                0,
                (ghostNode_.position.y - modelClipboard_.obsScale.y / 2) - worldMinY,
                0
            )
        end
    end
end

--- 在虚影位置放置真实模型
local function PlaceGhostModel()
    if not ghostNode_ or not modelClipboard_ then return end

    local pos = ghostNode_.position
    local snappedX = pos.x
    local snappedZ = pos.z

    -- 移除虚影
    ghostNode_:Remove()
    ghostNode_ = nil

    -- 生成唯一名称
    ctx.addCounter = ctx.addCounter + 1
    local uniqueName = "Added_" .. modelClipboard_.modelKey .. "_" .. ctx.addCounter

    -- 构造障碍物数据
    local newObs = {
        pos           = Vector3(snappedX, 0, snappedZ),
        scale         = Vector3(modelClipboard_.obsScale.x, modelClipboard_.obsScale.y, modelClipboard_.obsScale.z),
        name          = uniqueName,
        modelKey      = modelClipboard_.modelKey,
        modelScale    = modelClipboard_.modelScale,
        modelRotation = modelClipboard_.modelRotation,
        noCollision   = modelClipboard_.noCollision,
    }

    -- 添加到配置并创建场景节点
    table.insert(Config.Level1.Obstacles, newObs)
    Shared.CreateObstacle(ctx.scene, newObs, false)
    Shared.MarkObstacleCollidersDirty()

    -- 网络同步
    SendObsEdit("add", uniqueName, {
        posX       = snappedX,
        posZ       = snappedZ,
        modelKey   = modelClipboard_.modelKey,
        modelScale = modelClipboard_.modelScale,
        scaleX     = newObs.scale.x,
        scaleY     = newObs.scale.y,
        scaleZ     = newObs.scale.z,
    })

    print(string.format("[MapEditor] 已放置模型: %s 在 (%.1f, %.1f)", uniqueName, snappedX, snappedZ))

    -- 放置后保持粘贴模式（可继续放置多个副本）
    EnterModelPasteMode()
end

--- 每帧更新
---@param dt number
function MapEditor.Update(dt)
    if not ctx.active then return end

    -- ==================== 粘贴模式处理（最高优先级） ====================
    if pasteMode_ then
        -- 每帧更新虚影位置
        UpdateGhostPosition()

        -- 左键点击放置（不在 UI 上方时）
        if input:GetMouseButtonPress(MOUSEB_LEFT) and not UI.IsPointerOverUI() then
            PlaceGhostModel()
            return
        end

        -- Esc 或 右键取消粘贴模式
        if input:GetKeyPress(KEY_ESCAPE) or input:GetMouseButtonPress(MOUSEB_RIGHT) then
            ExitModelPasteMode()
            ShowAddButton()
            return
        end

        -- 粘贴模式下屏蔽其他输入
        return
    end

    -- ==================== 正常模式 ====================

    -- 左键双击计时
    if ctx.leftClickTimer > 0 then
        ctx.leftClickTimer = ctx.leftClickTimer - dt
        if ctx.leftClickTimer <= 0 then
            ctx.leftClickCount = 0
        end
    end

    -- 只在 ctx.state == IDLE 或 SELECTED 时检测左键双击
    if ctx.state == STATE_IDLE or ctx.state == STATE_SELECTED then
        DetectLeftDoubleClick()
    end

    -- 根据状态处理输入
    if ctx.state == STATE_MOVING then
        HandleMoveInput(dt)
    elseif ctx.state == STATE_SCALING then
        HandleScaleInput(dt)
    end

    -- Ctrl+C 复制模型并自动进入虚影粘贴模式
    if input:GetKeyDown(KEY_CTRL) then
        if input:GetKeyPress(KEY_C) and ctx.state == STATE_SELECTED then
            CopySelectedModel()
            return
        end
        -- Ctrl+V：如果剪贴板有数据，重新进入粘贴模式
        if input:GetKeyPress(KEY_V) and (ctx.state == STATE_IDLE or ctx.state == STATE_SELECTED) then
            if modelClipboard_ then
                EnterModelPasteMode()
            else
                print("[MapEditor] 剪贴板为空，请先 Ctrl+C 复制模型")
            end
            return
        end
    end

    -- Esc 键：取消当前操作或取消选中
    if input:GetKeyPress(KEY_ESCAPE) then
        if ctx.state == STATE_MOVING then
            CancelMove()
        elseif ctx.state == STATE_ROTATING then
            CancelRotate()
        elseif ctx.state == STATE_SCALING then
            CancelScale()
        elseif ctx.state == STATE_ADDING then
            CloseAddPanel()
            ctx.state = STATE_IDLE
            ShowAddButton()
        elseif ctx.state == STATE_SELECTED then
            DeselectNode()
        end
    end

    -- Enter 键：确认当前操作
    if input:GetKeyPress(KEY_RETURN) then
        if ctx.state == STATE_MOVING then
            ConfirmMove()
        elseif ctx.state == STATE_ROTATING then
            ConfirmRotate()
        elseif ctx.state == STATE_SCALING then
            ConfirmScale()
        end
    end

    -- 每帧更新菜单位置（跟随模型）
    UpdateMenuPosition()
end

--- 在 PostRenderUpdate 中绘制选中高亮
function MapEditor.DrawGizmos()
    if not ctx.active then return end
    if not ctx.scene then return end

    local debugRenderer = ctx.scene:GetComponent("DebugRenderer")
    if not debugRenderer then return end

    -- 绘制虚影包围盒（粘贴模式）
    if pasteMode_ and ghostNode_ then
        local ghostVisual = ghostNode_:GetChild("Visual")
        local ghostModel = ghostVisual and ghostVisual:GetComponent("StaticModel")
        if ghostModel then
            debugRenderer:AddBoundingBox(ghostModel.worldBoundingBox, GHOST_COLOR, false)
        end
    end

    -- 绘制选中模型包围盒
    if not ctx.selectedNode then return end

    local color = (ctx.state == STATE_MOVING) and MOVING_COLOR or HIGHLIGHT_COLOR

    -- 结构段 / 障碍物 / 通用：统一查找 StaticModel
    local model = nil
    if ctx.selectedType == "structure" then
        -- 单段节点本身有 StaticModel
        model = ctx.selectedNode:GetComponent("StaticModel")
    else
        -- 障碍物优先查 Visual 子节点
        local visualNode = ctx.selectedNode:GetChild("Visual")
        if visualNode then
            model = visualNode:GetComponent("StaticModel")
        else
            model = ctx.selectedNode:GetComponent("StaticModel")
        end
    end

    if model then
        debugRenderer:AddBoundingBox(model.worldBoundingBox, color, false)
    end
end

--- 保存当前地图到日志
function MapEditor.SaveToLog()
    local L = Config.Level1
    local output = "-- ============================================================\n"
    output = output .. "-- 地图编辑器导出 — " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n"
    output = output .. "-- 可直接粘贴到 GameConfig.lua 的 Level1.Obstacles 中\n"
    output = output .. "-- ============================================================\n"
    output = output .. "Obstacles = {\n"

    for i, obs in ipairs(L.Obstacles) do
        -- 从场景中读取实际位置（编辑后的）
        local node = ctx.scene:GetChild(obs.name)
        local pos = obs.pos
        local ms = obs.modelScale or 1.0

        if node then
            pos = Vector3(node.position.x, 0, node.position.z)
            local visual = node:GetChild("Visual")
            if visual then
                ms = visual.scale.x
            end
        end

        local line = string.format(
            '    { pos = Vector3(%g, 0, %g), scale = Vector3(%g, %g, %g), name = "%s"',
            pos.x, pos.z,
            obs.scale.x, obs.scale.y, obs.scale.z,
            obs.name
        )

        if obs.modelKey then
            line = line .. string.format(', modelKey = "%s"', obs.modelKey)
        end

        line = line .. string.format(', modelScale = %g', ms)

        -- 读取旋转
        if node then
            local visual = node:GetChild("Visual")
            if visual then
                local angle = visual.rotation:EulerAngles()
                if math.abs(angle.x) > 0.1 or math.abs(angle.y) > 0.1 or math.abs(angle.z) > 0.1 then
                    line = line .. string.format(', modelRotation = Quaternion(%g, %g, %g)', angle.x, angle.y, angle.z)
                end
            end
        elseif obs.modelRotation then
            local angle = obs.modelRotation:EulerAngles()
            if math.abs(angle.x) > 0.1 or math.abs(angle.y) > 0.1 or math.abs(angle.z) > 0.1 then
                line = line .. string.format(', modelRotation = Quaternion(%g, %g, %g)', angle.x, angle.y, angle.z)
            end
        end

        if obs.noCollision then
            line = line .. ', noCollision = true'
        end

        line = line .. ' },'
        output = output .. line .. "\n"
    end

    output = output .. "}\n\n"

    -- 导出结构物（围墙/围栏）位置信息
    if #ctx.structureList > 0 then
        output = output .. "-- 结构物（围墙/围栏）当前位置\n"
        output = output .. "-- 注意：这些位置需要手动更新到 Shared.lua 的创建代码中\n"
        for i, struct in ipairs(ctx.structureList) do
            local node = struct.node
            if node then
                local pos = node.position
                local rot = node.rotation:EulerAngles()
                local scl = node.scale
                output = output .. string.format(
                    '-- %s: pos=(%.2f, %.2f, %.2f), rot=(%.1f, %.1f, %.1f), scale=(%.2f, %.2f, %.2f)\n',
                    struct.label,
                    pos.x, pos.y, pos.z,
                    rot.x, rot.y, rot.z,
                    scl.x, scl.y, scl.z
                )
            end
        end
    end

    print("=== MAP EDITOR EXPORT START ===")
    print(output)
    print("=== MAP EDITOR EXPORT END ===")
end

-- ============================================================================
-- 世界坐标投影到屏幕坐标
-- ============================================================================

--- 将世界坐标投影到屏幕像素坐标
---@param worldPos Vector3
---@return number|nil x, number|nil y  屏幕像素坐标，不可见时返回 nil
WorldToScreen = function(worldPos)
    if not ctx.cameraNode then return nil, nil end
    local camera = ctx.cameraNode:GetComponent("Camera")
    if not camera then return nil, nil end

    -- 先检查点是否在相机前方
    local camDir = ctx.cameraNode:GetDirection()
    local toTarget = worldPos - ctx.cameraNode:GetWorldPosition()
    if camDir:DotProduct(toTarget) <= 0 then return nil, nil end

    -- WorldToScreenPoint 返回 Vector2 (归一化 0~1)
    local screenPos = camera:WorldToScreenPoint(worldPos)
    if not screenPos then return nil, nil end

    local physW = graphics:GetWidth()
    local physH = graphics:GetHeight()
    local dpr = graphics:GetDPR()
    local logicalW = physW / dpr
    local logicalH = physH / dpr

    return screenPos.x * logicalW, screenPos.y * logicalH
end

--- 合并节点所有子节点的世界包围盒（用于围墙/围栏等多段结构）
---@param node Node
---@return BoundingBox|nil
MergeChildBoundingBoxes = function(node)
    local minX, minY, minZ =  1e9,  1e9,  1e9
    local maxX, maxY, maxZ = -1e9, -1e9, -1e9
    local found = false

    for i = 0, node:GetNumChildren(false) - 1 do
        local child = node:GetChild(i)
        local model = child:GetComponent("StaticModel")
        if model then
            local bb = model.worldBoundingBox
            minX = math.min(minX, bb.min.x)
            minY = math.min(minY, bb.min.y)
            minZ = math.min(minZ, bb.min.z)
            maxX = math.max(maxX, bb.max.x)
            maxY = math.max(maxY, bb.max.y)
            maxZ = math.max(maxZ, bb.max.z)
            found = true
        end
    end

    if found then
        return BoundingBox(Vector3(minX, minY, minZ), Vector3(maxX, maxY, maxZ))
    end
    return nil
end

--- 获取选中模型的顶部世界坐标
---@return Vector3|nil
GetSelectedTopPos = function()
    if not ctx.selectedNode then return nil end

    -- 结构段：直接使用段节点自身的 StaticModel
    if ctx.selectedType == "structure" then
        local model = ctx.selectedNode:GetComponent("StaticModel")
        if model then
            local bb = model.worldBoundingBox
            return Vector3(
                (bb.min.x + bb.max.x) / 2,
                bb.max.y + 0.3,
                (bb.min.z + bb.max.z) / 2
            )
        end
        local wp = ctx.selectedNode.worldPosition
        return Vector3(wp.x, wp.y + 1, wp.z)
    end

    -- 障碍物：使用 Visual 子节点
    local visualNode = ctx.selectedNode:GetChild("Visual")
    local model = visualNode and visualNode:GetComponent("StaticModel") or ctx.selectedNode:GetComponent("StaticModel")
    if model then
        local bb = model.worldBoundingBox
        return Vector3(
            (bb.min.x + bb.max.x) / 2,
            bb.max.y + 0.3,
            (bb.min.z + bb.max.z) / 2
        )
    end

    return Vector3(ctx.selectedNode.position.x, ctx.selectedNode.position.y + 2, ctx.selectedNode.position.z)
end

-- ============================================================================
-- 左键双击检测
-- ============================================================================

local leftWasDown_ = false

DetectLeftDoubleClick = function()
    -- UI 上方不检测
    if UI.IsPointerOverUI() then return end

    local leftDown = input:GetMouseButtonDown(MOUSEB_LEFT)

    -- 检测左键释放瞬间
    if leftWasDown_ and not leftDown then
        if not ctx.leftWasDrag then
            ctx.leftClickCount = ctx.leftClickCount + 1
            ctx.leftClickTimer = DOUBLE_CLICK_TIME

            if ctx.leftClickCount >= 2 then
                ctx.leftClickCount = 0
                ctx.leftClickTimer = 0
                TrySelectAtMouse()
            end
        else
            ctx.leftClickCount = 0
            ctx.leftClickTimer = 0
        end
    end

    -- 检测左键按下瞬间
    if leftDown and not leftWasDown_ then
        ctx.leftDownPos = { x = input.mousePosition.x, y = input.mousePosition.y }
        ctx.leftWasDrag = false
    end

    -- 追踪按住期间的移动
    if leftDown and ctx.leftDownPos then
        local mx = input.mousePosition.x
        local my = input.mousePosition.y
        local dx = mx - ctx.leftDownPos.x
        local dy = my - ctx.leftDownPos.y
        if math.abs(dx) > CLICK_MOVE_THRESH or math.abs(dy) > CLICK_MOVE_THRESH then
            ctx.leftWasDrag = true
        end
    end

    leftWasDown_ = leftDown
end

-- ============================================================================
-- 选中逻辑
-- ============================================================================

TrySelectAtMouse = function()
    if not ctx.cameraNode or not ctx.scene then return end

    local camera = ctx.cameraNode:GetComponent("Camera")
    if not camera then return end

    local mousePos = input.mousePosition
    local screenW = graphics:GetWidth()
    local screenH = graphics:GetHeight()
    if screenW <= 0 or screenH <= 0 then return end

    local nx = mousePos.x / screenW
    local ny = mousePos.y / screenH

    local ray = camera:GetScreenRay(nx, ny)

    local octree = ctx.scene:GetComponent("Octree")
    if not octree then return end

    local result = octree:RaycastSingle(ray, RAY_TRIANGLE, 200.0, DRAWABLE_GEOMETRY)
    if not result or not result.drawable then
        if ctx.state == STATE_SELECTED then
            DeselectNode()
        end
        return
    end

    local hitNode = result.drawable:GetNode()
    local rootNode, idx, nodeType = FindSelectableRoot(hitNode)

    if rootNode and idx and nodeType then
        SelectNode(rootNode, idx, nodeType)
    else
        if ctx.state == STATE_SELECTED then
            DeselectNode()
        end
    end
end

--- 从节点向上查找可选中的根节点（障碍物或结构物）
---@param node Node
---@return Node|nil node
---@return number|nil index
---@return string|nil type "obstacle" or "structure"
FindSelectableRoot = function(node)
    local current = node
    for _ = 1, 5 do
        if not current then break end
        local name = current.name

        -- 检查障碍物
        for i, obs in ipairs(Config.Level1.Obstacles) do
            if obs.name == name then
                return current, i, "obstacle"
            end
        end

        -- 检查外围装饰物
        for i, dec in ipairs(Config.Exterior.Decorations) do
            if dec.name and dec.name == name then
                return current, i, "decoration"
            end
        end

        -- 检查结构物（围墙/围栏）
        for i, struct in ipairs(ctx.structureList) do
            if current == struct.node then
                return current, i, "structure"
            end
        end

        current = current:GetParent()
    end
    return nil, nil, nil
end

SelectNode = function(node, idx, nodeType)
    ctx.selectedNode = node
    ctx.selectedType = nodeType
    if nodeType == "obstacle" or nodeType == "decoration" then
        ctx.selectedObsIndex = idx
        ctx.selectedStructIndex = nil
    else
        ctx.selectedStructIndex = idx
        ctx.selectedObsIndex = nil
    end
    ctx.state = STATE_SELECTED

    print(string.format("[MapEditor] 选中: %s (类型 %s, 索引 %d)", GetSelectedName(), nodeType, idx))
    ShowMenu()
end

DeselectNode = function()
    ctx.selectedNode = nil
    ctx.selectedObsIndex = nil
    ctx.selectedType = nil
    ctx.selectedStructIndex = nil
    ctx.state = STATE_IDLE
    CloseAllUI()
    print("[MapEditor] 取消选中")
end

-- ============================================================================
-- 关闭所有 UI
-- ============================================================================

CloseAllUI = function()
    CloseMenu()
    CloseRotatePanel()
    CloseScalePanel()
    CloseStatusHint()
    CloseAddPanel()
end

-- ============================================================================
-- 菜单 UI（跟随模型位置）
-- ============================================================================

ShowMenu = function()
    CloseAllUI()

    local root = GetUIRoot()
    if not ctx.selectedNode or not root then return end

    -- 防御性清理：移除可能残留的地形编辑菜单
    local terrainMenu = root:FindById("terrainMenu")
    if terrainMenu then
        terrainMenu:Remove()
        print("[MapEditor] ShowMenu: 移除残留的地形菜单")
    end

    local displayName = GetSelectedName()
    local T = AstroonTheme.Tokens

    ctx.menuPanel = UI.Panel {
        id = "editorMenu",
        position = "absolute",
        top = 0,
        left = 0,
        translateX = -1,   -- 水平居中
        translateY = -1,   -- 完全在锚点上方
        width = 280,
        padding = 10,
        backgroundColor = { T.surface[1], T.surface[2], T.surface[3], 230 },
        borderRadius = 8,
        borderWidth = 1,
        borderColor = T.border,
        boxShadow = {
            { x = 0, y = 4, blur = 12, spread = 0, color = T.shadow },
        },
        alignItems = "center",
        gap = 6,
        children = {
            UI.Label {
                text = "编辑: " .. displayName,
                fontSize = 14,
                fontWeight = "bold",
                fontColor = T.text,
            },
            UI.Panel {
                flexDirection = "row",
                gap = 6,
                children = {
                    UI.Button {
                        text = "移动",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 12, paddingRight = 12,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 33, 69, 138, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() StartMove() end,
                    },
                    UI.Button {
                        text = "旋转",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 12, paddingRight = 12,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 33, 69, 138, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() StartRotate() end,
                    },
                    UI.Button {
                        text = "缩放",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 12, paddingRight = 12,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 33, 69, 138, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() StartScale() end,
                    },
                    UI.Button {
                        text = "删除",
                        fontSize = 13,
                        fontWeight = "bold",
                        borderRadius = 4,
                        paddingLeft = 12, paddingRight = 12,
                        paddingTop = 6, paddingBottom = 6,
                        backgroundColor = { 160, 30, 30, 255 },
                        hoverBackgroundColor = { 200, 40, 40, 255 },
                        fontColor = { 255, 255, 255, 255 },
                        onClick = function() DeleteSelected() end,
                    },
                },
            },
            UI.Label {
                text = "右键双击选择其他模型 | Esc 取消选中",
                fontSize = 11,
                fontColor = T.textMuted,
                textAlign = "center",
            },
        },
    }

    root:AddChild(ctx.menuPanel)

    -- 立即更新位置
    UpdateMenuPosition()
    print(string.format("[MapEditor] ShowMenu: 编辑菜单已创建 - %s", displayName))
end

CloseMenu = function()
    if ctx.menuPanel then
        ctx.menuPanel:Remove()
        ctx.menuPanel = nil
    end
end

--- 每帧更新菜单面板位置（跟随模型的世界坐标投影）
UpdateMenuPosition = function()
    local panel = ctx.menuPanel or ctx.rotatePanel or ctx.scalePanel
    if not panel or not ctx.selectedNode then return end

    local topPos = GetSelectedTopPos()
    if not topPos then return end

    local sx, sy = WorldToScreen(topPos)
    if sx and sy then
        -- 获取逻辑屏幕尺寸
        local dpr = graphics:GetDPR()
        local logicalW = graphics:GetWidth() / dpr
        local logicalH = graphics:GetHeight() / dpr

        -- 面板使用 translateX=-1, translateY=-1，即向左偏移 100% 宽度、向上偏移 100% 高度
        -- 估算面板尺寸（menuPanel=280, rotatePanel=340, scalePanel=320）
        local panelW = 340  -- 取最大值以确保所有面板都可见
        local panelH = 200  -- 面板高度估算

        -- 夹紧 sx：确保面板左边缘不超出屏幕左边（sx - panelW >= 0）
        sx = math.max(sx, panelW)
        -- 夹紧 sx：确保面板右边缘不超出屏幕右边
        sx = math.min(sx, logicalW)

        -- 夹紧 sy：确保面板上边缘不超出屏幕上方（sy - panelH >= 0）
        sy = math.max(sy, panelH)
        -- 夹紧 sy：确保面板不超出屏幕下方
        sy = math.min(sy, logicalH)

        panel.left = sx
        panel.top = sy
    end
end
-- ============================================================================
-- 初始化子模块（此处所有 local function 均已定义）
-- ============================================================================

MapEditorOps.Init(ctx, {
    GetSelectedEntry   = GetSelectedEntry,
    GetSelectedName    = GetSelectedName,
    GetUIRoot          = GetUIRoot,
    CloseAllUI         = CloseAllUI,
    ShowMenu           = ShowMenu,
    UpdateMenuPosition = UpdateMenuPosition,
    SendObsEdit        = SendObsEdit,
}, {
    STATE_IDLE     = STATE_IDLE,
    STATE_SELECTED = STATE_SELECTED,
    STATE_MOVING   = STATE_MOVING,
    STATE_ROTATING = STATE_ROTATING,
    STATE_SCALING  = STATE_SCALING,
    SNAP_SIZE      = SNAP_SIZE,
    PRESET_ANGLES  = PRESET_ANGLES,
    EVENTS         = EVENTS,
})

-- 将 Ops 导出的函数赋给 forward declaration 变量（宿主代码通过这些变量调用）
DeleteSelected   = MapEditorOps.DeleteSelected
StartMove        = MapEditorOps.StartMove
HandleMoveInput  = MapEditorOps.HandleMoveInput
ConfirmMove      = MapEditorOps.ConfirmMove
CancelMove       = MapEditorOps.CancelMove
StartRotate      = MapEditorOps.StartRotate
ConfirmRotate    = MapEditorOps.ConfirmRotate
CancelRotate     = MapEditorOps.CancelRotate
StartScale       = MapEditorOps.StartScale
HandleScaleInput = MapEditorOps.HandleScaleInput
ConfirmScale     = MapEditorOps.ConfirmScale
CancelScale      = MapEditorOps.CancelScale
CloseRotatePanel = MapEditorOps.CloseRotatePanel
CloseScalePanel  = MapEditorOps.CloseScalePanel
ShowStatusHint   = MapEditorOps.ShowStatusHint
CloseStatusHint  = MapEditorOps.CloseStatusHint
RaycastGround    = MapEditorOps.RaycastGround
RealignVisual    = MapEditorOps.RealignVisual

MapEditorAddModel.Init(ctx, {
    GetUIRoot   = GetUIRoot,
    CloseAllUI  = CloseAllUI,
    SendObsEdit = SendObsEdit,
}, {
    STATE_IDLE   = STATE_IDLE,
    STATE_ADDING = STATE_ADDING,
    SNAP_SIZE    = SNAP_SIZE,
})

-- 将 AddModel 导出的函数赋给 forward declaration 变量
ShowAddButton  = MapEditorAddModel.ShowAddButton
CloseAddButton = MapEditorAddModel.CloseAddButton
ShowAddPanel   = MapEditorAddModel.ShowAddPanel
CloseAddPanel  = MapEditorAddModel.CloseAddPanel
ConfirmAdd     = MapEditorAddModel.ConfirmAdd

return MapEditor
