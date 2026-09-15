//
//  VoiceInputViews.swift
//  wfc-voice-input 插件 iOS 端
//
//  按住说话浮层上自绘的控件，移植自 ../ios-chat 的 Vendor/ChatInputBar/WFCUVoiceInputView.m 里的
//  WFCUVoiceInputBackgroundView、WFCUVoiceWaveView、WFCUVoiceRecordBottomView、WFCUVoiceBubbleView、
//  WFCUVoiceEditTextView、WFCUVectorIconView。
//  和 ios-chat 的区别：文案从配置里来（插件读不到 WFCString）；display link 换成弱引用中转；
//  动画曲线和时长按 Android 端（android-chat 是交互的基准）。
//

import UIKit

enum VoiceInputZone: Int {
    // 松开发送语音
    case send = 0
    // 松手取消
    case cancel = 1
    // 滑到这里转文字
    case text = 2
}

/// 浮层配色，参考微信深色模式，和 Android 端一致
enum VoicePalette {
    static let dim = VoiceInputContext.argbColor(0xFF111111)
    static let panel = VoiceInputContext.argbColor(0xFF444444)
    static let arc = VoiceInputContext.argbColor(0xFF575757)
    static let arcSelectedTop = VoiceInputContext.argbColor(0xFF636363)
    static let arcSelectedBottom = VoiceInputContext.argbColor(0xFF808080)
    static let arcRim = VoiceInputContext.argbColor(0xFF767676)
    static let arcLabel = VoiceInputContext.argbColor(0xFFDDDDDD)
    static let pill = VoiceInputContext.argbColor(0xFF575757)
    static let pillSelected = VoiceInputContext.argbColor(0xFF9A9A9A)
    static let pillLabel = VoiceInputContext.argbColor(0xFFE6E6E6)
    static let selectedLabel = VoiceInputContext.argbColor(0xFF111111)
    static let hint = VoiceInputContext.argbColor(0xFFD0D0D0)
    static let red = VoiceInputContext.argbColor(0xFFFA5151)
    static let circleButton = VoiceInputContext.argbColor(0xFF575757)
    static let circleButtonPressed = VoiceInputContext.argbColor(0xFF6A6A6A)
    static let actionText = VoiceInputContext.argbColor(0xFFBDBDBD)
    static let sendButton = VoiceInputContext.argbColor(0xFFDADADA)
    static let sendButtonPressed = VoiceInputContext.argbColor(0xFFBDBDBD)
    static let sendButtonDisabled = VoiceInputContext.argbColor(0xFF4E4E4E)
    static let sendTextDisabled = VoiceInputContext.argbColor(0xFF737373)
}

// MARK: - 浮层背景

/// 整屏半透明的深色遮罩，底部再叠一块深灰色背景，上边缘从透明线性渐变到不透明。
/// 录音时深灰背景从弧形按钮处开始，编辑文字时升到气泡下方
final class VoiceInputBackgroundView: UIView {
    /// 显示程度，0 完全透明，1 完全显示
    var progress: CGFloat = 0 {
        didSet {
            setNeedsDisplay()
        }
    }

    /// 深灰背景完全不透明处的 y 坐标
    var panelTop: CGFloat = 0 {
        didSet {
            setNeedsDisplay()
        }
    }

    var stageLeft: CGFloat = 0
    var stageRight: CGFloat = 0

    // 深灰背景上边缘渐变区域的高度
    private let fadeHeight: CGFloat = 130

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard progress > 0, let ctx = UIGraphicsGetCurrentContext() else {
            return
        }
        let area = bounds
        ctx.setFillColor(VoicePalette.dim.withAlphaComponent(0.8 * progress).cgColor)
        ctx.fill(area)
        let right = stageRight > stageLeft ? stageRight : area.width
        let width = right - stageLeft
        if width <= 0 {
            return
        }
        let fadeTop = panelTop - fadeHeight
        let top = max(area.minY, fadeTop)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: stageLeft, y: top, width: width, height: max(0, area.maxY - top)))
        let colors = [VoicePalette.panel.withAlphaComponent(0).cgColor, VoicePalette.panel.withAlphaComponent(progress).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            // drawsAfterEndLocation：panelTop 以下一直是不透明的深灰
            ctx.drawLinearGradient(gradient, start: CGPoint(x: stageLeft, y: fadeTop), end: CGPoint(x: stageLeft, y: panelTop), options: [.drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }
}

// MARK: - 声波

/// 一排圆角竖条，中间高两边低，高度随音量平滑起落；录音结束、等待识别结果时换成三个依次跳动的圆点
final class VoiceWaveView: UIView {
    var barColor: UIColor = .white {
        didSet {
            setNeedsDisplay()
        }
    }

    /// 是否显示等待识别结果的动画
    var loading = false

    private let barWidth: CGFloat = 2
    private let barGap: CGFloat = 2.2
    private let minBarHeight: CGFloat = 3
    private let dotRadius: CGFloat = 2.6
    private let dotSpacing: CGFloat = 9

    private var level: CGFloat = 0
    // 等待动画的显示程度，0 显示声波，1 显示等待动画
    private var loadingProgress: CGFloat = 0
    // 每个竖条当前和目标的高度比例，0~1
    private var heights: [CGFloat] = []
    private var targets: [CGFloat] = []
    private var lastFrameTime: CFTimeInterval = 0
    private lazy var displayLink = VoiceDisplayLink { [weak self] in
        self?.onTick()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 音量，0~1
    func setLevel(_ value: CGFloat) {
        level = max(0, min(1, value))
        updateTargets()
    }

    func startAnimation() {
        lastFrameTime = 0
        displayLink.start()
    }

    func stopAnimation() {
        displayLink.pause()
        lastFrameTime = 0
    }

    /// 浮层销毁时调用，停掉 display link
    func invalidate() {
        displayLink.invalidate()
    }

    private func updateTargets() {
        let count = targets.count
        for i in 0..<count {
            let x: CGFloat = count == 1 ? 0 : CGFloat(i) / CGFloat(count - 1) * 2 - 1
            let envelope = 0.3 + 0.7 * CGFloat(exp(Double(-x * x * 2.5)))
            let jitter = 0.5 + 0.5 * CGFloat.random(in: 0...1)
            // 不说话时也保留一点起伏
            let idle = 0.06 + 0.1 * CGFloat.random(in: 0...1) * envelope
            targets[i] = min(1, idle + level * envelope * jitter * 1.2)
        }
        setNeedsDisplay()
    }

    private func ensureBars() {
        let count = max(1, Int((bounds.width + barGap) / (barWidth + barGap)))
        if count == heights.count {
            return
        }
        // 宽度变化时按比例重采样，形变过程中竖条高度不会突变
        var newHeights = [CGFloat](repeating: 0, count: count)
        if !heights.isEmpty {
            for i in 0..<count {
                newHeights[i] = heights[min(heights.count - 1, i * heights.count / count)]
            }
        }
        heights = newHeights
        targets = [CGFloat](repeating: 0, count: count)
        updateTargets()
    }

    private func onTick() {
        let now = CACurrentMediaTime()
        let dt = lastFrameTime == 0 ? 0.016 : min(0.064, now - lastFrameTime)
        lastFrameTime = now
        // 竖条升高、回落的时间常数，回落慢一些更自然；声波和等待动画之间切换的时间常数 100ms
        loadingProgress += ((loading ? 1 : 0) - loadingProgress) * CGFloat(1 - exp(-dt / 0.1))
        for i in 0..<min(heights.count, targets.count) {
            let target = loading ? 0 : targets[i]
            let timeConstant = target > heights[i] ? 0.05 : 0.14
            heights[i] += (target - heights[i]) * CGFloat(1 - exp(-dt / timeConstant))
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let size = bounds.size
        guard size.width > 0, size.height > 0, let ctx = UIGraphicsGetCurrentContext() else {
            return
        }
        ensureBars()
        let count = heights.count
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * barGap
        var left = (size.width - totalWidth) / 2
        let centerY = size.height / 2
        let range = max(0, size.height - minBarHeight)
        let baseAlpha = barColor.cgColor.alpha
        // 等待识别结果时竖条落下并淡出
        let barAlpha = 1 - loadingProgress
        if barAlpha > 0.01 {
            ctx.setFillColor(barColor.withAlphaComponent(baseAlpha * barAlpha).cgColor)
            for i in 0..<count {
                let h = minBarHeight + range * heights[i]
                let bar = UIBezierPath(roundedRect: CGRect(x: left, y: centerY - h / 2, width: barWidth, height: h), cornerRadius: barWidth / 2)
                ctx.addPath(bar.cgPath)
                left += barWidth + barGap
            }
            ctx.fillPath()
        }
        if loadingProgress > 0.01 {
            // 三个圆点从左到右依次变大变亮
            let phase = CACurrentMediaTime() * Double.pi * 2 * 1.2
            let centerX = size.width / 2
            for i in 0..<3 {
                let pulse = 0.5 + 0.5 * CGFloat(sin(phase - Double(i) * 0.9))
                let r = dotRadius * (0.7 + 0.3 * pulse) * (0.5 + 0.5 * loadingProgress)
                ctx.setFillColor(barColor.withAlphaComponent(baseAlpha * loadingProgress * (0.4 + 0.6 * pulse)).cgColor)
                ctx.fillEllipse(in: CGRect(x: centerX + CGFloat(i - 1) * dotSpacing - r, y: centerY - r, width: r * 2, height: r * 2))
            }
        }
    }
}

// MARK: - 底部操作区

/// 最下方弧形的「松开 发送」区域，上方左右两条弧形的「取消」和「转文字」按钮。
/// zoneAt 判断手指所在的目标，selectZone 让对应的按钮平滑高亮
final class VoiceRecordBottomView: UIView {
    private(set) var zone: VoiceInputZone = .send

    var speechToTextEnabled = false {
        didSet {
            setNeedsDisplay()
        }
    }

    private var voiceLabel = ""
    private var sendLabel = ""
    private var cancelLabel = ""
    private var cancelHint = ""
    private var textLabel = ""
    private var textHint = ""

    private var hasStage = false
    private var stageLeft: CGFloat = 0
    private var stageWidth: CGFloat = 0
    private var centerX: CGFloat = 0
    // 底部弧形区域：圆心在底部中间下方的大圆
    private var arcTop: CGFloat = 0
    private var arcRadius: CGFloat = 0
    private var arcCenterY: CGFloat = 0
    // 两条弧形按钮的中线在同一个更大的圆上
    private var pillThickness: CGFloat = 0
    private var pillGap: CGFloat = 0
    private var pillRadius: CGFloat = 0
    private var pillCenterY: CGFloat = 0
    // 按钮文字中心到中线的水平距离
    private var labelOffsetX: CGFloat = 0
    private var maxLabelWidth: CGFloat = 0

    // 各个目标的高亮程度，0~1，按 VoiceInputZone 索引
    private var selection: [CGFloat] = [1, 0, 0]
    private var fromSelection: [CGFloat] = [1, 0, 0]
    private var selectionStart: CFTimeInterval = 0
    // 入场进度，0 完全隐藏，1 完全显示
    private var appear = VoiceTween(0)
    private var appearCompletion: (() -> Void)?
    private lazy var displayLink = VoiceDisplayLink { [weak self] in
        self?.onTick()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setLabels(voice: String, send: String, cancel: String, cancelHint: String, text: String, textHint: String) {
        voiceLabel = voice
        sendLabel = send
        cancelLabel = cancel
        self.cancelHint = cancelHint
        textLabel = text
        self.textHint = textHint
        setNeedsDisplay()
    }

    /// 设置操作区的位置
    /// - Parameters:
    ///   - left: 左边界，本视图坐标
    ///   - right: 右边界，本视图坐标
    ///   - arcTop: 底部弧形区域最高点的 y 坐标，按住说话按钮需要在弧形区域内
    func setStage(left: CGFloat, right: CGFloat, arcTop: CGFloat) {
        stageLeft = left
        stageWidth = right - left
        centerX = left + stageWidth / 2
        self.arcTop = arcTop
        arcRadius = stageWidth * 1.68
        arcCenterY = arcTop + arcRadius

        pillThickness = max(56, min(72, stageWidth * 0.17))
        pillGap = 22
        pillRadius = stageWidth * 1.72
        pillCenterY = arcTop - 16 - pillThickness / 2 + pillRadius
        labelOffsetX = min(stageWidth * 0.29, 170)
        maxLabelWidth = max(48, 2 * min(labelOffsetX - pillGap / 2 - 12, stageWidth / 2 - 8 - labelOffsetX))
        hasStage = true
        setNeedsDisplay()
    }

    /// 弧形按钮上边缘最高点的 y 坐标
    func pillTop() -> CGFloat {
        return pillCenterY - pillRadius - pillThickness / 2
    }

    /// 「取消」按钮文字中心的 x 坐标
    func cancelCenterX() -> CGFloat {
        return centerX - labelOffsetX
    }

    /// 手指所在的目标，point 为本视图坐标
    func zoneAt(_ point: CGPoint) -> VoiceInputZone {
        if !hasStage {
            return .send
        }
        let dx = point.x - centerX
        if abs(dx) < arcRadius && point.y >= arcCenterY - sqrt(arcRadius * arcRadius - dx * dx) {
            return .send
        }
        return speechToTextEnabled && point.x >= centerX ? .text : .cancel
    }

    func selectZone(_ newZone: VoiceInputZone) {
        if zone == newZone {
            return
        }
        zone = newZone
        fromSelection = selection
        selectionStart = CACurrentMediaTime()
        displayLink.start()
    }

    /// 恢复到未显示、选中发送的状态
    func reset() {
        zone = .send
        selection = [1, 0, 0]
        fromSelection = selection
        selectionStart = 0
        appear.set(0)
        appearCompletion = nil
        setNeedsDisplay()
    }

    /// 弧形区域和按钮从底部升起
    func show() {
        appearCompletion = nil
        appear.animate(to: 1, duration: 0.34, easing: VoiceEasing.decelerate(2))
        displayLink.start()
    }

    /// 按钮和弧形区域落回底部
    func hide(completion: (() -> Void)? = nil) {
        appearCompletion = completion
        appear.animate(to: 0, duration: 0.22, easing: VoiceEasing.accelerate(1.5))
        displayLink.start()
    }

    /// 浮层销毁时调用，停掉 display link
    func invalidate() {
        displayLink.invalidate()
    }

    private func onTick() {
        let now = CACurrentMediaTime()
        var animating = false
        if selectionStart > 0 {
            let fraction = CGFloat(min(1, (now - selectionStart) / 0.22))
            let t = VoiceEasing.decelerate(1.5)(fraction)
            for i in 0..<3 {
                let target: CGFloat = i == zone.rawValue ? 1 : 0
                selection[i] = fromSelection[i] + (target - fromSelection[i]) * t
            }
            if fraction >= 1 {
                selectionStart = 0
            } else {
                animating = true
            }
        }
        if appear.update(now) {
            animating = true
            if !appear.running, let completion = appearCompletion {
                appearCompletion = nil
                completion()
            }
        }
        setNeedsDisplay()
        if !animating {
            displayLink.pause()
        }
    }

    override func draw(_ rect: CGRect) {
        guard hasStage, appear.value > 0, let ctx = UIGraphicsGetCurrentContext() else {
            return
        }
        let height = bounds.height
        ctx.saveGState()
        ctx.clip(to: CGRect(x: stageLeft, y: 0, width: stageWidth, height: height))
        drawArcArea(ctx, height: height)
        // 按钮比弧形区域稍晚升起，更早落下
        let pillAppear = max(0, min(1, (appear.value - 0.15) / 0.85))
        if pillAppear > 0 {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: (1 - pillAppear) * (height - pillTop()))
            drawPill(ctx, left: true, selected: selection[VoiceInputZone.cancel.rawValue], label: cancelLabel, hint: cancelHint, alpha: pillAppear)
            if speechToTextEnabled {
                drawPill(ctx, left: false, selected: selection[VoiceInputZone.text.rawValue], label: textLabel, hint: textHint, alpha: pillAppear)
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    private func drawArcArea(_ ctx: CGContext, height: CGFloat) {
        let selected = selection[VoiceInputZone.send.rawValue]
        ctx.saveGState()
        ctx.translateBy(x: 0, y: (1 - appear.value) * (height - arcTop))
        let circle = CGRect(x: centerX - arcRadius, y: arcCenterY - arcRadius, width: arcRadius * 2, height: arcRadius * 2)
        ctx.setFillColor(VoicePalette.arc.cgColor)
        ctx.fillEllipse(in: circle)
        if selected > 0 {
            // 高亮渐变
            ctx.saveGState()
            ctx.addEllipse(in: circle)
            ctx.clip()
            let colors = [VoicePalette.arcSelectedTop.withAlphaComponent(selected).cgColor, VoicePalette.arcSelectedBottom.withAlphaComponent(selected).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: centerX, y: arcTop), end: CGPoint(x: centerX, y: max(arcTop + 1, height)), options: [.drawsAfterEndLocation])
            }
            ctx.restoreGState()
            ctx.setStrokeColor(VoicePalette.arcRim.withAlphaComponent(selected).cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))
        }
        // 「语音」和「松开 发送」交叉淡入淡出，文字同时轻微上移
        let labelCenterY = arcTop + 44 - 8 * selected
        let font = UIFont.boldSystemFont(ofSize: 18)
        if 1 - selected > 0.01 {
            drawCenteredText(voiceLabel, centerY: labelCenterY, color: VoicePalette.arcLabel.withAlphaComponent(1 - selected), font: font)
        }
        if selected > 0.01 {
            drawCenteredText(sendLabel, centerY: labelCenterY, color: VoicePalette.selectedLabel.withAlphaComponent(selected), font: font)
        }
        ctx.restoreGState()
    }

    private func drawCenteredText(_ text: String, centerY: CGFloat, color: UIColor, font: UIFont) {
        if text.isEmpty {
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(in: CGRect(x: centerX - size.width / 2, y: centerY - size.height / 2, width: size.width, height: size.height), withAttributes: attrs)
    }

    private func drawPill(_ ctx: CGContext, left: Bool, selected: CGFloat, label: String, hint: String, alpha: CGFloat) {
        // 选中时稍微变粗
        let thickness = pillThickness * (1 + 0.06 * selected)
        let inner = asin((pillGap / 2 + pillThickness / 2) / pillRadius)
        let outer = asin(min(1, (stageWidth / 2 + thickness) / pillRadius))
        // 圆的最高点是 -π/2，角度顺时针增加，弧线从左往右画
        let start = left ? -CGFloat.pi / 2 - outer : -CGFloat.pi / 2 + inner
        let arc = UIBezierPath(arcCenter: CGPoint(x: centerX, y: pillCenterY), radius: pillRadius, startAngle: start, endAngle: start + outer - inner, clockwise: true)
        arc.lineWidth = thickness
        arc.lineCapStyle = .round
        VoiceInputContext.blend(VoicePalette.pill, VoicePalette.pillSelected, selected).withAlphaComponent(alpha).setStroke()
        arc.stroke()

        let offsetX = left ? -labelOffsetX : labelOffsetX
        let labelColor = VoiceInputContext.blend(VoicePalette.pillLabel, VoicePalette.selectedLabel, selected).withAlphaComponent(alpha)
        drawTextOnArc(ctx, label, radius: pillRadius, offsetX: offsetX, font: UIFont.systemFont(ofSize: 17), color: labelColor, maxWidth: maxLabelWidth)
        if selected > 0 {
            // 按钮上方的提示随高亮淡入，并向上浮起
            let hintRadius = pillRadius + thickness / 2 + 24 - 8 * (1 - selected)
            drawTextOnArc(ctx, hint, radius: hintRadius, offsetX: offsetX, font: UIFont.systemFont(ofSize: 14), color: VoicePalette.hint.withAlphaComponent(alpha * selected), maxWidth: maxLabelWidth + 40)
        }
    }

    /// 沿以 (centerX, pillCenterY) 为圆心的圆弧逐字绘制文字，文字中心在 centerX + offsetX 附近，太长时缩小字号
    private func drawTextOnArc(_ ctx: CGContext, _ text: String, radius: CGFloat, offsetX: CGFloat, font: UIFont, color: UIColor, maxWidth: CGFloat) {
        if text.isEmpty || color.cgColor.alpha <= 0 {
            return
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var width = (text as NSString).size(withAttributes: attrs).width
        if width > maxWidth && maxWidth > 0 {
            attrs[.font] = font.withSize(font.pointSize * maxWidth / width)
            width = (text as NSString).size(withAttributes: attrs).width
        }
        let centerAngle = -CGFloat.pi / 2 + asin(max(-1, min(1, offsetX / radius)))
        let startAngle = centerAngle - width / radius / 2
        var drawn: CGFloat = 0
        for character in text {
            let piece = String(character) as NSString
            let size = piece.size(withAttributes: attrs)
            let angle = startAngle + (drawn + size.width / 2) / radius
            drawn += size.width
            ctx.saveGState()
            ctx.translateBy(x: centerX + radius * cos(angle), y: pillCenterY + radius * sin(angle))
            ctx.rotate(by: angle + CGFloat.pi / 2)
            piece.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), withAttributes: attrs)
            ctx.restoreGState()
        }
    }
}

// MARK: - 气泡

/// 圆角矩形，底部有一个指向当前手势目标的小尖角，尖角画在底部 tailHeight 的范围内
final class VoiceBubbleView: UIView {
    let tailHeight: CGFloat = 8

    var bubbleColor: UIColor = .white {
        didSet {
            setNeedsDisplay()
        }
    }

    /// 尖角中心相对于气泡左边的位置，小于 0 时居中
    var tailX: CGFloat = -1 {
        didSet {
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        // 必须用 bounds 而不是传入的 rect（脏区），否则局部重绘时会按脏区尺寸画出一个尺寸、位置都不对的气泡
        let width = bounds.width
        let height = bounds.height
        let bodyBottom = height - tailHeight
        if width <= 0 || bodyBottom <= 0 {
            return
        }
        let r = min(18, min(width, bodyBottom) / 2)
        bubbleColor.setFill()
        UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: bodyBottom), cornerRadius: r).fill()

        let half: CGFloat = 9
        var x = tailX < 0 ? width / 2 : tailX
        x = max(min(r + half, width / 2), min(max(width - r - half, width / 2), x))
        // 尖角向上多画 1pt 与气泡主体重叠，避免抗锯齿留下接缝；尖端画成小圆角
        let tip: CGFloat = 1.5
        let tail = UIBezierPath()
        tail.move(to: CGPoint(x: x - half, y: bodyBottom - 1))
        tail.addLine(to: CGPoint(x: x - tip, y: height - 1))
        tail.addQuadCurve(to: CGPoint(x: x + tip, y: height - 1), controlPoint: CGPoint(x: x, y: height))
        tail.addLine(to: CGPoint(x: x + half, y: bodyBottom - 1))
        tail.close()
        tail.fill()
    }
}

// MARK: - 编辑用输入框

/// 编辑识别文字用的 UITextView。
/// 文字要显示在彩色气泡上，输入框必须完全透明。只设一次 backgroundColor 并不稳：UIAppearance（例如某些三方 SDK
/// 给 UITextView 设了白底）是在视图加入 window 时才应用的，会覆盖掉之前设置的 clear，气泡里就出现一块白色方块。
/// 所以在 init / didMoveToWindow / layoutSubviews 里反复兜底，并把内部容器视图的背景也清掉（同 ios-chat）
final class VoiceEditTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        clearBackground()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        clearBackground()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clearBackground()
    }

    private func clearBackground() {
        backgroundColor = .clear
        isOpaque = false
        layer.backgroundColor = UIColor.clear.cgColor
        for subview in subviews {
            subview.backgroundColor = .clear
            subview.isOpaque = false
        }
    }
}

// MARK: - 图标

/// 编辑文字时圆形按钮里的图标，按 24 的画布画，和 Android 的 vector drawable 一致
final class VoiceIconView: UIView {
    enum Kind {
        case close
        case sound
    }

    private let kind: Kind

    init(frame: CGRect, kind: Kind) {
        self.kind = kind
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else {
            return
        }
        let size = min(bounds.width, bounds.height)
        if size <= 0 {
            return
        }
        ctx.translateBy(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2)
        ctx.scaleBy(x: size / 24, y: size / 24)
        UIColor.white.setStroke()
        UIColor.white.setFill()
        switch kind {
        case .close:
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 6, y: 6))
            path.addLine(to: CGPoint(x: 18, y: 18))
            path.move(to: CGPoint(x: 18, y: 6))
            path.addLine(to: CGPoint(x: 6, y: 18))
            path.lineWidth = 2
            path.lineCapStyle = .square
            path.stroke()
        case .sound:
            // 一个圆点，加两道以它为圆心的弧
            UIBezierPath(ovalIn: CGRect(x: 7 - 1.8, y: 12 - 1.8, width: 3.6, height: 3.6)).fill()
            for radius in [CGFloat(5.1), CGFloat(9.6)] {
                let arc = UIBezierPath(arcCenter: CGPoint(x: 7, y: 12), radius: radius, startAngle: -CGFloat.pi / 4, endAngle: CGFloat.pi / 4, clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                arc.stroke()
            }
        }
    }
}

enum VoiceIcons {
    /// 圆形感叹号，感叹号镂空、透出气泡的颜色，同 Android 的 voice_input_ic_warning
    static func warningImage(color: UIColor, size: CGFloat = 20) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            context.cgContext.scaleBy(x: size / 22, y: size / 22)
            let path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 22, height: 22))
            path.append(UIBezierPath(roundedRect: CGRect(x: 9.7, y: 4.8, width: 2.6, height: 8.96), cornerRadius: 1.3))
            path.append(UIBezierPath(ovalIn: CGRect(x: 11 - 1.45, y: 16.65 - 1.45, width: 2.9, height: 2.9)))
            path.usesEvenOddFillRule = true
            color.setFill()
            path.fill()
        }
    }
}
