-- ============================================================================
-- ClientSplash.lua — 客户端闪屏动画模块
-- 包含：NanoVG 闪屏初始化、渲染、更新、结束
-- ============================================================================

local ClientSplash = {}

local UI = require("urhox-libs/UI")

-- ============================================================================
-- 内部状态（自包含，不需要宿主共享）
-- ============================================================================
local splashVg_ = nil
local splashImage_ = -1
local splashImageW_ = 0
local splashImageH_ = 0
local splashTimer_ = 0
local splashActive_ = false

-- 动画时间轴常量
local SPLASH_ANIM_DURATION = 1.0   -- 旋转缩放入场（快速）
local SPLASH_HOLD_DURATION = 2.0   -- 标题静态展示
local SPLASH_FADE_DURATION = 1.0   -- 渐隐退出

-- 宿主回调
local getUIRoot_ = nil  -- fn() -> UIElement|nil

-- ============================================================================
-- 初始化
-- ============================================================================

--- 初始化模块
---@param helpers table { getUIRoot = fn() }
function ClientSplash.Init(helpers)
    getUIRoot_ = helpers.getUIRoot
end

--- 启动闪屏动画
function ClientSplash.Start()
    splashVg_ = nvgCreate(1)
    if splashVg_ == nil then
        print("[Client] 闪屏 NanoVG 创建失败")
        splashActive_ = false
        return
    end

    -- flag=0 加载（与引擎 UI 库一致，避免 KTX 格式不兼容）
    splashImage_ = nvgCreateImage(splashVg_, "image/标题.png", 0)
    if splashImage_ <= 0 then
        print("[Client] 标题图片加载失败")
        splashActive_ = false
        nvgDelete(splashVg_)
        splashVg_ = nil
        return
    end

    -- 硬编码原始 PNG 像素尺寸（nvgImageSize / Image 资源在 Web 平台不可靠）
    splashImageW_ = 2048
    splashImageH_ = 524
    print("[Client] 标题图片: " .. splashImageW_ .. "x" .. splashImageH_)

    SubscribeToEvent(splashVg_, "NanoVGRender", "HandleSplashRender")

    -- 完全移除 UI 根节点，确保闪屏期间不渲染任何 HUD
    UI.SetRoot(nil)

    splashTimer_ = 0
    splashActive_ = true
end

-- ============================================================================
-- 渲染（全局函数，由 NanoVGRender 事件回调）
-- ============================================================================

function HandleSplashRender(eventType, eventData)
    if not splashActive_ or splashVg_ == nil then return end

    local physW = graphics:GetWidth()
    local physH = graphics:GetHeight()
    local dpr = graphics:GetDPR()
    -- 使用逻辑分辨率 + DPR，确保高 DPI 屏下清晰渲染
    local screenW = physW / dpr
    local screenH = physH / dpr

    nvgBeginFrame(splashVg_, screenW, screenH, dpr)

    -- 三阶段时间轴：入场动画 → 静态展示 → 渐隐退出
    local animScale = 1.0
    local rotation = 0
    local alpha = 1.0

    if splashTimer_ < SPLASH_ANIM_DURATION then
        -- 阶段1：旋转缩放入场
        local animProgress = splashTimer_ / SPLASH_ANIM_DURATION
        local eased = 1.0 - (1.0 - animProgress) ^ 3  -- ease-out cubic
        animScale = 0.3 + 0.7 * eased       -- 从 30% → 100%
        rotation = (1.0 - eased) * math.pi * 2  -- 从 360° → 0°
    elseif splashTimer_ < SPLASH_ANIM_DURATION + SPLASH_HOLD_DURATION then
        -- 阶段2：静态展示（标题完整可见）
        animScale = 1.0
        rotation = 0
    else
        -- 阶段3：渐隐退出
        local fadeProgress = (splashTimer_ - SPLASH_ANIM_DURATION - SPLASH_HOLD_DURATION) / SPLASH_FADE_DURATION
        fadeProgress = math.min(fadeProgress, 1.0)
        alpha = 1.0 - fadeProgress
    end

    nvgGlobalAlpha(splashVg_, alpha)

    -- 白色背景（覆盖全屏）
    nvgBeginPath(splashVg_)
    nvgRect(splashVg_, 0, 0, screenW, screenH)
    nvgFillColor(splashVg_, nvgRGBA(255, 255, 255, 255))
    nvgFill(splashVg_)

    -- 计算图片目标尺寸（屏幕像素宽度 61.8%，保持原始比例，无形变）
    local targetW = physW * 0.618 / dpr
    local imgAspect = splashImageW_ / splashImageH_
    local targetH = targetW / imgAspect

    local drawW = targetW * animScale
    local drawH = targetH * animScale

    -- 居中旋转绘制
    local cx = screenW / 2
    local cy = screenH / 2

    nvgSave(splashVg_)
    nvgTranslate(splashVg_, cx, cy)
    nvgRotate(splashVg_, rotation)

    local imgPaint = nvgImagePattern(
        splashVg_, -drawW / 2, -drawH / 2, drawW, drawH, 0, splashImage_, 1.0
    )
    nvgBeginPath(splashVg_)
    nvgRect(splashVg_, -drawW / 2, -drawH / 2, drawW, drawH)
    nvgFillPaint(splashVg_, imgPaint)
    nvgFill(splashVg_)

    nvgRestore(splashVg_)
    nvgEndFrame(splashVg_)
end

-- ============================================================================
-- 更新 & 结束
-- ============================================================================

--- 每帧更新闪屏动画
---@param dt number
function ClientSplash.Update(dt)
    if not splashActive_ then return end

    splashTimer_ = splashTimer_ + dt

    if splashTimer_ >= SPLASH_ANIM_DURATION + SPLASH_HOLD_DURATION + SPLASH_FADE_DURATION then
        ClientSplash.End()
    end
end

--- 结束闪屏（可由外部提前调用）
function ClientSplash.End()
    splashActive_ = false

    if splashVg_ then
        if splashImage_ > 0 then
            nvgDeleteImage(splashVg_, splashImage_)
        end
        nvgDelete(splashVg_)
        splashVg_ = nil
    end

    -- 恢复游戏 HUD（重新设置 UI 根节点）
    local uiRoot = getUIRoot_ and getUIRoot_()
    if uiRoot then
        UI.SetRoot(uiRoot)
    end

    print("[Client] 闪屏结束，进入游戏")
end

--- 闪屏是否正在播放
---@return boolean
function ClientSplash.IsActive()
    return splashActive_
end

return ClientSplash
