-- ============================================================================
-- Shared.lua — 共享代码（Server / Client 均引用）
-- 职责：场景创建、地图搭建、材质工具、远程事件注册
-- ============================================================================

local Shared = {}
local Config = require("config.GameConfig")

-- Re-export 方便其他模块使用
Shared.Config  = Config
Shared.CTRL    = Config.CTRL
Shared.EVENTS  = Config.EVENTS
Shared.VARS    = Config.VARS

-- ============================================================================
-- 工具函数
-- ============================================================================

function Shared.Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- 创建 PBR 纯色材质（不透明）
function Shared.CreatePBRMaterial(color, metallic, roughness)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(color.r, color.g, color.b, 1.0)))
    mat:SetShaderParameter("MatSpecColor", Variant(Color(0.5, 0.5, 0.5, 1.0)))
    mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
    mat:SetShaderParameter("Roughness", Variant(roughness or 0.6))
    return mat
end

--- 创建 PBR 半透明材质
function Shared.CreatePBRAlphaMaterial(color, metallic, roughness)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("MatSpecColor", Variant(Color(0.4, 0.4, 0.4, 1.0)))
    mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
    mat:SetShaderParameter("Roughness", Variant(roughness or 0.6))
    return mat
end

-- ============================================================================
-- 场景创建
-- ============================================================================

function Shared.CreateScene(isServer)
    local scene = Scene()

    scene:CreateComponent("Octree", LOCAL)
    scene:CreateComponent("DebugRenderer", LOCAL)

    local physicsWorld = scene:CreateComponent("PhysicsWorld", LOCAL)
    physicsWorld:SetGravity(Vector3(0, -9.81, 0))

    -- 光照（仅客户端）
    if not isServer then
        scene:InstantiateXML("LightGroup/Daytime.xml", Vector3.ZERO, Quaternion.IDENTITY, LOCAL)
    end

    -- 搭建地图
    Shared.CreateMap(scene, isServer)

    -- 保存 scene 引用供 BuildObstacleColliders 扫描围墙用
    Shared.currentScene = scene

    return scene
end

-- ============================================================================
-- 地图搭建
-- ============================================================================

function Shared.CreateMap(scene, isServer)
    local L = Config.Level1
    local C = Config.Colors

    -- ====== 外围环境（在农场地面之前创建，层级在下方）======
    Shared.CreateExterior(scene, isServer)

    -- ====== 地面 ======
    local floor = scene:CreateChild("Floor", LOCAL)
    floor.position = Vector3(L.MapWidth / 2, -0.25, L.MapHeight / 2)
    floor.scale = Vector3(L.MapWidth, 0.5, L.MapHeight)
    if not isServer then
        local m = floor:CreateComponent("StaticModel", LOCAL)
        m:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        -- 纯色草地（与树木绿色一致）
        local grassMat = Material:new()
        grassMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        grassMat:SetShaderParameter("MatDiffColor", Variant(Color(0.25, 0.82, 0.05, 1.0)))
        grassMat:SetShaderParameter("Roughness", Variant(0.92))
        grassMat:SetShaderParameter("Metallic", Variant(0.0))
        m:SetMaterial(grassMat)
    end
    local fb = floor:CreateComponent("RigidBody", LOCAL)
    fb:SetCollisionLayer(1)
    local fs = floor:CreateComponent("CollisionShape", LOCAL)
    fs:SetBox(Vector3(1, 1, 1))

    -- ====== 目标区地面（黄色棋盘格贴图，按 terrainGrid target 格子动态生成） ======
    if not isServer then
        Shared.RebuildTargetFloor(scene)
    end

    -- ====== 边界围墙（h=0.7m，参考概念图比例） ======
    local wallH = 0.7
    local wallThick = 0.5
    -- 下边 (Z=0) — 水平墙包裹角落
    Shared.CreateWall(scene, Vector3(L.MapWidth/2, wallH/2, -wallThick/2), Vector3(L.MapWidth + wallThick, wallH, wallThick), isServer)
    -- 上边 (Z=MapHeight) — 水平墙包裹角落
    Shared.CreateWall(scene, Vector3(L.MapWidth/2, wallH/2, L.MapHeight + wallThick/2), Vector3(L.MapWidth + wallThick, wallH, wallThick), isServer)
    -- 左边 (X=0) — 垂直墙不包含角落，缩短长度
    Shared.CreateWall(scene, Vector3(-wallThick/2, wallH/2, L.MapHeight/2), Vector3(wallThick, wallH, L.MapHeight), isServer)
    -- 右边 (X=MapWidth) — 垂直墙不包含角落，缩短长度
    Shared.CreateWall(scene, Vector3(L.MapWidth + wallThick/2, wallH/2, L.MapHeight/2), Vector3(wallThick, wallH, L.MapHeight), isServer)

    -- ====== U 形目标围栏 ======
    Shared.CreateTargetFence(scene, isServer)

    -- ====== 障碍物 ======
    for _, obs in ipairs(L.Obstacles) do
        Shared.CreateObstacle(scene, obs, isServer)
    end

    -- ====== 面包屑道具（仅视觉+触发器） ======
    Shared.CreateBreadcrumb(scene, L.BreadcrumbPos, isServer)

    print("[Shared] Map created: " .. L.Name)
end

-- ============================================================================
-- 目标区地面重建（黄色棋盘格贴图，按 terrainGrid target 格子生成）
-- ============================================================================

--- 缓存的目标区材质（避免每格重复创建）
local targetFloorMat_ = nil

local function GetTargetFloorMaterial()
    if targetFloorMat_ then return targetFloorMat_ end
    targetFloorMat_ = Material:new()
    targetFloorMat_:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRDiff.xml"))
    targetFloorMat_:SetTexture(TU_DIFFUSE, cache:GetResource("Texture2D", "image/target_checker_20260511052831.png"))
    targetFloorMat_:SetShaderParameter("UOffset", Variant(Vector4(1, 0, 0, 0)))
    targetFloorMat_:SetShaderParameter("VOffset", Variant(Vector4(0, 1, 0, 0)))
    targetFloorMat_:SetShaderParameter("Roughness", Variant(0.7))
    targetFloorMat_:SetShaderParameter("Metallic", Variant(0.0))
    return targetFloorMat_
end

--- 根据 Shared.terrainGrid 的 "target" 格子动态重建目标区地面
---@param scene Scene
function Shared.RebuildTargetFloor(scene)
    -- 删除旧容器
    local old = scene:GetChild("TargetFloorGroup", false)
    if old then old:Remove() end

    local group = scene:CreateChild("TargetFloorGroup", LOCAL)
    local mat = GetTargetFloorMaterial()
    local boxModel = cache:GetResource("Model", "Models/Box.mdl")

    -- 优先使用 terrainGrid
    local grid = Shared.terrainGrid
    if grid then
        for x, row in pairs(grid) do
            for z, cellType in pairs(row) do
                if cellType == "target" then
                    local tile = group:CreateChild("TF", LOCAL)
                    tile.position = Vector3(x + 0.5, 0.011, z + 0.5)
                    tile.scale = Vector3(1.0, 0.01, 1.0)
                    local sm = tile:CreateComponent("StaticModel", LOCAL)
                    sm:SetModel(boxModel)
                    sm:SetMaterial(mat)
                end
            end
        end
    else
        -- fallback：使用 Config 默认 TargetArea
        local ta = Config.Level1.TargetArea
        local hx = ta.Size.x / 2
        local hz = ta.Size.z / 2
        local minX = math.floor(ta.Center.x - hx)
        local maxX = math.ceil(ta.Center.x + hx)
        local minZ = math.floor(ta.Center.z - hz)
        local maxZ = math.ceil(ta.Center.z + hz)
        for x = minX, maxX - 1 do
            for z = minZ, maxZ - 1 do
                local tile = group:CreateChild("TF", LOCAL)
                tile.position = Vector3(x + 0.5, 0.011, z + 0.5)
                tile.scale = Vector3(1.0, 0.01, 1.0)
                local sm = tile:CreateComponent("StaticModel", LOCAL)
                sm:SetModel(boxModel)
                sm:SetMaterial(mat)
            end
        end
    end
end

-- ============================================================================
-- 高度地形系统（平滑高分辨率网格 + 高度查询）
-- ============================================================================

--- 高度数据和平滑网格（由 TerrainEditor 写入）
Shared.heightGrid = nil    -- heightGrid[x][z] = number (米)
Shared.smoothGrid = nil    -- smoothGrid[x][z] = number (0~1, 每格独立平滑因子)

--- 内部缓存：平滑后的高分辨率高度图（供 GetTerrainHeightAt 查询）
Shared._hmap     = nil  -- _hmap[ix][iz] = float（细分网格高度值）
Shared._hmapSub  = 4    -- 每格子细分次数（0.25m 分辨率）
Shared._hmapMinX = 0
Shared._hmapMinZ = 0
Shared._hmapMaxX = 0
Shared._hmapMaxZ = 0

--- 获取格子 (x,z) 的原始高度，越界返回 0
---@param hg table heightGrid
---@param x number
---@param z number
---@return number
local function GetCellHeight(hg, x, z)
    if hg[x] and hg[x][z] then return hg[x][z] end
    return 0
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 构建平滑高度图：将稀疏格子高度 → 高分辨率高度图 → 高斯模糊
-- ─────────────────────────────────────────────────────────────────────────────

--- 构建平滑后的高分辨率高度图（per-cell 平滑因子）
---@param hg table heightGrid (sparse)
---@param sg table|nil smoothGrid (sparse), sg[x][z] = 0~1, 默认 0.5
---@return table hmap, number minIX, number minIZ, number maxIX, number maxIZ
local function BuildSmoothedHeightMap(hg, sg)
    local SUB = Shared._hmapSub  -- 每米 4 个采样点

    -- 1) 收集有高度的格子范围
    local cellMinX, cellMaxX, cellMinZ, cellMaxZ
    for x, row in pairs(hg) do
        for z, h in pairs(row) do
            if h ~= 0 then
                if not cellMinX then
                    cellMinX, cellMaxX = x, x
                    cellMinZ, cellMaxZ = z, z
                else
                    if x < cellMinX then cellMinX = x end
                    if x > cellMaxX then cellMaxX = x end
                    if z < cellMinZ then cellMinZ = z end
                    if z > cellMaxZ then cellMaxZ = z end
                end
            end
        end
    end
    if not cellMinX then return nil end

    -- 计算全局最大 smooth 值，决定 PAD 和模糊次数
    local maxSmooth = 0
    for x, row in pairs(hg) do
        for z, h in pairs(row) do
            if h ~= 0 then
                local s = (sg and sg[x] and sg[x][z]) or 0.5
                if s > maxSmooth then maxSmooth = s end
            end
        end
    end

    -- smooth 越大，模糊范围越广、次数越多 → 更宽更平滑的过渡
    -- smooth=0 → PAD=1, 0次; smooth=0.5 → PAD=2, 6次; smooth=1 → PAD=4, 12次
    local PAD = math.max(1, math.floor(maxSmooth * 4 + 0.5))
    local maxBlurPasses = (maxSmooth > 0.001) and math.floor(maxSmooth * 12 + 0.5) or 0

    cellMinX = cellMinX - PAD
    cellMaxX = cellMaxX + 1 + PAD
    cellMinZ = cellMinZ - PAD
    cellMaxZ = cellMaxZ + 1 + PAD

    local minIX = cellMinX * SUB
    local maxIX = cellMaxX * SUB
    local minIZ = cellMinZ * SUB
    local maxIZ = cellMaxZ * SUB

    -- 2) 初始化高分辨率高度图（方块状：每个像素取所属格子的高度）
    local hmap = {}
    for ix = minIX, maxIX do
        hmap[ix] = {}
        for iz = minIZ, maxIZ do
            local cx = math.floor(ix / SUB)
            local cz = math.floor(iz / SUB)
            hmap[ix][iz] = GetCellHeight(hg, cx, cz)
        end
    end

    -- 如果全局无模糊需求（所有格子 smooth ≈ 0），直接返回方块高度图
    if maxBlurPasses <= 0 then
        return hmap, minIX, minIZ, maxIX, maxIZ
    end

    -- 3) 保存原始方块高度（smooth=0 的参考基准）
    local original = {}
    for ix = minIX, maxIX do
        original[ix] = {}
        for iz = minIZ, maxIZ do
            original[ix][iz] = hmap[ix][iz]
        end
    end

    -- 4) 执行高斯模糊（最大次数），产生完全平滑版本
    for _ = 1, maxBlurPasses do
        local tmp = {}
        for ix = minIX, maxIX do
            tmp[ix] = {}
            for iz = minIZ, maxIZ do
                local h0 = (ix > minIX and hmap[ix - 1][iz]) or 0
                local h1 = hmap[ix][iz]
                local h2 = (ix < maxIX and hmap[ix + 1][iz]) or 0
                tmp[ix][iz] = h0 * 0.25 + h1 * 0.5 + h2 * 0.25
            end
        end
        for ix = minIX, maxIX do
            for iz = minIZ, maxIZ do
                local h0 = (iz > minIZ and tmp[ix][iz - 1]) or 0
                local h1 = tmp[ix][iz]
                local h2 = (iz < maxIZ and tmp[ix][iz + 1]) or 0
                hmap[ix][iz] = h0 * 0.25 + h1 * 0.5 + h2 * 0.25
            end
        end
    end

    -- 5) 高度补偿：模糊后峰值被削低，按比例缩放整个影响区域使中心峰值恢复到指定高度
    --    对每个有高度的格子，找到模糊后的中心高度，计算缩放因子，
    --    然后对该格子及其周围受影响的区域统一缩放
    for x, row in pairs(hg) do
        for z, h in pairs(row) do
            if h ~= 0 then
                local centerIX = x * SUB + math.floor(SUB / 2)
                local centerIZ = z * SUB + math.floor(SUB / 2)
                local blurredCenter = (hmap[centerIX] and hmap[centerIX][centerIZ]) or 0
                if math.abs(blurredCenter) > 0.001 then
                    local scale = h / blurredCenter
                    -- 缩放范围 = 格子本身 + PAD 格的影响区域
                    local compPad = PAD
                    local sIX = (x - compPad) * SUB
                    local eIX = (x + 1 + compPad) * SUB
                    local sIZ = (z - compPad) * SUB
                    local eIZ = (z + 1 + compPad) * SUB
                    sIX = math.max(sIX, minIX)
                    eIX = math.min(eIX, maxIX)
                    sIZ = math.max(sIZ, minIZ)
                    eIZ = math.min(eIZ, maxIZ)
                    for ix2 = sIX, eIX do
                        for iz2 = sIZ, eIZ do
                            if hmap[ix2] and hmap[ix2][iz2] then
                                hmap[ix2][iz2] = hmap[ix2][iz2] * scale
                            end
                        end
                    end
                end
            end
        end
    end

    -- 6) per-pixel 混合：根据每个像素所属格子的 smooth 值，在方块和平滑之间插值
    --    smooth=0 → 完全方块（original）
    --    smooth=1 → 完全平滑+补偿后（hmap）
    --    中间值 → 线性插值
    for ix = minIX, maxIX do
        for iz = minIZ, maxIZ do
            local cx = math.floor(ix / SUB)
            local cz = math.floor(iz / SUB)

            -- 8方向邻居（含对角）
            local dirs8 = { {-1,0},{1,0},{0,-1},{0,1}, {-1,-1},{-1,1},{1,-1},{1,1} }

            -- 获取自身 smooth 值
            local selfH = GetCellHeight(hg, cx, cz)
            local w
            if selfH ~= 0 then
                -- 有高度的格子：使用自身 smooth
                w = (sg and sg[cx] and sg[cx][cz]) or 0.5
            else
                -- 无高度的格子（平地）：取有高度的邻居的最大 smooth
                -- 如果所有有高度的邻居 smooth=0，则该平地像素也不应受模糊影响
                w = 0
            end

            -- 同时考虑邻居中有高度格子的 smooth（使过渡区域平滑，含对角方向）
            for _, d in ipairs(dirs8) do
                local nx2, nz2 = cx + d[1], cz + d[2]
                local nh2 = GetCellHeight(hg, nx2, nz2)
                if nh2 ~= 0 then
                    local ns2 = (sg and sg[nx2] and sg[nx2][nz2]) or 0.5
                    if ns2 > w then w = ns2 end
                end
            end

            if w < 0.001 then
                -- 完全方块
                hmap[ix][iz] = original[ix][iz]
            elseif w < 0.999 then
                -- 部分平滑：在方块和曲面之间插值
                hmap[ix][iz] = original[ix][iz] * (1 - w) + hmap[ix][iz] * w
            end
            -- w >= 0.999: 完全平滑，直接使用 hmap（已含补偿）
        end
    end

    return hmap, minIX, minIZ, maxIX, maxIZ
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 高度查询：双线性插值（供实体定位）
-- ─────────────────────────────────────────────────────────────────────────────

--- 查询世界坐标 (wx, wz) 处的地形高度
--- 使用内部缓存的平滑高度图进行双线性插值
---@param wx number 世界 X
---@param wz number 世界 Z
---@return number 地形高度（米），无数据返回 0
function Shared.GetTerrainHeightAt(wx, wz)
    -- 优先检查方块格子（smooth=0）：高度图已被清零，直接返回格子原始高度
    local blockCells = Shared._blockCells
    if blockCells then
        local cx = math.floor(wx)
        local cz = math.floor(wz)
        if blockCells[cx] and blockCells[cx][cz] then
            local hg = Shared.heightGrid
            if hg and hg[cx] and hg[cx][cz] then
                return hg[cx][cz]
            end
        end
    end

    local hmap = Shared._hmap
    if not hmap then return 0 end

    local SUB = Shared._hmapSub
    local fx = wx * SUB  -- 转为高度图坐标
    local fz = wz * SUB

    local minIX = Shared._hmapMinX
    local minIZ = Shared._hmapMinZ
    local maxIX = Shared._hmapMaxX
    local maxIZ = Shared._hmapMaxZ

    -- 超出范围返回 0
    if fx < minIX or fx > maxIX or fz < minIZ or fz > maxIZ then return 0 end

    -- 双线性插值
    local ix0 = math.floor(fx)
    local iz0 = math.floor(fz)
    local ix1 = ix0 + 1
    local iz1 = iz0 + 1

    -- 钳制到边界
    ix0 = math.max(ix0, minIX)
    iz0 = math.max(iz0, minIZ)
    ix1 = math.min(ix1, maxIX)
    iz1 = math.min(iz1, maxIZ)

    local tx = fx - math.floor(fx)
    local tz = fz - math.floor(fz)

    local h00 = (hmap[ix0] and hmap[ix0][iz0]) or 0
    local h10 = (hmap[ix1] and hmap[ix1][iz0]) or 0
    local h01 = (hmap[ix0] and hmap[ix0][iz1]) or 0
    local h11 = (hmap[ix1] and hmap[ix1][iz1]) or 0

    -- bilinear
    local h0 = h00 * (1 - tx) + h10 * tx
    local h1 = h01 * (1 - tx) + h11 * tx
    return h0 * (1 - tz) + h1 * tz
end

--- 采样碰撞半径范围内多个点，返回最大高度
--- 防止角色/物体在斜坡上因只取中心点高度而身体穿入上坡侧地形
---@param wx number 世界 X
---@param wz number 世界 Z
---@param radius number 碰撞半径
---@return number 碰撞半径内的最大地形高度
function Shared.GetTerrainHeightAtRadius(wx, wz, radius)
    local h = Shared.GetTerrainHeightAt(wx, wz)
    h = math.max(h, Shared.GetTerrainHeightAt(wx + radius, wz))
    h = math.max(h, Shared.GetTerrainHeightAt(wx - radius, wz))
    h = math.max(h, Shared.GetTerrainHeightAt(wx, wz + radius))
    h = math.max(h, Shared.GetTerrainHeightAt(wx, wz - radius))
    return h
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 网格生成：从平滑高度图生成 CustomGeometry
-- ─────────────────────────────────────────────────────────────────────────────

--- 辅助：为 CustomGeometry 定义一个三角形（3 个顶点）
---@param geom CustomGeometry
---@param p1 Vector3
---@param p2 Vector3
---@param p3 Vector3
---@param n Vector3 法线
local function EmitTri(geom, p1, p2, p3, n)
    geom:DefineVertex(p1); geom:DefineNormal(n); geom:DefineTexCoord(Vector2(p1.x, p1.z))
    geom:DefineVertex(p2); geom:DefineNormal(n); geom:DefineTexCoord(Vector2(p2.x, p2.z))
    geom:DefineVertex(p3); geom:DefineNormal(n); geom:DefineTexCoord(Vector2(p3.x, p3.z))
end

--- 重建高度地形网格（CustomGeometry，高分辨率平滑）
--- 生成自然丝滑的地形隆起/凹陷，边缘与平地过渡
---@param scene Scene
function Shared.RebuildHeightTerrain(scene)
    -- 删除旧的高度地形节点
    local old = scene:GetChild("HeightTerrain", false)
    if old then old:Remove() end

    local hg = Shared.heightGrid
    if not hg then
        Shared._hmap = nil
        return
    end

    local sg = Shared.smoothGrid

    -- 判断是否有任何非零高度
    local hasHeight = false
    for _, row in pairs(hg) do
        for _, h in pairs(row) do
            if h ~= 0 then hasHeight = true; break end
        end
        if hasHeight then break end
    end
    if not hasHeight then
        Shared._hmap = nil
        return
    end

    -- 1) 构建平滑高度图（per-cell 平滑因子）
    local hmap, minIX, minIZ, maxIX, maxIZ = BuildSmoothedHeightMap(hg, sg)
    if not hmap then
        Shared._hmap = nil
        return
    end

    -- 缓存供 GetTerrainHeightAt 使用
    Shared._hmap     = hmap
    Shared._hmapMinX = minIX
    Shared._hmapMinZ = minIZ
    Shared._hmapMaxX = maxIX
    Shared._hmapMaxZ = maxIZ

    local SUB = Shared._hmapSub
    local step = 1.0 / SUB  -- 世界空间中每个细分的步长 (0.25m)
    local yOff = 0.005       -- Z-fighting 微偏移
    local MIN_H = 0.002      -- 高度阈值，低于此不生成面片

    -- ── 收集 smooth=0 的方块格子 ──
    local blockCells = {}  -- blockCells[x][z] = true
    Shared._blockCells = blockCells  -- 缓存供 GetTerrainHeightAt 使用
    for x, row in pairs(hg) do
        for z, h in pairs(row) do
            if h ~= 0 then
                local s = (sg and sg[x] and sg[x][z]) or 0.5
                if s < 0.001 then
                    if not blockCells[x] then blockCells[x] = {} end
                    blockCells[x][z] = true
                end
            end
        end
    end

    -- 判断像素是否属于方块格子
    local function IsBlockPixel(pix, piz)
        local cx = math.floor(pix / SUB)
        local cz = math.floor(piz / SUB)
        return blockCells[cx] and blockCells[cx][cz]
    end

    -- 2) 生成 CustomGeometry 网格
    local terrainNode = scene:CreateChild("HeightTerrain", LOCAL)
    terrainNode.position = Vector3.ZERO
    local geom = terrainNode:CreateComponent("CustomGeometry", LOCAL)
    geom:BeginGeometry(0, TRIANGLE_LIST)

    local vertCount = 0

    -- ── 2a) 为 smooth=0 格子生成完美 Box 几何体 ──
    for x, row in pairs(hg) do
        for z, h in pairs(row) do
            if h ~= 0 and blockCells[x] and blockCells[x][z] then
                local x0 = x * 1.0       -- 世界坐标
                local x1 = (x + 1) * 1.0
                local z0 = z * 1.0
                local z1 = (z + 1) * 1.0
                local y0 = yOff          -- 底面（地面）
                local y1 = h + yOff      -- 顶面

                -- 顶面（Y+）
                local topN = Vector3.UP
                EmitTri(geom, Vector3(x0, y1, z0), Vector3(x0, y1, z1), Vector3(x1, y1, z1), topN)
                EmitTri(geom, Vector3(x0, y1, z0), Vector3(x1, y1, z1), Vector3(x1, y1, z0), topN)
                vertCount = vertCount + 6

                -- 四个侧面：只在邻格高度更低时生成墙壁
                -- X- 面
                local nxH = GetCellHeight(hg, x - 1, z)
                local nxBlock = blockCells[x - 1] and blockCells[x - 1][z]
                local wallBaseXN = (nxBlock and nxH or 0) + yOff
                if wallBaseXN < y1 - MIN_H then
                    local sn = Vector3(-1, 0, 0)
                    EmitTri(geom, Vector3(x0, y1, z1), Vector3(x0, y1, z0), Vector3(x0, wallBaseXN, z0), sn)
                    EmitTri(geom, Vector3(x0, y1, z1), Vector3(x0, wallBaseXN, z0), Vector3(x0, wallBaseXN, z1), sn)
                    vertCount = vertCount + 6
                end

                -- X+ 面
                local pxH = GetCellHeight(hg, x + 1, z)
                local pxBlock = blockCells[x + 1] and blockCells[x + 1][z]
                local wallBaseXP = (pxBlock and pxH or 0) + yOff
                if wallBaseXP < y1 - MIN_H then
                    local sn = Vector3(1, 0, 0)
                    EmitTri(geom, Vector3(x1, y1, z0), Vector3(x1, y1, z1), Vector3(x1, wallBaseXP, z1), sn)
                    EmitTri(geom, Vector3(x1, y1, z0), Vector3(x1, wallBaseXP, z1), Vector3(x1, wallBaseXP, z0), sn)
                    vertCount = vertCount + 6
                end

                -- Z- 面
                local nzH = GetCellHeight(hg, x, z - 1)
                local nzBlock = blockCells[x] and blockCells[x][z - 1]
                local wallBaseZN = (nzBlock and nzH or 0) + yOff
                if wallBaseZN < y1 - MIN_H then
                    local sn = Vector3(0, 0, -1)
                    EmitTri(geom, Vector3(x0, y1, z0), Vector3(x1, y1, z0), Vector3(x1, wallBaseZN, z0), sn)
                    EmitTri(geom, Vector3(x0, y1, z0), Vector3(x1, wallBaseZN, z0), Vector3(x0, wallBaseZN, z0), sn)
                    vertCount = vertCount + 6
                end

                -- Z+ 面
                local pzH = GetCellHeight(hg, x, z + 1)
                local pzBlock = blockCells[x] and blockCells[x][z + 1]
                local wallBaseZP = (pzBlock and pzH or 0) + yOff
                if wallBaseZP < y1 - MIN_H then
                    local sn = Vector3(0, 0, 1)
                    EmitTri(geom, Vector3(x1, y1, z1), Vector3(x0, y1, z1), Vector3(x0, wallBaseZP, z1), sn)
                    EmitTri(geom, Vector3(x1, y1, z1), Vector3(x0, wallBaseZP, z1), Vector3(x1, wallBaseZP, z1), sn)
                    vertCount = vertCount + 6
                end
            end
        end
    end

    -- ── 2b) 将方块格子的高度图像素清零，避免高度图网格重叠 ──
    for x, row in pairs(blockCells) do
        for z, _ in pairs(row) do
            for pix = x * SUB, (x + 1) * SUB do
                if hmap[pix] then
                    for piz = z * SUB, (z + 1) * SUB do
                        if hmap[pix][piz] ~= nil then
                            hmap[pix][piz] = 0
                        end
                    end
                end
            end
        end
    end

    -- ── 2c) 高度图网格（仅 smooth>0 的区域） ──
    for ix = minIX, maxIX - 1 do
        for iz = minIZ, maxIZ - 1 do
            -- 四个角的高度
            local h00 = hmap[ix]     and hmap[ix][iz]         or 0
            local h10 = hmap[ix + 1] and hmap[ix + 1][iz]     or 0
            local h01 = hmap[ix]     and hmap[ix][iz + 1]     or 0
            local h11 = hmap[ix + 1] and hmap[ix + 1][iz + 1] or 0

            -- 跳过全部接近零的四边形
            if math.abs(h00) < MIN_H and math.abs(h10) < MIN_H
               and math.abs(h01) < MIN_H and math.abs(h11) < MIN_H then
                goto continue
            end

            -- 世界坐标
            local wx0 = ix * step
            local wz0 = iz * step
            local wx1 = (ix + 1) * step
            local wz1 = (iz + 1) * step

            local v1 = Vector3(wx0, h00 + yOff, wz0)
            local v2 = Vector3(wx1, h10 + yOff, wz0)
            local v3 = Vector3(wx1, h11 + yOff, wz1)
            local v4 = Vector3(wx0, h01 + yOff, wz1)

            -- 法线：两条对角线叉积
            local diag1 = v3 - v1
            local diag2 = v4 - v2
            local normal = diag2:CrossProduct(diag1):Normalized()

            -- 两个三角形
            EmitTri(geom, v1, v3, v2, normal)
            EmitTri(geom, v1, v4, v3, normal)
            vertCount = vertCount + 6

            -- ── 侧面裙边 ──
            -- 在高度图边界处（相邻像素高度≈0 或不存在），生成侧面连接地面
            -- 只在有明显高度差的边缘处绘制

            -- 检查四条边是否需要裙边
            local function NeedSkirt(adjIX, adjIZ)
                if adjIX < minIX or adjIX > maxIX or adjIZ < minIZ or adjIZ > maxIZ then
                    return true
                end
                local ah = hmap[adjIX] and hmap[adjIX][adjIZ] or 0
                return math.abs(ah) < MIN_H
            end

            -- Z- 边（iz 方向的前边）
            if iz == minIZ or NeedSkirt(ix, iz - 1) then
                if math.abs(h00) > MIN_H or math.abs(h10) > MIN_H then
                    local b1 = Vector3(wx0, yOff, wz0)
                    local b2 = Vector3(wx1, yOff, wz0)
                    local sn = Vector3(0, 0, -1)
                    if h00 > 0 or h10 > 0 then
                        EmitTri(geom, v1, v2, b2, sn)
                        EmitTri(geom, v1, b2, b1, sn)
                    else
                        EmitTri(geom, b1, b2, v2, sn)
                        EmitTri(geom, b1, v2, v1, sn)
                    end
                    vertCount = vertCount + 6
                end
            end

            -- Z+ 边
            if iz == maxIZ - 1 or NeedSkirt(ix, iz + 1) then
                if math.abs(h01) > MIN_H or math.abs(h11) > MIN_H then
                    local b3 = Vector3(wx1, yOff, wz1)
                    local b4 = Vector3(wx0, yOff, wz1)
                    local sn = Vector3(0, 0, 1)
                    if h01 > 0 or h11 > 0 then
                        EmitTri(geom, v3, v4, b4, sn)
                        EmitTri(geom, v3, b4, b3, sn)
                    else
                        EmitTri(geom, b4, b3, v3, sn)
                        EmitTri(geom, b4, v3, v4, sn)
                    end
                    vertCount = vertCount + 6
                end
            end

            -- X- 边
            if ix == minIX or NeedSkirt(ix - 1, iz) then
                if math.abs(h00) > MIN_H or math.abs(h01) > MIN_H then
                    local b1 = Vector3(wx0, yOff, wz0)
                    local b4 = Vector3(wx0, yOff, wz1)
                    local sn = Vector3(-1, 0, 0)
                    if h00 > 0 or h01 > 0 then
                        EmitTri(geom, v4, v1, b1, sn)
                        EmitTri(geom, v4, b1, b4, sn)
                    else
                        EmitTri(geom, b1, b4, v4, sn)
                        EmitTri(geom, b1, v4, v1, sn)
                    end
                    vertCount = vertCount + 6
                end
            end

            -- X+ 边
            if ix == maxIX - 1 or NeedSkirt(ix + 1, iz) then
                if math.abs(h10) > MIN_H or math.abs(h11) > MIN_H then
                    local b2 = Vector3(wx1, yOff, wz0)
                    local b3 = Vector3(wx1, yOff, wz1)
                    local sn = Vector3(1, 0, 0)
                    if h10 > 0 or h11 > 0 then
                        EmitTri(geom, v2, v3, b3, sn)
                        EmitTri(geom, v2, b3, b2, sn)
                    else
                        EmitTri(geom, b3, b2, v2, sn)
                        EmitTri(geom, b3, v2, v3, sn)
                    end
                    vertCount = vertCount + 6
                end
            end

            ::continue::
        end
    end

    geom:Commit()

    -- 材质：草地色 PBR
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.25, 0.82, 0.05, 1.0)))
    mat:SetShaderParameter("Roughness", Variant(0.92))
    mat:SetShaderParameter("Metallic", Variant(0.0))
    geom:SetMaterial(mat)

    print(string.format("[Shared] RebuildHeightTerrain: %d verts, per-cell smooth, grid=[%d,%d]-[%d,%d]",
        vertCount, minIX, minIZ, maxIX, maxIZ))

    -- 地形高度变化后，重新定位所有障碍物/装饰物的 Y 坐标
    Shared.RepositionAllObstacles(scene)
end

--- 重新定位所有障碍物和装饰物，使其底部贴合地形表面
function Shared.RepositionAllObstacles(scene)
    if not scene then return end

    -- 重新定位障碍物
    local obstacles = Config.Level1 and Config.Level1.Obstacles or {}
    for _, obs in ipairs(obstacles) do
        local node = scene:GetChild(obs.name, false)
        if node then
            local terrainY = Shared.GetTerrainHeightAt(obs.pos.x, obs.pos.z)
            local newY = terrainY + (obs.scale and obs.scale.y / 2 or 0)
            node.position = Vector3(obs.pos.x, newY, obs.pos.z)
            -- 重新对齐 Visual 子节点底部
            local visual = node:GetChild("Visual")
            if visual then
                local model = visual:GetComponent("StaticModel")
                if model then
                    visual.position = Vector3(visual.position.x, 0, visual.position.z)
                    local worldBB = model.worldBoundingBox
                    local worldMinY = worldBB.min.y
                    visual.position = Vector3(
                        visual.position.x,
                        visual.position.y + (node.position.y - obs.scale.y / 2) - worldMinY,
                        visual.position.z
                    )
                end
            end
        end
    end

    -- 重新定位装饰物
    local decorations = Config.Exterior and Config.Exterior.Decorations or {}
    for _, dec in ipairs(decorations) do
        local node = scene:GetChild(dec.name, false)
        if node then
            local terrainY = Shared.GetTerrainHeightAt(dec.pos.x, dec.pos.z)
            local newY = terrainY + (dec.scale and dec.scale.y / 2 or 0)
            node.position = Vector3(dec.pos.x, newY, dec.pos.z)
            local visual = node:GetChild("Visual")
            if visual then
                local model = visual:GetComponent("StaticModel")
                if model then
                    visual.position = Vector3(visual.position.x, 0, visual.position.z)
                    local worldBB = model.worldBoundingBox
                    local worldMinY = worldBB.min.y
                    visual.position = Vector3(
                        visual.position.x,
                        visual.position.y + (node.position.y - (dec.scale and dec.scale.y / 2 or 0)) - worldMinY,
                        visual.position.z
                    )
                end
            end
        end
    end
end

-- ============================================================================
-- 围墙
-- ============================================================================

function Shared.CreateWall(scene, pos, size, isServer)
    local wall = scene:CreateChild("Wall", LOCAL)
    wall.position = pos

    local wallModel = Config.Models.Wall

    -- WallSeg 位置计算（客户端和服务端共用，服务端需要用于碰撞体扫描）
    local isHorizontal = (size.x > size.z)
    local wallLength = isHorizontal and size.x or size.z
    local modelNaturalHeight = 0.22
    local ms = size.y / modelNaturalHeight
    local segmentSpan = 1.75 * ms
    local halfLen = wallLength / 2
    local startOffset = -halfLen + segmentSpan / 2
    local segIndex = 0

    while true do
        local offset = startOffset + segIndex * segmentSpan
        if offset > halfLen then break end

        local segNode = wall:CreateChild("WallSeg", LOCAL)

        if isHorizontal then
            segNode.position = Vector3(offset, 0, 0)
        else
            segNode.position = Vector3(0, 0, offset)
        end

        -- 客户端：添加视觉模型
        if not isServer and wallModel then
            segNode.scale = Vector3(ms, ms, ms)
            if not isHorizontal then
                segNode.rotation = Quaternion(90, Vector3.UP)
            end

            local m = segNode:CreateComponent("StaticModel", LOCAL)
            m:SetModel(cache:GetResource("Model", wallModel.model))
            m:SetMaterial(cache:GetResource("Material", wallModel.material))
            m.castShadows = true

            -- 底部对齐: 让模型底部贴 y=0
            local bb = m.boundingBox
            segNode.position = Vector3(segNode.position.x, -pos.y - bb.min.y * ms, segNode.position.z)
        end

        segIndex = segIndex + 1
    end

    -- 客户端无模型配置时的回退样式
    if not isServer and not wallModel then
        wall.scale = size
        local m = wall:CreateComponent("StaticModel", LOCAL)
        m:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        m:SetMaterial(Shared.CreatePBRMaterial(Config.Colors.Wall, 0.0, 0.75))
        m.castShadows = true
    end

    local b = wall:CreateComponent("RigidBody", LOCAL)
    b:SetCollisionLayer(1)
    local s = wall:CreateComponent("CollisionShape", LOCAL)
    s:SetBox(size)
end

--- 按 label（如 "围墙段10"）在 scene 中找到对应 WallSeg 并删除
--- 扫描顺序与客户端 MapEditor.ScanStructures() 一致：遍历所有 Wall 子节点的 WallSeg
function Shared.RemoveWallSegByLabel(label)
    if not Shared.currentScene then return false end

    -- 从 label 中提取编号
    local targetIndex = tonumber(label:match("围墙段(%d+)"))
    if not targetIndex then
        print(string.format("[Shared] RemoveWallSegByLabel: 无法解析 label '%s'", label))
        return false
    end

    -- 按 ScanStructures 相同顺序遍历
    local wallSegCount = 0
    for i = 0, Shared.currentScene:GetNumChildren(false) - 1 do
        local child = Shared.currentScene:GetChild(i)
        if child.name == "Wall" then
            for j = 0, child:GetNumChildren(false) - 1 do
                local seg = child:GetChild(j)
                if seg.name == "WallSeg" then
                    wallSegCount = wallSegCount + 1
                    if wallSegCount == targetIndex then
                        seg:Remove()
                        print(string.format("[Shared] 已删除围墙段 '%s' (Wall子节点 #%d)", label, j))
                        return true
                    end
                end
            end
        end
    end

    print(string.format("[Shared] RemoveWallSegByLabel: 未找到 '%s' (扫描到 %d 个围墙段)", label, wallSegCount))
    return false
end

-- ============================================================================
-- U 形目标围栏
-- ============================================================================

function Shared.CreateTargetFence(scene, isServer)
    local ta = Config.Level1.TargetArea
    local cx, cz = ta.Center.x, ta.Center.z
    local hw, hh = ta.Size.x / 2, ta.Size.z / 2
    local fenceH = 0.8
    local fenceThick = 0.3

    -- 右段 (X+ 侧，完整高墙)
    Shared.CreateFenceSegment(scene,
        Vector3(cx + hw + fenceThick/2, fenceH/2, cz),
        Vector3(fenceThick, fenceH, ta.Size.z + fenceThick*2),
        isServer)

    -- 上段 (Z+ 侧)
    Shared.CreateFenceSegment(scene,
        Vector3(cx, fenceH/2, cz + hh + fenceThick/2),
        Vector3(ta.Size.x, fenceH, fenceThick),
        isServer)

    -- 下段 (Z- 侧)
    Shared.CreateFenceSegment(scene,
        Vector3(cx, fenceH/2, cz - hh - fenceThick/2),
        Vector3(ta.Size.x, fenceH, fenceThick),
        isServer)
end

function Shared.CreateFenceSegment(scene, pos, size, isServer)
    local fence = scene:CreateChild("Fence", LOCAL)
    fence.position = pos

    local fenceModel = Config.Models.Fence
    if not isServer then
        if fenceModel then
            -- 新围栏模型自然尺寸: ~0.076 x 0.221 x 0.998 (X x Y x Z)
            -- Z方向是模型的长边(~1.0m)，沿围栏排列
            local isHorizontal = (size.x > size.z)
            local fenceLength = isHorizontal and size.x or size.z

            -- 等比缩放: 让模型高度匹配围栏高度
            local modelNaturalHeight = 0.221
            local ms = size.y / modelNaturalHeight
            local segmentSpan = 0.998 * ms  -- 每段覆盖的长度(Z方向 * 缩放)

            -- 从围栏起点开始，步进 segmentSpan
            local halfLen = fenceLength / 2
            local startOffset = -halfLen + segmentSpan / 2
            local segIndex = 0

            while true do
                local offset = startOffset + segIndex * segmentSpan
                if offset > halfLen then break end

                local segNode = fence:CreateChild("FenceSeg", LOCAL)
                segNode.scale = Vector3(ms, ms, ms)

                -- 模型Z轴是长边(~1.0m)
                -- 水平围栏(沿世界X): 旋转90°让模型Z映射到世界X
                -- 垂直围栏(沿世界Z): 模型Z自然沿Z，无需旋转
                if isHorizontal then
                    segNode.rotation = Quaternion(90, Vector3.UP)
                    segNode.position = Vector3(offset, 0, 0)
                else
                    segNode.position = Vector3(0, 0, offset)
                end

                local m = segNode:CreateComponent("StaticModel", LOCAL)
                m:SetModel(cache:GetResource("Model", fenceModel.model))
                m:SetMaterial(cache:GetResource("Material", fenceModel.material))
                m.castShadows = true

                -- 底部对齐
                local bb = m.boundingBox
                segNode.position = Vector3(
                    segNode.position.x,
                    -pos.y - bb.min.y * ms,
                    segNode.position.z
                )

                segIndex = segIndex + 1
            end
        else
            fence.scale = size
            local m = fence:CreateComponent("StaticModel", LOCAL)
            m:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            m:SetMaterial(Shared.CreatePBRMaterial(Config.Colors.Fence, 0.0, 0.7))
            m.castShadows = true
        end
    end

    local b = fence:CreateComponent("RigidBody", LOCAL)
    b:SetCollisionLayer(1)
    local s = fence:CreateComponent("CollisionShape", LOCAL)
    s:SetBox(size)
end

-- ============================================================================
-- 障碍物（统一创建）
-- ============================================================================

function Shared.CreateObstacle(scene, obs, isServer)
    local pos   = obs.pos
    local scale = obs.scale
    local name  = obs.name

    local node = scene:CreateChild(name, LOCAL)
    -- 碰撞体位置：底部贴合地形表面
    local terrainY = Shared.GetTerrainHeightAt(pos.x, pos.z)
    node.position = Vector3(pos.x, terrainY + scale.y / 2, pos.z)

    -- 查找是否有对应的 3D 模型
    local modelInfo = obs.modelKey and Config.Models[obs.modelKey] or nil

    if not isServer then
        if modelInfo then
            -- ===== 使用导入的 3D 模型 =====
            local visualNode = node:CreateChild("Visual", LOCAL)
            local ms = obs.modelScale or 1.0
            visualNode.scale = Vector3(ms, ms, ms)

            -- 支持模型旋转修正（如饮水池需要转正）
            if obs.modelRotation then
                visualNode.rotation = obs.modelRotation
            end

            local m = visualNode:CreateComponent("StaticModel", LOCAL)
            m:SetModel(cache:GetResource("Model", modelInfo.model))
            m:SetMaterial(cache:GetResource("Material", modelInfo.material))
            m.castShadows = true

            -- 用世界包围盒计算底部偏移，让模型底部贴地（y=0）
            local worldBB = m.worldBoundingBox
            local worldMinY = worldBB.min.y
            visualNode.position = Vector3(
                visualNode.position.x,
                visualNode.position.y + (node.position.y - scale.y / 2) - worldMinY,
                visualNode.position.z
            )
        else
            -- ===== 回退到基础形状 =====
            node.scale = scale
            local m = node:CreateComponent("StaticModel", LOCAL)
            m:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            m:SetMaterial(Shared.CreatePBRMaterial(Config.Colors.Rock, 0.0, 0.7))
            m.castShadows = true
        end
    end

    -- ===== 物理碰撞体（装饰物可跳过） =====
    if not obs.noCollision then
        local b = node:CreateComponent("RigidBody", LOCAL)
        b:SetCollisionLayer(1)
        local s = node:CreateComponent("CollisionShape", LOCAL)

        if modelInfo and modelInfo.footprintRadius then
            -- 使用 footprintRadius 精确设置碰撞体（与 BuildObstacleColliders 一致）
            local ms = obs.modelScale or 1.0
            local dia = modelInfo.footprintRadius * 2 * ms
            local h = scale.y  -- 高度仍用 obs.scale.y
            if string.find(name, "Rock") or string.find(name, "Barrel") then
                s:SetSphere(dia)
            else
                s:SetBox(Vector3(dia, h, dia))
            end
        elseif modelInfo then
            -- 有模型但没有 footprintRadius，回退到 obs.scale
            if string.find(name, "Rock") or string.find(name, "Barrel") then
                s:SetSphere(math.max(scale.x, scale.z))
            else
                s:SetBox(scale)
            end
        else
            -- 无模型的基础形状
            if string.find(name, "Rock") or string.find(name, "Barrel") then
                s:SetSphere(1.0)
            else
                s:SetBox(Vector3(1, 1, 1))
            end
        end
    end
end

-- ============================================================================
-- 面包屑道具
-- ============================================================================

function Shared.CreateBreadcrumb(scene, pos, isServer)
    local node = scene:CreateChild("Breadcrumb", LOCAL)
    node.position = pos
    node.scale = Vector3(0.2, 0.2, 0.2)

    if not isServer then
        local m = node:CreateComponent("StaticModel", LOCAL)
        m:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local mat = Shared.CreatePBRMaterial(Config.Colors.Breadcrumb, 0.0, 0.4)
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.8, 0.6, 0.1)))
        m:SetMaterial(mat)
        m.castShadows = false
    end

    -- 触发器检测
    local b = node:CreateComponent("RigidBody", LOCAL)
    b.trigger = true
    b:SetCollisionLayer(2)
    local s = node:CreateComponent("CollisionShape", LOCAL)
    s:SetSphere(3.0)  -- 拾取范围较大
end

-- ============================================================================
-- 注册远程事件
-- ============================================================================

function Shared.RegisterEvents()
    for _, eventName in pairs(Config.EVENTS) do
        network:RegisterRemoteEvent(eventName)
    end
end

-- ============================================================================
-- 固定等距相机设置
-- ============================================================================

function Shared.SetupIsometricCamera(cameraNode)
    local cam = Config.Camera
    -- 从目标点出发，按 yaw/pitch/distance 计算相机位置
    local yawRad   = math.rad(cam.Yaw)
    local pitchRad = math.rad(-cam.Pitch)  -- pitch 是负数(向下)，取反得正

    local horizontalDist = cam.Distance * math.cos(pitchRad)
    local verticalDist   = cam.Distance * math.sin(pitchRad)

    local offsetX = horizontalDist * math.sin(yawRad)
    local offsetZ = horizontalDist * math.cos(yawRad)

    local camPos = Vector3(
        cam.TargetPos.x - offsetX,
        cam.TargetPos.y + verticalDist,
        cam.TargetPos.z - offsetZ
    )

    cameraNode.position = camPos

    -- 使用 LookAt 直接朝向目标点（最可靠）
    local targetPos = Vector3(cam.TargetPos.x, cam.TargetPos.y, cam.TargetPos.z)
    cameraNode:LookAt(targetPos)

    local camera = cameraNode:GetComponent("Camera")
    if camera then
        camera.fov = cam.Fov
        camera.nearClip = cam.NearClip
        camera.farClip = cam.FarClip
    end

    print(string.format("[Shared] 相机位置: (%.1f, %.1f, %.1f) 看向: (%.1f, %.1f, %.1f)",
        camPos.x, camPos.y, camPos.z, targetPos.x, targetPos.y, targetPos.z))
end

-- ============================================================================
-- 游戏模式相机跟随（玩家接近边缘时相机缓动偏移）
-- ============================================================================

--- 当前相机目标偏移（相对于 Config.Camera.TargetPos 的 XZ 偏移）
Shared.cameraOffset = { x = 0, z = 0 }

--- 更新等距相机跟随（视锥感知 + 紧急度 + 硬约束）
--- 农场内轻柔跟随；接近画面边缘时逐渐加强；硬约束保证永不出画面
--- @param cameraNode Node
--- @param playerX number 玩家世界 X
--- @param playerZ number 玩家世界 Z
--- @param dt number 帧时间
function Shared.UpdateCameraFollow(cameraNode, playerX, playerZ, dt)
    local cam = Config.Camera
    local centerX = cam.TargetPos.x
    local centerZ = cam.TargetPos.z

    -- ── 1. 根据相机参数计算地面可视区域 ──
    local fovRad   = math.rad(cam.Fov)
    local pitchRad = math.rad(math.abs(cam.Pitch))
    local halfFov  = fovRad / 2
    local yawRad   = math.rad(cam.Yaw)
    local camH     = cam.Distance * math.sin(pitchRad)       -- 相机海拔
    local camGD    = cam.Distance * math.cos(pitchRad)       -- 相机在地面的投影距离
    local aspect   = graphics:GetWidth() / graphics:GetHeight()

    -- Z轴（沿相机前方）可视范围——斜视角导致近端窄、远端宽
    local nearAng  = math.min(pitchRad + halfFov, math.rad(88))
    local farAng   = math.max(pitchRad - halfFov, math.rad(1))
    local nearGD   = camH / math.tan(nearAng)                -- 近端地面距离（靠近相机）
    local farGD    = camH / math.tan(farAng)                 -- 远端地面距离（远离相机）
    local visNearZ = -(camGD - nearGD)                       -- 负值：目标后方（靠近相机）
    local visFarZ  = farGD - camGD                           -- 正值：目标前方（远离相机）

    -- X轴：取近端（最窄处）保证安全
    local nearCamD = camH / math.sin(nearAng)
    local visHalfX = nearCamD * math.tan(halfFov) * aspect

    -- 安全边距：玩家至少距画面边缘 margin 米
    local margin   = 2.0
    local safeNear = visNearZ + margin                       -- 例如 -6.3+2 = -4.3
    local safeFar  = visFarZ  - margin                       -- 例如 10.9-2 = 8.9
    local safeHX   = visHalfX - margin                       -- 例如 9.8-2 = 7.8

    -- ── 2. 投影到相机坐标系 ──
    local fwdX, fwdZ     = math.sin(yawRad), math.cos(yawRad)
    local rightX, rightZ = math.cos(yawRad), -math.sin(yawRad)

    local curLookX = centerX + Shared.cameraOffset.x
    local curLookZ = centerZ + Shared.cameraOffset.z
    local offX = playerX - curLookX
    local offZ = playerZ - curLookZ
    local projFwd   = offX * fwdX + offZ * fwdZ              -- 沿相机前方
    local projRight = offX * rightX + offZ * rightZ           -- 沿相机右方

    -- ── 3. 计算紧急度（0=舒适区中心, 1=安全边界）──
    local comfortFrac = 0.5                                   -- 舒适区占安全区 50%
    local uR = 0
    if safeHX > 0 then
        uR = math.max(0, (math.abs(projRight) - safeHX * comfortFrac) / (safeHX * (1 - comfortFrac)))
    end
    local uF = 0
    if projFwd < 0 and math.abs(safeNear) > 0 then
        uF = math.max(0, (math.abs(projFwd) - math.abs(safeNear) * comfortFrac)
                       / (math.abs(safeNear) * (1 - comfortFrac)))
    elseif projFwd > 0 and safeFar > 0 then
        uF = math.max(0, (projFwd - safeFar * comfortFrac) / (safeFar * (1 - comfortFrac)))
    end
    local urgency = math.min(1.0, math.max(uR, uF))

    -- ── 4. 跟随强度与速度随紧急度插值 ──
    local strength = 0.15 + 0.85 * urgency                   -- 15%轻柔 → 100%锁定
    local speed    = 2.0  + 10.0 * urgency                   -- 2.0缓慢 → 12.0快速

    local targetOffX = (playerX - centerX) * strength
    local targetOffZ = (playerZ - centerZ) * strength

    local t = math.min(1.0, speed * dt)
    Shared.cameraOffset.x = Shared.cameraOffset.x + (targetOffX - Shared.cameraOffset.x) * t
    Shared.cameraOffset.z = Shared.cameraOffset.z + (targetOffZ - Shared.cameraOffset.z) * t

    -- ── 5. 硬约束：保证玩家永远在画面安全区内 ──
    local fLookX = centerX + Shared.cameraOffset.x
    local fLookZ = centerZ + Shared.cameraOffset.z
    local fOffX  = playerX - fLookX
    local fOffZ  = playerZ - fLookZ
    local fPF    = fOffX * fwdX + fOffZ * fwdZ
    local fPR    = fOffX * rightX + fOffZ * rightZ

    local adjFwd = 0
    if fPF > safeFar  then adjFwd = fPF - safeFar
    elseif fPF < safeNear then adjFwd = fPF - safeNear end
    local adjRight = 0
    if fPR > safeHX      then adjRight = fPR - safeHX
    elseif fPR < -safeHX then adjRight = fPR + safeHX end

    Shared.cameraOffset.x = Shared.cameraOffset.x + adjFwd * fwdX + adjRight * rightX
    Shared.cameraOffset.z = Shared.cameraOffset.z + adjFwd * fwdZ + adjRight * rightZ

    -- ── 6. 应用相机位置 ──
    local horizontalDist = cam.Distance * math.cos(pitchRad)
    local verticalDist   = cam.Distance * math.sin(pitchRad)
    local offsetXCam     = horizontalDist * math.sin(yawRad)
    local offsetZCam     = horizontalDist * math.cos(yawRad)

    local newTargetX = centerX + Shared.cameraOffset.x
    local newTargetZ = centerZ + Shared.cameraOffset.z

    cameraNode.position = Vector3(
        newTargetX - offsetXCam,
        cam.TargetPos.y + verticalDist,
        newTargetZ - offsetZCam
    )
    cameraNode:LookAt(Vector3(newTargetX, cam.TargetPos.y, newTargetZ))
end

--- 重置相机偏移（切回固定视角时调用）
function Shared.ResetCameraOffset()
    Shared.cameraOffset.x = 0
    Shared.cameraOffset.z = 0
end

-- ============================================================================
-- 碰撞检测 & 推开（脚本层，用于 kinematic 刚体）
-- ============================================================================

-- ============================================================================
-- 编辑器 → 服务端 同步机制
-- ============================================================================

--- 障碍物碰撞缓存脏标记（编辑器修改后置 true，服务端下一帧重建）
Shared.obstacleCollidersDirty = false

--- 标记障碍物碰撞缓存需要重建（MapEditor / TerrainEditor 调用）
function Shared.MarkObstacleCollidersDirty()
    Shared.obstacleCollidersDirty = true
end

--- 围栏段存活状态（动态管理，支持编辑器删除后同步碰撞体）
--- key: "right" | "top" | "bottom"，value: true/nil
Shared.fenceSegmentsAlive = { right = true, top = true, bottom = true }

--- 删除围栏段（按标签匹配）
--- @param label string 如 "围栏段1"、"围栏段2"、"围栏段3"
function Shared.RemoveFenceSegment(label)
    -- 围栏段编号对应：1=右段, 2=上段, 3=下段（按 ScanStructures 的枚举顺序）
    local segMap = { ["围栏段1"] = "right", ["围栏段2"] = "top", ["围栏段3"] = "bottom" }
    local segKey = segMap[label]
    if segKey then
        Shared.fenceSegmentsAlive[segKey] = nil
        Shared.obstacleCollidersDirty = true
        print(string.format("[Shared] 围栏段 '%s' → '%s' 已删除, 碰撞体将重建", label, segKey))
    else
        print(string.format("[Shared] 未知围栏段标签: '%s'", label))
    end
end

--- 按方向标识（side）删除围栏段碰撞（基于位置识别，比 label 编号更可靠）
---@param side string "right"|"top"|"bottom"
function Shared.RemoveFenceSegmentBySide(side)
    if Shared.fenceSegmentsAlive[side] then
        Shared.fenceSegmentsAlive[side] = nil
        Shared.obstacleCollidersDirty = true
        print(string.format("[Shared] 围栏段 side='%s' 已删除, 碰撞体将重建", side))
    else
        print(string.format("[Shared] 围栏段 side='%s' 不存在或已删除", side))
    end
end

--- 地形网格数据（TerrainEditor 写入，Server 读取）
--- 格式: terrainGrid[x][z] = "open" | "blocked" | "target"
Shared.terrainGrid = nil

--- 检查指定世界坐标是否为 blocked 地形（考虑碰撞半径）
--- 当 radius > 0 时，检查圆形范围覆盖的所有格子，任一为 blocked 即返回 true
---@param wx number 世界 X
---@param wz number 世界 Z
---@param radius number? 碰撞半径（默认 0，仅检查中心点）
---@return boolean
function Shared.IsTerrainBlocked(wx, wz, radius)
    if not Shared.terrainGrid then return false end
    local r = radius or 0
    local minGX = math.floor(wx - r)
    local maxGX = math.floor(wx + r)
    local minGZ = math.floor(wz - r)
    local maxGZ = math.floor(wz + r)
    for gx = minGX, maxGX do
        local row = Shared.terrainGrid[gx]
        if row then
            for gz = minGZ, maxGZ do
                if row[gz] == "blocked" then
                    return true
                end
            end
        else
            -- grid 范围外视为不阻挡（超出地图边界由 Clamp 处理）
        end
    end
    return false
end

--- 地形高度碰撞检测：当目标位置地形高度 >= maxPassHeight 时视为撞墙
--- 玩家 maxPassHeight=0.5m，鸭子 maxPassHeight=0.25m
---@param oldX number 当前 X 位置
---@param oldZ number 当前 Z 位置
---@param newX number 目标 X 位置
---@param newZ number 目标 Z 位置
---@param radius number 碰撞半径
---@param maxPassHeight number 可通行的最大地形高度 (m)
---@return number, number 修正后的 X, Z 位置
function Shared.ResolveTerrainHeightCollision(oldX, oldZ, newX, newZ, radius, maxPassHeight)
    -- 在指定位置周围采样（中心 + 碰撞边缘 4 方向），检查是否存在不可通行的地形
    local function isBlocked(px, pz)
        local sx = { px,          px + radius, px - radius, px,          px          }
        local sz = { pz,          pz,          pz,          pz + radius, pz - radius }
        for i = 1, 5 do
            local h = Shared.GetTerrainHeightAt(sx[i], sz[i])
            if h >= maxPassHeight then
                return true
            end
        end
        return false
    end

    -- 目标位置不被阻挡，直接通过
    if not isBlocked(newX, newZ) then
        return newX, newZ
    end

    -- 尝试沿墙滑行：仅移动 X 轴
    if not isBlocked(newX, oldZ) then
        return newX, oldZ
    end

    -- 尝试沿墙滑行：仅移动 Z 轴
    if not isBlocked(oldX, newZ) then
        return oldX, newZ
    end

    -- 全方向阻挡，保持原位
    return oldX, oldZ
end

--- 构建障碍物碰撞列表（圆形近似），调用一次缓存结果
--- 返回 { {x, z, radius}, ... }
function Shared.BuildObstacleColliders()
    local colliders = {}
    for _, obs in ipairs(Config.Level1.Obstacles) do
        if not obs.noCollision then
            local r
            local modelInfo = obs.modelKey and Config.Models[obs.modelKey] or nil
            if modelInfo and modelInfo.footprintRadius then
                -- 使用模型实际 XZ 碰撞半径 × modelScale（精确匹配视觉体积）
                r = modelInfo.footprintRadius * (obs.modelScale or 1.0)
            else
                -- 回退：使用 obs.scale 的最大 XZ 值的一半
                r = math.max(obs.scale.x, obs.scale.z) * 0.5
            end
            table.insert(colliders, { x = obs.pos.x, z = obs.pos.z, radius = r })
        end
    end
    -- 边界围墙碰撞体：动态扫描场景中实际存在的 WallSeg 节点
    -- 删除围墙段后碰撞体随之消失，支持编辑器开口
    if Shared.currentScene then
        local wallThick = 0.5
        local modelNaturalHeight = 0.22
        local modelNaturalWidth = 1.75
        for i = 0, Shared.currentScene:GetNumChildren(false) - 1 do
            local wallNode = Shared.currentScene:GetChild(i)
            if wallNode.name == "Wall" then
                local wallPos = wallNode.position
                local shape = wallNode:GetComponent("CollisionShape")
                if shape then
                    local wallSize = shape.size
                    local isHorizontal = (wallSize.x > wallSize.z)
                    local ms = wallSize.y / modelNaturalHeight
                    local segmentSpan = modelNaturalWidth * ms

                    -- 遍历 WallSeg 子节点
                    for j = 0, wallNode:GetNumChildren(false) - 1 do
                        local seg = wallNode:GetChild(j)
                        if seg.name == "WallSeg" then
                            local segLocalPos = seg.position
                            if isHorizontal then
                                local cx = wallPos.x + segLocalPos.x
                                local cz = wallPos.z
                                table.insert(colliders, { x = cx, z = cz,
                                    halfW = segmentSpan / 2, halfH = wallThick / 2, isBox = true })
                            else
                                local cx = wallPos.x
                                local cz = wallPos.z + segLocalPos.z
                                table.insert(colliders, { x = cx, z = cz,
                                    halfW = wallThick / 2, halfH = segmentSpan / 2, isBox = true })
                            end
                        end
                    end
                end
            end
        end
    end

    -- 围栏段碰撞体（U 形围栏三段，动态管理，支持编辑器删除）
    -- 碰撞范围必须与 CreateFenceSegment 的模型 tiling 视觉范围一致
    local ta = Config.Level1.TargetArea
    local cx, cz = ta.Center.x, ta.Center.z
    local hw, hh = ta.Size.x / 2, ta.Size.z / 2
    local fenceThick = 0.3
    local fenceH = 0.8

    -- 计算模型 tiling 的实际视觉半长度（与 CreateFenceSegment 逻辑一致）
    local modelNaturalHeight = 0.221
    local ms = fenceH / modelNaturalHeight
    local segmentSpan = 0.998 * ms  -- 每段覆盖的长度

    ---计算围栏 tiling 后的实际视觉半长度
    ---@param nominalLen number 围栏的名义长度（CreateTargetFence 中的 size.z 或 size.x）
    ---@return number visualHalfLen 实际视觉半长度
    ---@return number centerOffset 视觉中心相对于围栏中心的偏移
    local function calcFenceVisualExtent(nominalLen)
        local halfLen = nominalLen / 2
        local startOffset = -halfLen + segmentSpan / 2
        -- 找到最后一段的偏移
        local lastOffset = startOffset
        local segIdx = 0
        while true do
            local nextOffset = startOffset + (segIdx + 1) * segmentSpan
            if nextOffset > halfLen then break end
            lastOffset = nextOffset
            segIdx = segIdx + 1
        end
        -- 第一段和最后一段的视觉边缘
        local visualMin = startOffset - segmentSpan / 2
        local visualMax = lastOffset + segmentSpan / 2
        local visualCenter = (visualMin + visualMax) / 2
        local visualHalfLen = (visualMax - visualMin) / 2
        return visualHalfLen, visualCenter
    end

    local alive = Shared.fenceSegmentsAlive
    -- 右段（垂直围栏，fenceLength = ta.Size.z + fenceThick*2 = 5.6）
    if alive.right then
        local rightLen = ta.Size.z + fenceThick * 2
        local visualHalf, centerOff = calcFenceVisualExtent(rightLen)
        table.insert(colliders, { x = cx + hw + fenceThick / 2, z = cz + centerOff, halfW = fenceThick / 2, halfH = visualHalf, isBox = true })
    end
    -- 上段（水平围栏，fenceLength = ta.Size.x = 4）
    if alive.top then
        local topLen = ta.Size.x
        local visualHalf, centerOff = calcFenceVisualExtent(topLen)
        table.insert(colliders, { x = cx + centerOff, z = cz + hh + fenceThick / 2, halfW = visualHalf, halfH = fenceThick / 2, isBox = true })
    end
    -- 下段（水平围栏，fenceLength = ta.Size.x = 4）
    if alive.bottom then
        local bottomLen = ta.Size.x
        local visualHalf, centerOff = calcFenceVisualExtent(bottomLen)
        table.insert(colliders, { x = cx + centerOff, z = cz - hh - fenceThick / 2, halfW = visualHalf, halfH = fenceThick / 2, isBox = true })
    end
    return colliders
end

--- 将位置 (px, pz) 以半径 pr 推离所有障碍物碰撞体
--- @param px number
--- @param pz number
--- @param pr number 移动物体的碰撞半径
--- @param colliders table Shared.BuildObstacleColliders() 的返回值
--- @return number, number 修正后的 px, pz
function Shared.ResolveObstacleCollisions(px, pz, pr, colliders)
    for _, c in ipairs(colliders) do
        if c.isBox then
            -- AABB vs Circle 推开
            -- 找到 AABB 上最近点
            local closestX = Shared.Clamp(px, c.x - c.halfW, c.x + c.halfW)
            local closestZ = Shared.Clamp(pz, c.z - c.halfH, c.z + c.halfH)
            local dx = px - closestX
            local dz = pz - closestZ
            local dist = math.sqrt(dx * dx + dz * dz)
            if dist < pr and dist > 0.001 then
                local overlap = pr - dist
                px = px + (dx / dist) * overlap
                pz = pz + (dz / dist) * overlap
            elseif dist < 0.001 then
                -- 完全在内部，推出到最近的边
                local pushX = (pr + c.halfW) - math.abs(px - c.x)
                local pushZ = (pr + c.halfH) - math.abs(pz - c.z)
                if pushX < pushZ then
                    px = px + (px > c.x and pushX or -pushX)
                else
                    pz = pz + (pz > c.z and pushZ or -pushZ)
                end
            end
        else
            -- Circle vs Circle 推开
            local dx = px - c.x
            local dz = pz - c.z
            local dist = math.sqrt(dx * dx + dz * dz)
            local minDist = pr + c.radius
            if dist < minDist and dist > 0.001 then
                local overlap = minDist - dist
                px = px + (dx / dist) * overlap
                pz = pz + (dz / dist) * overlap
            end
        end
    end
    return px, pz
end

--- 两个圆形碰撞体互相推开，返回修正后的位置
--- @param ax number 物体A的x
--- @param az number 物体A的z
--- @param ar number 物体A的碰撞半径
--- @param bx number 物体B的x
--- @param bz number 物体B的z
--- @param br number 物体B的碰撞半径
--- @return number, number 修正后的 ax, az（只推开A）
function Shared.ResolveCircleCollision(ax, az, ar, bx, bz, br)
    local dx = ax - bx
    local dz = az - bz
    local dist = math.sqrt(dx * dx + dz * dz)
    local minDist = ar + br
    if dist < minDist and dist > 0.001 then
        local overlap = minDist - dist
        ax = ax + (dx / dist) * overlap
        az = az + (dz / dist) * overlap
    end
    return ax, az
end

-- ============================================================================
-- 农场外围环境
-- ============================================================================

function Shared.CreateExterior(scene, isServer)
    local E = Config.Exterior
    local L = Config.Level1

    -- ====== 外围大地面（比农场大很多，覆盖蓝色空白区域） ======
    local extFloor = scene:CreateChild("ExteriorFloor", LOCAL)
    -- 以农场中心为中心放置，高度与农场 Floor 一致（Y=-0.25, scaleY=0.5 → 顶面Y=0）
    extFloor.position = Vector3(L.MapWidth / 2, -0.25, L.MapHeight / 2)
    extFloor.scale = Vector3(E.GroundWidth, 0.5, E.GroundHeight)
    if not isServer then
        local m = extFloor:CreateComponent("StaticModel", LOCAL)
        m:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        -- 使用与农场内相同的草地颜色
        local grassMat = Material:new()
        grassMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        grassMat:SetShaderParameter("MatDiffColor", Variant(Color(0.25, 0.82, 0.05, 1.0)))
        grassMat:SetShaderParameter("Roughness", Variant(0.92))
        grassMat:SetShaderParameter("Metallic", Variant(0.0))
        m:SetMaterial(grassMat)
    end
    -- 外围地面碰撞体（让角色/鸭子在外围也能正常行走）
    local efb = extFloor:CreateComponent("RigidBody", LOCAL)
    efb:SetCollisionLayer(1)
    local efs = extFloor:CreateComponent("CollisionShape", LOCAL)
    efs:SetBox(Vector3(1, 1, 1))

    -- ====== 道路 ======
    if not isServer then
        for i, road in ipairs(E.Roads) do
            local roadNode = scene:CreateChild("Road" .. i, LOCAL)
            roadNode.position = road.center
            roadNode.scale = road.size
            local m = roadNode:CreateComponent("StaticModel", LOCAL)
            m:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            local roadMat = Material:new()
            roadMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
            roadMat:SetShaderParameter("MatDiffColor", Variant(road.color))
            roadMat:SetShaderParameter("Roughness", Variant(0.85))
            roadMat:SetShaderParameter("Metallic", Variant(0.0))
            m:SetMaterial(roadMat)
        end
    end

    -- ====== 外围装饰物（纯视觉，无碰撞） ======
    if not isServer then
        for _, dec in ipairs(E.Decorations) do
            local modelInfo = dec.modelKey and Config.Models[dec.modelKey] or nil
            if modelInfo then
                local node = scene:CreateChild(dec.name or ("Ext_" .. dec.modelKey), LOCAL)
                node.position = Vector3(dec.pos.x, 0, dec.pos.z)

                local visualNode = node:CreateChild("Visual", LOCAL)
                local ms = dec.modelScale or 1.0
                visualNode.scale = Vector3(ms, ms, ms)

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

    print("[Shared] Exterior environment created")
end

-- ============================================================================
-- 获取出生点
-- ============================================================================

function Shared.GetSpawnPoint(index)
    local pts = Config.Level1.SpawnPoints
    local i = ((index - 1) % #pts) + 1
    return pts[i]
end

return Shared
