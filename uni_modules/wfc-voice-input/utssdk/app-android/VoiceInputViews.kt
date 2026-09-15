/*
 * Copyright (c) 2026 WildFireChat. All rights reserved.
 */

package uts.sdk.modules.wfcVoiceInput

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ArgbEvaluator
import android.animation.TimeInterpolator
import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.drawable.Drawable
import android.os.SystemClock
import android.util.TypedValue
import android.view.View
import android.view.animation.AccelerateInterpolator
import android.view.animation.DecelerateInterpolator
import android.widget.FrameLayout
import java.util.Random
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/*
 * 按住说话浮层上自绘的控件，移植自 ../android-chat 的 audio/VoiceRecordBottomView.java、VoiceBubbleLayout.java、
 * VoiceInputBackground.java、VoiceWaveView.java。
 * 插件里不放资源文件（插件的 res 只在自定义基座生效）：文案从配置里来，图标（android-chat 的 vector drawable）改成代码画。
 */

internal const val ZONE_SEND = 0
internal const val ZONE_CANCEL = 1
internal const val ZONE_TEXT = 2

private fun withAlpha(color: Int, alpha: Float): Int {
    return Color.argb((Color.alpha(color) * max(0f, min(1f, alpha))).roundToInt(), Color.red(color), Color.green(color), Color.blue(color))
}

private fun toDegrees(radians: Float): Float {
    return (radians * 180.0 / PI).toFloat()
}

/**
 * 动画正常结束（没有被取消）时执行
 */
internal class EndListener(private val endAction: (() -> Unit)?) : AnimatorListenerAdapter() {
    private var canceled = false

    override fun onAnimationCancel(animation: Animator) {
        canceled = true
    }

    override fun onAnimationEnd(animation: Animator) {
        if (!canceled) {
            endAction?.invoke()
        }
    }
}

/**
 * 按住说话时的底部操作区：最下方弧形的「松开 发送」区域，上方左右两条弧形的「取消」和「转文字」按钮
 *
 * 通过 [zoneAt] 判断手指所在的目标，[selectZone] 让对应的按钮平滑高亮
 */
internal class VoiceRecordBottomView(context: Context) : View(context) {

    companion object {
        // 配色参考微信深色模式，画在深灰背景上
        private val ARC_COLOR = 0xFF575757.toInt()
        private val ARC_SELECTED_TOP_COLOR = 0xFF636363.toInt()
        private val ARC_SELECTED_BOTTOM_COLOR = 0xFF808080.toInt()
        private val ARC_RIM_COLOR = 0xFF767676.toInt()
        private val ARC_LABEL_COLOR = 0xFFDDDDDD.toInt()
        private val PILL_COLOR = 0xFF575757.toInt()
        private val PILL_SELECTED_COLOR = 0xFF9A9A9A.toInt()
        private val PILL_LABEL_COLOR = 0xFFE6E6E6.toInt()
        private val SELECTED_LABEL_COLOR = 0xFF111111.toInt()
        private val HINT_COLOR = 0xFFD0D0D0.toInt()
    }

    private val density = resources.displayMetrics.density
    private val argbEvaluator = ArgbEvaluator()
    private val arcPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val arcSelectedPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val rimPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pillPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val arcLabelPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pillLabelPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val hintPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pillLabelTextSize = sp(17f)
    private val hintTextSize = sp(14f)
    private val textPath = Path()
    private val oval = RectF()

    private var voiceLabel = ""
    private var sendLabel = ""
    private var cancelLabel = ""
    private var cancelHint = ""
    private var textLabel = ""
    private var textHint = ""

    private var textZoneEnabled = false
    private var hasStage = false
    private var stageLeft = 0f
    private var stageRight = 0f
    private var stageWidth = 0f
    private var centerX = 0f

    // 底部弧形区域：圆心在底部中间下方的大圆
    private var arcTop = 0f
    private var arcRadius = 0f
    private var arcCenterY = 0f
    private var shaderHeight = 0

    // 两条弧形按钮的中线在同一个更大的圆上
    private var pillThickness = 0f
    private var pillGap = 0f
    private var pillRadius = 0f
    private var pillCenterY = 0f

    // 按钮文字中心到中线的水平距离
    private var labelOffsetX = 0f
    private var maxLabelWidth = 0f

    private var zone = ZONE_SEND

    // 各个目标的高亮程度，0~1，按 ZONE_* 索引
    private val selection = floatArrayOf(1f, 0f, 0f)
    private var selectionAnimator: ValueAnimator? = null

    // 入场进度，0 完全隐藏，1 完全显示
    private var appear = 0f
    private var appearAnimator: ValueAnimator? = null

    init {
        arcPaint.color = ARC_COLOR
        rimPaint.style = Paint.Style.STROKE
        rimPaint.strokeWidth = 2 * density
        rimPaint.color = ARC_RIM_COLOR
        pillPaint.style = Paint.Style.STROKE
        pillPaint.strokeCap = Paint.Cap.ROUND

        arcLabelPaint.textAlign = Paint.Align.CENTER
        arcLabelPaint.textSize = sp(18f)
        pillLabelPaint.textSize = pillLabelTextSize
        hintPaint.textSize = hintTextSize
    }

    fun setLabels(voice: String, send: String, cancel: String, cancelHint: String, text: String, textHint: String) {
        voiceLabel = voice
        sendLabel = send
        cancelLabel = cancel
        this.cancelHint = cancelHint
        textLabel = text
        this.textHint = textHint
        invalidate()
    }

    fun setSpeechToTextEnabled(enabled: Boolean) {
        textZoneEnabled = enabled
        invalidate()
    }

    /**
     * 设置操作区的位置
     *
     * @param left   左边界，本 View 坐标
     * @param right  右边界，本 View 坐标
     * @param arcTop 底部弧形区域最高点的 y 坐标，按住说话按钮需要在弧形区域内
     */
    fun setStage(left: Float, right: Float, arcTop: Float) {
        stageLeft = left
        stageRight = right
        stageWidth = right - left
        centerX = left + stageWidth / 2
        this.arcTop = arcTop
        arcRadius = stageWidth * 1.68f
        arcCenterY = arcTop + arcRadius
        shaderHeight = 0

        pillThickness = max(dp(56f), min(dp(72f), stageWidth * 0.17f))
        pillGap = dp(22f)
        pillRadius = stageWidth * 1.72f
        pillCenterY = arcTop - dp(16f) - pillThickness / 2 + pillRadius
        labelOffsetX = min(stageWidth * 0.29f, dp(170f))
        maxLabelWidth = max(dp(48f), 2 * min(labelOffsetX - pillGap / 2 - dp(12f), stageWidth / 2 - dp(8f) - labelOffsetX))
        hasStage = true
        invalidate()
    }

    /**
     * 弧形按钮上边缘最高点的 y 坐标
     */
    fun pillTop(): Float {
        return pillCenterY - pillRadius - pillThickness / 2
    }

    /**
     * 「取消」按钮文字中心的 x 坐标
     */
    fun cancelCenterX(): Float {
        return centerX - labelOffsetX
    }

    /**
     * 手指所在的目标
     *
     * @return ZONE_SEND、ZONE_CANCEL 或 ZONE_TEXT
     */
    fun zoneAt(x: Float, y: Float): Int {
        if (!hasStage) {
            return ZONE_SEND
        }
        val dx = x - centerX
        if (abs(dx) < arcRadius && y >= arcCenterY - sqrt(arcRadius * arcRadius - dx * dx)) {
            return ZONE_SEND
        }
        return if (textZoneEnabled && x >= centerX) ZONE_TEXT else ZONE_CANCEL
    }

    fun currentZone(): Int {
        return zone
    }

    fun selectZone(zone: Int) {
        if (this.zone == zone) {
            return
        }
        this.zone = zone
        val from = selection.clone()
        selectionAnimator?.cancel()
        val animator = ValueAnimator.ofFloat(0f, 1f)
        animator.duration = 220
        animator.interpolator = DecelerateInterpolator(1.5f)
        animator.addUpdateListener { animation ->
            val fraction = animation.animatedValue as Float
            for (i in selection.indices) {
                selection[i] = from[i] + ((if (i == zone) 1f else 0f) - from[i]) * fraction
            }
            invalidate()
        }
        selectionAnimator = animator
        animator.start()
    }

    /**
     * 恢复到未显示、选中发送的状态
     */
    fun reset() {
        selectionAnimator?.cancel()
        appearAnimator?.cancel()
        zone = ZONE_SEND
        selection[ZONE_SEND] = 1f
        selection[ZONE_CANCEL] = 0f
        selection[ZONE_TEXT] = 0f
        appear = 0f
        invalidate()
    }

    /**
     * 弧形区域和按钮从底部升起
     */
    fun show() {
        animateAppear(1f, 340, DecelerateInterpolator(2f), null)
    }

    /**
     * 按钮和弧形区域落回底部
     */
    fun hide(endAction: (() -> Unit)?) {
        animateAppear(0f, 220, AccelerateInterpolator(1.5f), endAction)
    }

    private fun animateAppear(target: Float, duration: Long, interpolator: TimeInterpolator, endAction: (() -> Unit)?) {
        appearAnimator?.cancel()
        val animator = ValueAnimator.ofFloat(appear, target)
        animator.duration = duration
        animator.interpolator = interpolator
        animator.addUpdateListener { animation ->
            appear = animation.animatedValue as Float
            invalidate()
        }
        animator.addListener(EndListener(endAction))
        appearAnimator = animator
        animator.start()
    }

    override fun onDetachedFromWindow() {
        super.onDetachedFromWindow()
        selectionAnimator?.cancel()
        appearAnimator?.cancel()
    }

    override fun onDraw(canvas: Canvas) {
        if (!hasStage || appear <= 0) {
            return
        }
        canvas.save()
        canvas.clipRect(stageLeft, 0f, stageRight, height.toFloat())
        drawArcArea(canvas)
        // 按钮比弧形区域稍晚升起，更早落下
        val pillAppear = max(0f, min(1f, (appear - 0.15f) / 0.85f))
        if (pillAppear > 0) {
            canvas.save()
            canvas.translate(0f, (1 - pillAppear) * (height - pillTop()))
            drawPill(canvas, true, selection[ZONE_CANCEL], cancelLabel, cancelHint, pillAppear)
            if (textZoneEnabled) {
                drawPill(canvas, false, selection[ZONE_TEXT], textLabel, textHint, pillAppear)
            }
            canvas.restore()
        }
        canvas.restore()
    }

    private fun drawArcArea(canvas: Canvas) {
        if (shaderHeight != height) {
            shaderHeight = height
            arcSelectedPaint.shader = LinearGradient(0f, arcTop, 0f, max(arcTop + 1, shaderHeight.toFloat()),
                ARC_SELECTED_TOP_COLOR, ARC_SELECTED_BOTTOM_COLOR, Shader.TileMode.CLAMP)
        }
        val selected = selection[ZONE_SEND]
        canvas.save()
        canvas.translate(0f, (1 - appear) * (height - arcTop))
        canvas.drawCircle(centerX, arcCenterY, arcRadius, arcPaint)
        if (selected > 0) {
            arcSelectedPaint.alpha = (255 * selected).roundToInt()
            canvas.drawCircle(centerX, arcCenterY, arcRadius, arcSelectedPaint)
            rimPaint.alpha = (255 * selected).roundToInt()
            canvas.drawCircle(centerX, arcCenterY, arcRadius - density, rimPaint)
        }
        // 「语音」和「松开 发送」交叉淡入淡出，文字同时轻微上移
        val labelCenterY = arcTop + dp(44f) - dp(8f) * selected
        drawCenteredText(canvas, voiceLabel, labelCenterY, withAlpha(ARC_LABEL_COLOR, 1 - selected))
        drawCenteredText(canvas, sendLabel, labelCenterY, withAlpha(SELECTED_LABEL_COLOR, selected))
        canvas.restore()
    }

    private fun drawCenteredText(canvas: Canvas, text: String, centerY: Float, color: Int) {
        if (Color.alpha(color) == 0 || text.isEmpty()) {
            return
        }
        arcLabelPaint.color = color
        val fm = arcLabelPaint.fontMetrics
        canvas.drawText(text, centerX, centerY - (fm.ascent + fm.descent) / 2, arcLabelPaint)
    }

    private fun drawPill(canvas: Canvas, left: Boolean, selected: Float, label: String, hint: String, alpha: Float) {
        // 选中时稍微变粗
        val thickness = pillThickness * (1 + 0.06f * selected)
        val innerDegrees = toDegrees(asin((pillGap / 2 + pillThickness / 2) / pillRadius))
        val outerDegrees = toDegrees(asin(min(1f, (stageWidth / 2 + thickness) / pillRadius)))
        // 圆的最高点是 270 度，角度顺时针增加，弧线从左往右画
        val startDegrees = if (left) 270 - outerDegrees else 270 + innerDegrees
        oval.set(centerX - pillRadius, pillCenterY - pillRadius, centerX + pillRadius, pillCenterY + pillRadius)
        pillPaint.strokeWidth = thickness
        pillPaint.color = withAlpha(blend(PILL_COLOR, PILL_SELECTED_COLOR, selected), alpha)
        canvas.drawArc(oval, startDegrees, outerDegrees - innerDegrees, false, pillPaint)

        val offsetX = if (left) -labelOffsetX else labelOffsetX
        pillLabelPaint.color = withAlpha(blend(PILL_LABEL_COLOR, SELECTED_LABEL_COLOR, selected), alpha)
        drawTextOnArc(canvas, label, pillLabelPaint, pillLabelTextSize, pillRadius, offsetX, maxLabelWidth)
        if (selected > 0) {
            // 按钮上方的提示随高亮淡入，并向上浮起
            hintPaint.color = withAlpha(HINT_COLOR, alpha * selected)
            val hintRadius = pillRadius + thickness / 2 + dp(24f) - dp(8f) * (1 - selected)
            drawTextOnArc(canvas, hint, hintPaint, hintTextSize, hintRadius, offsetX, maxLabelWidth + dp(40f))
        }
    }

    /**
     * 沿以 (centerX, pillCenterY) 为圆心的圆弧绘制文字，文字中心在 centerX + offsetX 附近，太长时缩小字号
     */
    private fun drawTextOnArc(canvas: Canvas, text: String, paint: Paint, textSize: Float, radius: Float, offsetX: Float, maxWidth: Float) {
        if (text.isEmpty()) {
            return
        }
        paint.textSize = textSize
        var width = paint.measureText(text)
        if (width > maxWidth) {
            paint.textSize = textSize * maxWidth / width
            width = maxWidth
        }
        // 路径两端多留一段，避免文字末尾超出路径被丢弃
        val margin = dp(24f)
        val centerDegrees = 270 + toDegrees(asin(max(-1f, min(1f, offsetX / radius))))
        val halfDegrees = toDegrees((width / 2 + margin) / radius)
        oval.set(centerX - radius, pillCenterY - radius, centerX + radius, pillCenterY + radius)
        textPath.reset()
        textPath.addArc(oval, centerDegrees - halfDegrees, halfDegrees * 2)
        val fm = paint.fontMetrics
        canvas.drawTextOnPath(text, textPath, margin, -(fm.ascent + fm.descent) / 2, paint)
    }

    private fun blend(from: Int, to: Int, fraction: Float): Int {
        return argbEvaluator.evaluate(fraction, from, to) as Int
    }

    private fun dp(value: Float): Float {
        return value * density
    }

    private fun sp(value: Float): Float {
        return TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, value, resources.displayMetrics)
    }
}

/**
 * 语音输入气泡：圆角矩形，底部有一个指向当前手势目标的小尖角
 *
 * 尖角画在底部 [tailHeight] 的范围内，paddingBottom 需要包含这部分高度
 */
internal class VoiceBubbleLayout(context: Context) : FrameLayout(context) {
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val tailPath = Path()
    private val bodyRect = RectF()
    private val density = resources.displayMetrics.density
    private val radius = 18 * density
    private val tailWidth = 18 * density
    val tailHeight = 8 * density

    // 尖角中心相对于气泡左边的位置，小于 0 时居中
    private var tailCenterX = -1f

    init {
        setWillNotDraw(false)
        paint.color = 0xFF95EC69.toInt()
    }

    fun setBubbleColor(color: Int) {
        paint.color = color
        invalidate()
    }

    fun setTailX(tailX: Float) {
        tailCenterX = tailX
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat()
        val h = height.toFloat()
        val bodyBottom = h - tailHeight
        if (w <= 0 || bodyBottom <= 0) {
            return
        }
        val r = min(radius, min(w, bodyBottom) / 2)
        bodyRect.set(0f, 0f, w, bodyBottom)
        canvas.drawRoundRect(bodyRect, r, r, paint)

        val half = tailWidth / 2
        var x = if (tailCenterX < 0) w / 2 else tailCenterX
        x = max(min(r + half, w / 2), min(max(w - r - half, w / 2), x))
        // 尖角向上多画 1px 与气泡主体重叠，避免抗锯齿留下接缝；尖端画成小圆角
        val tip = 1.5f * density
        tailPath.reset()
        tailPath.moveTo(x - half, bodyBottom - 1)
        tailPath.lineTo(x - tip, h - density)
        tailPath.quadTo(x, h, x + tip, h - density)
        tailPath.lineTo(x + half, bodyBottom - 1)
        tailPath.close()
        canvas.drawPath(tailPath, paint)
    }
}

/**
 * 语音输入浮层的背景：整屏半透明的深色遮罩，底部再叠一块深灰色背景，上边缘从透明线性渐变到不透明。
 * 录音时深灰背景从弧形按钮处开始，编辑文字时升到气泡下方
 */
internal class VoiceInputBackground(private val fadeHeight: Float) : Drawable() {

    companion object {
        private val DIM_COLOR = 0xCC111111.toInt()
        private val PANEL_COLOR = 0xFF444444.toInt()
    }

    private val dimPaint = Paint()
    private val panelPaint = Paint()
    private var stageLeft = 0f
    private var stageRight = 0f
    private var showProgress = 0f
    private var panelShader: LinearGradient? = null

    // panelShader 创建时的 panelTop
    private var shaderPanelTop = 0f

    /** 深灰背景完全不透明处的 y 坐标 */
    var panelTop = 0f
        set(value) {
            field = value
            invalidateSelf()
        }

    init {
        dimPaint.color = DIM_COLOR
    }

    /**
     * 深灰背景的左右边界
     */
    fun setStage(left: Float, right: Float) {
        stageLeft = left
        stageRight = right
        invalidateSelf()
    }

    /**
     * @param progress 显示程度，0 完全透明，1 完全显示
     */
    fun setProgress(progress: Float) {
        showProgress = progress
        invalidateSelf()
    }

    override fun draw(canvas: Canvas) {
        if (showProgress <= 0) {
            return
        }
        val rect = bounds
        dimPaint.alpha = (Color.alpha(DIM_COLOR) * showProgress).roundToInt()
        canvas.drawRect(rect, dimPaint)
        if (stageRight <= stageLeft) {
            return
        }
        val fadeTop = panelTop - fadeHeight
        if (panelShader == null || shaderPanelTop != panelTop) {
            // 按实际坐标创建渐变，不用 localMatrix：系统强制深色时会重建渐变并丢掉 localMatrix，渐变变成一条硬边
            val shader = LinearGradient(0f, fadeTop, 0f, panelTop, PANEL_COLOR and 0x00FFFFFF, PANEL_COLOR, Shader.TileMode.CLAMP)
            panelShader = shader
            panelPaint.shader = shader
            shaderPanelTop = panelTop
        }
        panelPaint.alpha = (255 * showProgress).roundToInt()
        canvas.drawRect(stageLeft, max(rect.top.toFloat(), fadeTop), stageRight, rect.bottom.toFloat(), panelPaint)
    }

    override fun setAlpha(alpha: Int) {
        // 透明度由 setProgress 控制
    }

    override fun setColorFilter(colorFilter: ColorFilter?) {
    }

    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int {
        return PixelFormat.TRANSLUCENT
    }
}

/**
 * 语音输入的声波：一排圆角竖条，中间高两边低，高度随音量平滑起落；录音结束、等待识别结果时换成三个依次跳动的圆点
 */
internal class VoiceWaveView(context: Context) : View(context) {

    companion object {
        // 竖条升高、回落的时间常数，回落慢一些更自然
        private const val RISE_TIME_MS = 50f
        private const val FALL_TIME_MS = 140f

        // 声波和等待动画之间切换的时间常数
        private const val LOADING_SWITCH_TIME_MS = 100f
        private const val LOADING_DOT_COUNT = 3
    }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val random = Random()
    private val density = resources.displayMetrics.density
    private val barWidth = 2 * density
    private val barGap = 2.2f * density
    private val minBarHeight = 3 * density
    private val dotRadius = 2.6f * density
    private val dotSpacing = 9 * density
    private var barColorValue = Color.WHITE

    private var levelValue = 0f
    private var loadingValue = false

    // 等待动画的显示程度，0 显示声波，1 显示等待动画
    private var loadingProgress = 0f

    // 每个竖条当前和目标的高度比例，0~1
    private var heights = FloatArray(0)
    private var targets = FloatArray(0)
    private var lastFrameTime = 0L

    fun setBarColor(color: Int) {
        barColorValue = color
        invalidate()
    }

    /**
     * @param level 音量，0~1
     */
    fun setLevel(level: Float) {
        levelValue = max(0f, min(1f, level))
        updateTargets()
    }

    /**
     * @param loading 是否显示等待识别结果的动画
     */
    fun setLoading(loading: Boolean) {
        if (loadingValue != loading) {
            loadingValue = loading
            invalidate()
        }
    }

    private fun updateTargets() {
        val count = targets.size
        for (i in 0 until count) {
            val x = if (count == 1) 0f else i.toFloat() / (count - 1) * 2 - 1
            val envelope = 0.3f + 0.7f * exp(-x * x * 2.5f)
            val jitter = 0.5f + 0.5f * random.nextFloat()
            // 不说话时也保留一点起伏
            val idle = 0.06f + 0.1f * random.nextFloat() * envelope
            targets[i] = min(1f, idle + levelValue * envelope * jitter * 1.2f)
        }
        invalidate()
    }

    private fun ensureBars() {
        val count = max(1, ((width + barGap) / (barWidth + barGap)).toInt())
        if (count == heights.size) {
            return
        }
        // 宽度变化时按比例重采样，形变过程中竖条高度不会突变
        val newHeights = FloatArray(count)
        for (i in 0 until count) {
            newHeights[i] = if (heights.isEmpty()) 0f else heights[min(heights.size - 1, i * heights.size / count)]
        }
        heights = newHeights
        targets = FloatArray(count)
        updateTargets()
    }

    override fun onDraw(canvas: Canvas) {
        if (width == 0 || height == 0) {
            return
        }
        ensureBars()
        val now = SystemClock.uptimeMillis()
        val dt = if (lastFrameTime == 0L) 16f else min(64f, (now - lastFrameTime).toFloat())
        lastFrameTime = now
        loadingProgress += ((if (loadingValue) 1f else 0f) - loadingProgress) * (1 - exp(-dt / LOADING_SWITCH_TIME_MS))

        val colorAlpha = Color.alpha(barColorValue)
        paint.color = barColorValue
        val count = heights.size
        val totalWidth = count * barWidth + (count - 1) * barGap
        var left = (width - totalWidth) / 2
        val centerY = height / 2f
        val range = max(0f, height - minBarHeight)
        // 等待识别结果时竖条落下并淡出
        val barAlpha = 1 - loadingProgress
        paint.alpha = (colorAlpha * barAlpha).roundToInt()
        for (i in 0 until count) {
            val target = if (loadingValue) 0f else targets[i]
            val timeConstant = if (target > heights[i]) RISE_TIME_MS else FALL_TIME_MS
            heights[i] += (target - heights[i]) * (1 - exp(-dt / timeConstant))
            if (barAlpha > 0.01f) {
                val h = minBarHeight + range * heights[i]
                canvas.drawRoundRect(left, centerY - h / 2, left + barWidth, centerY + h / 2, barWidth / 2, barWidth / 2, paint)
            }
            left += barWidth + barGap
        }
        if (loadingProgress > 0.01f) {
            // 三个圆点从左到右依次变大变亮
            val phase = now / 1000.0 * PI * 2 * 1.2
            val centerX = width / 2f
            for (i in 0 until LOADING_DOT_COUNT) {
                val pulse = 0.5f + 0.5f * sin(phase - i * 0.9).toFloat()
                val radius = dotRadius * (0.7f + 0.3f * pulse) * (0.5f + 0.5f * loadingProgress)
                paint.alpha = (colorAlpha * loadingProgress * (0.4f + 0.6f * pulse)).roundToInt()
                canvas.drawCircle(centerX + (i - (LOADING_DOT_COUNT - 1) / 2f) * dotSpacing, centerY, radius, paint)
            }
        }
        if (isShown) {
            postInvalidateOnAnimation()
        } else {
            lastFrameTime = 0
        }
    }
}

/**
 * 浮层上的图标，按 android-chat 的 vector drawable 用代码画：关闭、声音、圆形感叹号
 */
internal class VoiceIconDrawable(context: Context, private val type: Int) : Drawable() {

    companion object {
        const val CLOSE = 0
        const val SOUND = 1

        // 圆形感叹号，感叹号镂空，透出气泡的颜色
        const val WARNING = 2
    }

    private val density = context.resources.displayMetrics.density
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val path = Path()
    private val rect = RectF()
    private var iconColor = Color.WHITE

    fun setColor(color: Int) {
        iconColor = color
        invalidateSelf()
    }

    // 提示前面的感叹号是 TextView 的 compound drawable，要有固有尺寸；按钮里的图标由 ImageView 撑满
    override fun getIntrinsicWidth(): Int {
        return if (type == WARNING) (22 * density).roundToInt() else -1
    }

    override fun getIntrinsicHeight(): Int {
        return if (type == WARNING) (22 * density).roundToInt() else -1
    }

    override fun draw(canvas: Canvas) {
        val b = bounds
        val size = min(b.width(), b.height()).toFloat()
        if (size <= 0) {
            return
        }
        canvas.save()
        canvas.translate(b.left + (b.width() - size) / 2, b.top + (b.height() - size) / 2)
        paint.color = iconColor
        when (type) {
            CLOSE -> {
                // ic_close，24 的画布
                val scale = size / 24f
                canvas.scale(scale, scale)
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 2f
                paint.strokeCap = Paint.Cap.SQUARE
                canvas.drawLine(6f, 6f, 18f, 18f, paint)
                canvas.drawLine(18f, 6f, 6f, 18f, paint)
            }
            SOUND -> {
                // voice_input_ic_sound，24 的画布：一个圆点，加两道以它为圆心的弧
                val scale = size / 24f
                canvas.scale(scale, scale)
                paint.style = Paint.Style.FILL
                canvas.drawCircle(7f, 12f, 1.8f, paint)
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = 2f
                paint.strokeCap = Paint.Cap.ROUND
                for (radius in floatArrayOf(5.1f, 9.6f)) {
                    rect.set(7f - radius, 12f - radius, 7f + radius, 12f + radius)
                    canvas.drawArc(rect, -45f, 90f, false, paint)
                }
            }
            else -> {
                // voice_input_ic_warning，22 的画布：外圆和感叹号放进同一条奇偶填充的路径，感叹号就是镂空的
                val scale = size / 22f
                canvas.scale(scale, scale)
                paint.style = Paint.Style.FILL
                path.reset()
                path.fillType = Path.FillType.EVEN_ODD
                path.addCircle(11f, 11f, 11f, Path.Direction.CW)
                rect.set(9.7f, 4.8f, 12.3f, 13.76f)
                path.addRoundRect(rect, 1.3f, 1.3f, Path.Direction.CW)
                path.addCircle(11f, 16.65f, 1.45f, Path.Direction.CW)
                canvas.drawPath(path, paint)
            }
        }
        canvas.restore()
    }

    override fun setAlpha(alpha: Int) {
        // 颜色由 setColor 控制
    }

    override fun setColorFilter(colorFilter: ColorFilter?) {
        paint.colorFilter = colorFilter
    }

    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int {
        return PixelFormat.TRANSLUCENT
    }
}
