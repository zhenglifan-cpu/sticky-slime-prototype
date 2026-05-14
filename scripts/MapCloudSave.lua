-- ============================================================================
-- MapCloudSave.lua — 地图云存档模块
-- 职责：序列化/反序列化地图数据（障碍物 + 装饰物 + 地形），
--       云端读写（clientCloud），场景重建
-- ============================================================================

local MapCloudSave = {}

local Config = require("config.GameConfig")
local Shared = require("network.Shared")
local TerrainEditor = require("TerrainEditor")

-- 云存档键名（3 个栏位）
local SLOT_KEYS = { "map_slot_1", "map_slot_2", "map_slot_3" }

-- ============================================================================
-- 本地文件 Fallback（clientCloud 不可用时使用）
-- ============================================================================
local SAVE_DIR = "map_saves"
local LOCAL_FILES = {
    [SLOT_KEYS[1]] = SAVE_DIR .. "/slot_1.json",
    [SLOT_KEYS[2]] = SAVE_DIR .. "/slot_2.json",
    [SLOT_KEYS[3]] = SAVE_DIR .. "/slot_3.json",
}

--- 确保存档目录存在
local function EnsureSaveDir()
    fileSystem:CreateDir(SAVE_DIR)
end

--- 本地写入
---@param key string
---@param value string
---@return boolean success
---@return string|nil errMsg
local function LocalWrite(key, value)
    EnsureSaveDir()
    local path = LOCAL_FILES[key]
    if not path then return false, "未知键: " .. tostring(key) end

    local file = File(path, FILE_WRITE)
    if not file:IsOpen() then
        return false, "无法打开文件: " .. path
    end
    file:WriteString(value)
    file:Close()
    print(string.format("[MapCloudSave] 本地写入成功: %s (%d 字节)", path, #value))
    return true
end

--- 本地读取
---@param key string
---@return boolean exists
---@return string|nil content
local function LocalRead(key)
    local path = LOCAL_FILES[key]
    if not path then return false, nil end

    if not fileSystem:FileExists(path) then
        return false, nil
    end

    local file = File(path, FILE_READ)
    if not file:IsOpen() then
        return false, nil
    end
    local content = file:ReadString()
    file:Close()
    if content and content ~= "" then
        return true, content
    end
    return false, nil
end

--- 本地删除（写入空内容模拟删除）
---@param key string
---@return boolean
local function LocalDelete(key)
    EnsureSaveDir()
    local path = LOCAL_FILES[key]
    if not path then return false end

    -- 写入空字符串表示已删除
    local file = File(path, FILE_WRITE)
    if not file:IsOpen() then return false end
    file:WriteString("")
    file:Close()
    print(string.format("[MapCloudSave] 本地已删除: %s", path))
    return true
end

--- 判断是否使用云端
---@return boolean
local function UseCloud()
    return clientCloud ~= nil
end

-- ============================================================================
-- 序列化：直接从 Config 采集当前地图状态
-- 编辑器（MapEditorOps）的移动/旋转/缩放/删除/新增操作
-- 都会同步更新 Config.Level1.Obstacles / Config.Exterior.Decorations，
-- 因此直接从 Config 读取即可，无需再从场景节点二次采集。
-- ============================================================================

--- 采集当前障碍物数据（直接从 Config 读取，包含所有编辑后的状态）
---@return table
local function CollectObstacles()
    local result = {}
    for i, obs in ipairs(Config.Level1.Obstacles) do
        local entry = {
            name = obs.name,
            modelKey = obs.modelKey,
            noCollision = obs.noCollision or nil,
            -- 碰撞尺寸
            sx = obs.scale.x,
            sy = obs.scale.y,
            sz = obs.scale.z,
            -- 位置（编辑器 ConfirmMove 已同步到 obs.pos）
            px = obs.pos.x,
            pz = obs.pos.z,
            -- 模型缩放（编辑器 ConfirmScale 已同步到 obs.modelScale）
            ms = obs.modelScale or 1.0,
        }

        -- 模型旋转（编辑器 ConfirmRotate 已同步到 obs.modelRotation）
        if obs.modelRotation then
            local angle = obs.modelRotation:EulerAngles()
            entry.rx = angle.x
            entry.ry = angle.y
            entry.rz = angle.z
        end

        result[#result + 1] = entry
    end
    return result
end

--- 采集当前装饰物数据（直接从 Config 读取）
---@return table
local function CollectDecorations()
    local result = {}
    for i, dec in ipairs(Config.Exterior.Decorations) do
        local entry = {
            name = dec.name,
            modelKey = dec.modelKey,
            -- 碰撞尺寸
            sx = dec.scale.x,
            sy = dec.scale.y,
            sz = dec.scale.z,
            -- 位置
            px = dec.pos.x,
            pz = dec.pos.z,
            -- 模型缩放
            ms = dec.modelScale or 1.0,
        }

        -- 装饰物旋转
        if dec.modelRotation then
            local angle = dec.modelRotation:EulerAngles()
            entry.rx = angle.x
            entry.ry = angle.y
            entry.rz = angle.z
        end

        result[#result + 1] = entry
    end
    return result
end

--- 将当前地图完整序列化为 JSON 字符串
--- （数据直接从 Config 采集，不再依赖 scene 参数）
---@param scene Scene|nil  保留参数兼容旧调用，但实际不再使用
---@return string
function MapCloudSave.Serialize(scene)
    local terrainData, heightData, smoothData = TerrainEditor.GetGridData()
    local data = {
        v = 3,  -- 数据版本（v3 per-cell 平滑数据）
        ts = os.time(),
        obstacles = CollectObstacles(),
        decorations = CollectDecorations(),
        terrain = terrainData,
        heights = heightData,       -- 高度网格数据
        smoothGrid = smoothData,    -- per-cell 平滑数据
    }
    return cjson.encode(data)
end

-- ============================================================================
-- 反序列化 + 场景重建
-- ============================================================================

--- 从 JSON 字符串恢复地图
---@param scene Scene
---@param jsonStr string
---@return boolean success
---@return string|nil errorMsg
function MapCloudSave.Deserialize(scene, jsonStr)
    local ok, data = pcall(cjson.decode, jsonStr)
    if not ok or type(data) ~= "table" then
        return false, "JSON 解析失败"
    end

    -- 1. 恢复障碍物
    if data.obstacles then
        -- 先移除场景中现有的障碍物节点
        for _, obs in ipairs(Config.Level1.Obstacles) do
            local node = scene:GetChild(obs.name)
            if node then node:Remove() end
        end

        -- 更新 Config 并重建
        local newObstacles = {}
        for _, entry in ipairs(data.obstacles) do
            local obs = {
                name = entry.name,
                modelKey = entry.modelKey,
                noCollision = entry.noCollision or false,
                pos = Vector3(entry.px, 0, entry.pz),
                scale = Vector3(entry.sx, entry.sy, entry.sz),
                modelScale = entry.ms,
            }
            if entry.rx or entry.ry or entry.rz then
                obs.modelRotation = Quaternion(entry.rx or 0, entry.ry or 0, entry.rz or 0)
            end
            newObstacles[#newObstacles + 1] = obs
        end

        -- 替换 Config 中的障碍物列表
        Config.Level1.Obstacles = newObstacles

        -- 在场景中重建
        for _, obs in ipairs(newObstacles) do
            Shared.CreateObstacle(scene, obs, false)
        end
    end

    -- 2. 恢复装饰物
    if data.decorations then
        -- 先移除场景中现有的装饰物节点
        for _, dec in ipairs(Config.Exterior.Decorations) do
            local node = scene:GetChild(dec.name)
            if node then node:Remove() end
        end

        -- 更新 Config 并重建
        local newDecorations = {}
        for _, entry in ipairs(data.decorations) do
            local dec = {
                name = entry.name,
                modelKey = entry.modelKey,
                pos = Vector3(entry.px, 0, entry.pz),
                scale = Vector3(entry.sx, entry.sy, entry.sz),
                modelScale = entry.ms,
            }
            -- 恢复旋转信息
            if entry.rx or entry.ry or entry.rz then
                dec.modelRotation = Quaternion(entry.rx or 0, entry.ry or 0, entry.rz or 0)
            end
            newDecorations[#newDecorations + 1] = dec
        end

        -- 替换 Config 中的装饰物列表
        Config.Exterior.Decorations = newDecorations

        -- 在场景中重建（复用 CreateExterior 中装饰物创建的逻辑）
        for _, dec in ipairs(newDecorations) do
            local modelInfo = dec.modelKey and Config.Models[dec.modelKey] or nil
            if modelInfo then
                local node = scene:CreateChild(dec.name or ("Ext_" .. dec.modelKey), LOCAL)
                node.position = Vector3(dec.pos.x, 0, dec.pos.z)

                local visualNode = node:CreateChild("Visual", LOCAL)
                local ms = dec.modelScale or 1.0
                visualNode.scale = Vector3(ms, ms, ms)

                -- 恢复旋转
                if dec.modelRotation then
                    visualNode.rotation = dec.modelRotation
                end

                local m = visualNode:CreateComponent("StaticModel", LOCAL)
                m:SetModel(cache:GetResource("Model", modelInfo.model))
                m:SetMaterial(cache:GetResource("Material", modelInfo.material))
                m.castShadows = true

                -- 底部对齐地面
                local worldBB = m.worldBoundingBox
                local worldMinY = worldBB.min.y
                visualNode.position = Vector3(0, -worldMinY, 0)
            end
        end
    end

    -- 3. 恢复地形（包括高度数据和 per-cell 平滑数据）
    if data.terrain then
        -- 兼容 v2 旧数据：data.smooth 是单一数字，转为 smoothGrid 无数据（使用默认 0.5）
        local smoothData = data.smoothGrid or nil
        TerrainEditor.ReplaceGrid(data.terrain, data.heights, smoothData)
    end

    -- 4. 标记碰撞体需要重建
    Shared.MarkObstacleCollidersDirty()

    -- 生成恢复摘要
    local obCount = data.obstacles and #data.obstacles or 0
    local decCount = data.decorations and #data.decorations or 0
    local terCount = data.terrain and #data.terrain or 0
    local summary = string.format("已恢复: %d个障碍物, %d个装饰物, %d个地形格", obCount, decCount, terCount)
    print("[MapCloudSave] " .. summary)
    return true, summary
end

-- ============================================================================
-- 云端读写
-- ============================================================================

--- 保存到指定存档栏位 (1-3)
---@param scene Scene
---@param slotIndex number 1|2|3
---@param callback function|nil  function(success, errMsg)
function MapCloudSave.SaveToSlot(scene, slotIndex, callback)
    local key = SLOT_KEYS[slotIndex]
    if not key then
        if callback then callback(false, "无效的栏位: " .. tostring(slotIndex)) end
        return
    end

    local jsonStr = MapCloudSave.Serialize(scene)
    print(string.format("[MapCloudSave] 保存到栏位 %d, 数据大小: %d 字节", slotIndex, #jsonStr))

    if UseCloud() then
        clientCloud:Set(key, jsonStr, {
            ok = function()
                print(string.format("[MapCloudSave] 栏位 %d 已保存到云端", slotIndex))
                if callback then callback(true) end
            end,
            error = function(code, reason)
                print(string.format("[MapCloudSave] 栏位 %d 云端保存失败: %s, 尝试本地", slotIndex, tostring(reason)))
                local ok, err = LocalWrite(key, jsonStr)
                if callback then callback(ok, err) end
            end,
        })
    else
        local ok, err = LocalWrite(key, jsonStr)
        if callback then callback(ok, err) end
    end
end

--- 从指定存档栏位读取 (1-3)
---@param slotIndex number 1|2|3
---@param callback function  function(success, jsonStr|errMsg)
function MapCloudSave.LoadFromSlot(slotIndex, callback)
    local key = SLOT_KEYS[slotIndex]
    if not key then
        callback(false, "无效的栏位: " .. tostring(slotIndex))
        return
    end

    if UseCloud() then
        clientCloud:Get(key, {
            ok = function(values, iscores)
                local jsonStr = values[key]
                if jsonStr and jsonStr ~= "" then
                    print(string.format("[MapCloudSave] 栏位 %d 云端读取成功, %d 字节", slotIndex, #jsonStr))
                    callback(true, jsonStr)
                else
                    print(string.format("[MapCloudSave] 栏位 %d 云端为空", slotIndex))
                    callback(false, "栏位为空")
                end
            end,
            error = function(code, reason)
                print(string.format("[MapCloudSave] 栏位 %d 云端读取失败: %s, 尝试本地", slotIndex, tostring(reason)))
                local exists, content = LocalRead(key)
                if exists then
                    callback(true, content)
                else
                    callback(false, tostring(reason))
                end
            end,
        })
    else
        local exists, content = LocalRead(key)
        if exists then
            print(string.format("[MapCloudSave] 栏位 %d 本地读取成功, %d 字节", slotIndex, #content))
            callback(true, content)
        else
            callback(false, "栏位为空")
        end
    end
end

--- 删除指定存档栏位 (1-3)
---@param slotIndex number 1|2|3
---@param callback function|nil  function(success, errMsg)
function MapCloudSave.DeleteSlot(slotIndex, callback)
    local key = SLOT_KEYS[slotIndex]
    if not key then
        if callback then callback(false, "无效的栏位: " .. tostring(slotIndex)) end
        return
    end

    if UseCloud() then
        clientCloud:Set(key, "", {
            ok = function()
                print(string.format("[MapCloudSave] 栏位 %d 云端已删除", slotIndex))
                if callback then callback(true) end
            end,
            error = function(code, reason)
                print(string.format("[MapCloudSave] 栏位 %d 云端删除失败: %s, 尝试本地", slotIndex, tostring(reason)))
                local ok = LocalDelete(key)
                if callback then callback(ok, ok and nil or "本地删除失败") end
            end,
        })
    else
        local ok = LocalDelete(key)
        if callback then callback(ok, ok and nil or "本地删除失败") end
    end
end

--- 从 JSON 字符串中解析时间戳
---@param jsonStr string
---@return number ts
local function ParseTimestamp(jsonStr)
    local parseOk, data = pcall(cjson.decode, jsonStr)
    if parseOk and type(data) == "table" and data.ts then
        return data.ts
    end
    return 0
end

--- 批量查询所有存档栏位状态（3个栏位）
---@param callback function  function(slots)  slots = { [1]={exists,ts}, [2]={exists,ts}, [3]={exists,ts} }
function MapCloudSave.QueryAllSlots(callback)
    if UseCloud() then
        local batch = clientCloud:BatchGet()
        for _, key in ipairs(SLOT_KEYS) do
            batch:Key(key)
        end

        batch:Fetch({
            ok = function(values, iscores)
                local slots = {}
                for i = 1, 3 do
                    local jsonStr = values[SLOT_KEYS[i]]
                    if jsonStr and jsonStr ~= "" then
                        slots[i] = { exists = true, ts = ParseTimestamp(jsonStr) }
                    else
                        slots[i] = { exists = false, ts = 0 }
                    end
                end
                callback(slots)
            end,
            error = function(code, reason)
                print("[MapCloudSave] 云端批量查询失败: " .. tostring(reason) .. ", 使用本地数据")
                local slots = {}
                for i = 1, 3 do
                    local exists, content = LocalRead(SLOT_KEYS[i])
                    if exists then
                        slots[i] = { exists = true, ts = ParseTimestamp(content) }
                    else
                        slots[i] = { exists = false, ts = 0 }
                    end
                end
                callback(slots)
            end,
        })
    else
        local slots = {}
        for i = 1, 3 do
            local exists, content = LocalRead(SLOT_KEYS[i])
            if exists then
                slots[i] = { exists = true, ts = ParseTimestamp(content) }
            else
                slots[i] = { exists = false, ts = 0 }
            end
        end
        callback(slots)
    end
end

--- 应用存档数据到场景
---@param scene Scene
---@param jsonStr string
---@param callback function|nil  function(success, errMsg)
function MapCloudSave.ApplyToScene(scene, jsonStr, callback)
    local ok, errMsg = MapCloudSave.Deserialize(scene, jsonStr)
    if callback then callback(ok, errMsg) end
end

return MapCloudSave
