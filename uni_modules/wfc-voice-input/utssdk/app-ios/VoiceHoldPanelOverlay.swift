//
//  VoiceHoldPanelOverlay.swift
//  wfc-voice-input 插件 iOS 端
//
//  VoiceHoldPanel 的浮层部分：创建和布局控件、气泡在各形态之间形变、编辑文字、软键盘避让、退出动画。
//  计算方式和 Android 端 AudioRecorderPanel.kt 的「浮层」一节一一对应（dp 换成 pt）。
//

import UIKit

/// 按住说话的全屏浮层。编辑文字时才接管触摸；录音时手指还在 uvue 的按钮上，浮层不能拦截（同 ios-chat）
final class VoiceInputOverlayView: UIView {
    var interactive = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !interactive || isHidden || alpha < 0.01 {
            return nil
        }
        return super.hitTest(point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // 编辑文字时点空白处收起键盘；不往下传，避免穿透到下面的消息列表
        endEditing(true)
    }
}

/// 气泡某一形态的位置、大小和内容，坐标相对于浮层，声波和尖角的坐标相对于气泡
struct VoiceBubbleFrame {
    var left: CGFloat = 0
    var width: CGFloat = 0
    var height: CGFloat = 0
    var tailX: CGFloat = 0
    var color = UIColor.clear
    var waveColor = UIColor.white
    var waveWidth: CGFloat = 0
    var waveHeight: CGFloat = 0
    var waveCenterX: CGFloat = 0
    var waveCenterY: CGFloat = 0
    var waveAlpha: CGFloat = 0
    var textAlpha: CGFloat = 0
    var hintAlpha: CGFloat = 0
    var textBottomMargin: CGFloat = 0

    static func lerp(_ from: VoiceBubbleFrame, _ to: VoiceBubbleFrame, _ fraction: CGFloat) -> VoiceBubbleFrame {
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            return a + (b - a) * fraction
        }
        var frame = VoiceBubbleFrame()
        frame.left = mix(from.left, to.left)
        frame.width = mix(from.width, to.width)
        frame.height = mix(from.height, to.height)
        frame.tailX = mix(from.tailX, to.tailX)
        frame.color = VoiceInputContext.blend(from.color, to.color, fraction)
        frame.waveColor = VoiceInputContext.blend(from.waveColor, to.waveColor, fraction)
        frame.waveWidth = mix(from.waveWidth, to.waveWidth)
        frame.waveHeight = mix(from.waveHeight, to.waveHeight)
        frame.waveCenterX = mix(from.waveCenterX, to.waveCenterX)
        frame.waveCenterY = mix(from.waveCenterY, to.waveCenterY)
        frame.waveAlpha = mix(from.waveAlpha, to.waveAlpha)
        frame.textAlpha = mix(from.textAlpha, to.textAlpha)
        frame.hintAlpha = mix(from.hintAlpha, to.hintAlpha)
        frame.textBottomMargin = mix(from.textBottomMargin, to.textBottomMargin)
        return frame
    }
}

@available(iOS 13.0, *)
extension VoiceHoldPanel {

    // 气泡内边距，底部包含尖角的高度（和 Android 的 padding 一致）
    static let bubblePaddingHorizontal: CGFloat = 20
    static let bubblePaddingTop: CGFloat = 18
    static let bubblePaddingBottom: CGFloat = 26
    static let textFont = UIFont.systemFont(ofSize: 20)
    static let textMinHeight: CGFloat = 30
    static let textMaxLines = 6
    static let hintFont = UIFont.systemFont(ofSize: 18)
    // 编辑文字时底部按钮一行的高度，和升起的距离
    static let editActionsHeight: CGFloat = 96
    static let editActionOffset: CGFloat = 28

    // MARK: - 创建

    func setupOverlay() {
        overlay.backgroundColor = .clear
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        backgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.addSubview(backgroundView)
        bottomView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.addSubview(bottomView)

        countDownLabel.textColor = UIColor(white: 1, alpha: 0.8)
        countDownLabel.font = UIFont.systemFont(ofSize: 14)
        countDownLabel.textAlignment = .center
        countDownLabel.alpha = 0
        overlay.addSubview(countDownLabel)

        // 缩放以气泡底边中点（尖角处）为轴，和 Android 的 pivot 一致；center 因此就是尖角的位置
        bubbleView.layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        // 子视图不允许超出气泡，避免文字、光标在气泡外露出边角
        bubbleView.clipsToBounds = true
        bubbleView.alpha = 0
        overlay.addSubview(bubbleView)

        bubbleView.addSubview(waveView)

        textView.font = VoiceHoldPanel.textFont
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.isEditable = false
        textView.isUserInteractionEnabled = false
        textView.showsVerticalScrollIndicator = false
        // 浮层是深色的，键盘也用深色，编辑时和浮层连成一个整体
        textView.keyboardAppearance = .dark
        textView.delegate = self
        bubbleView.addSubview(textView)

        placeholderLabel.font = VoiceHoldPanel.textFont
        placeholderLabel.isUserInteractionEnabled = false
        bubbleView.addSubview(placeholderLabel)

        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 2
        hintLabel.alpha = 0
        bubbleView.addSubview(hintLabel)

        // 编辑文字时的底部按钮：取消、发送原语音、发送
        editActionsView.isHidden = true
        overlay.addSubview(editActionsView)
        setupActionButton(cancelActionView, button: cancelButton, label: cancelLabel, icon: .close, action: #selector(onEditCancelClick))
        setupActionButton(sendVoiceActionView, button: sendVoiceButton, label: sendVoiceLabel, icon: .sound, action: #selector(onSendVoiceClick))
        editActionsView.addSubview(cancelActionView)
        editActionsView.addSubview(sendVoiceActionView)

        // 发送文字的按钮和 Android 一致用浅灰色，主色调只用在气泡上；识别没结束或者文字为空时置灰
        sendTextButton.setBackgroundImage(VoiceHoldPanel.colorImage(VoicePalette.sendButton), for: .normal)
        sendTextButton.setBackgroundImage(VoiceHoldPanel.colorImage(VoicePalette.sendButtonPressed), for: .highlighted)
        sendTextButton.setBackgroundImage(VoiceHoldPanel.colorImage(VoicePalette.sendButtonDisabled), for: .disabled)
        sendTextButton.setTitleColor(VoicePalette.selectedLabel, for: .normal)
        sendTextButton.setTitleColor(VoicePalette.sendTextDisabled, for: .disabled)
        sendTextButton.titleLabel?.font = UIFont.systemFont(ofSize: 19)
        sendTextButton.layer.cornerRadius = 37
        sendTextButton.clipsToBounds = true
        sendTextButton.isEnabled = false
        sendTextButton.addTarget(self, action: #selector(onSendTextClick), for: .touchUpInside)
        editActionsView.addSubview(sendTextButton)
    }

    private func setupActionButton(_ container: UIView, button: UIButton, label: UILabel, icon: VoiceIconView.Kind, action: Selector) {
        button.frame = CGRect(x: 15, y: 0, width: 66, height: 66)
        button.setBackgroundImage(VoiceHoldPanel.colorImage(VoicePalette.circleButton), for: .normal)
        button.setBackgroundImage(VoiceHoldPanel.colorImage(VoicePalette.circleButtonPressed), for: .highlighted)
        button.layer.cornerRadius = 33
        button.clipsToBounds = true
        // 和 Android 的 ImageView 内边距一致：关闭图标 24pt，声音图标 26pt
        let iconSize: CGFloat = icon == .close ? 24 : 26
        button.addSubview(VoiceIconView(frame: CGRect(x: (66 - iconSize) / 2, y: (66 - iconSize) / 2, width: iconSize, height: iconSize), kind: icon))
        button.addTarget(self, action: action, for: .touchUpInside)
        container.addSubview(button)

        label.frame = CGRect(x: 0, y: 76, width: 96, height: 20)
        label.textColor = VoicePalette.actionText
        label.font = UIFont.systemFont(ofSize: 15)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        container.addSubview(label)
        container.addGestureRecognizer(UITapGestureRecognizer(target: self, action: action))
    }

    static func colorImage(_ color: UIColor) -> UIImage {
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }

    // MARK: - 显示与布局

    func showOverlay() {
        guard let window = VoiceInputContext.keyWindow() else {
            VoiceInputContext.log("show overlay failed: no key window")
            return
        }
        resetOverlay()
        overlay.frame = window.bounds
        overlay.interactive = false
        window.addSubview(overlay)
        overlay.layoutIfNeeded()
        layoutOverlay()
        waveView.startAnimation()
        playEnterAnimation()
        // 手指在浮层出现之前可能已经滑到别的目标上了
        updateZone()
    }

    private func resetOverlay() {
        layoutReady = false
        keyboardShift = 0
        countDownShown = false
        backgroundCompletion = nil
        backgroundProgress.set(0)
        backgroundView.progress = 0
        bottomView.reset()
        bottomView.speechToTextEnabled = speechToTextEnabled
        let t = texts
        bottomView.setLabels(voice: t.voice, send: t.releaseToSend, cancel: t.cancel, cancelHint: t.releaseToCancel, text: t.slideToText, textHint: t.releaseToEdit)
        cancelLabel.text = t.cancel
        sendVoiceLabel.text = t.sendVoice
        sendTextButton.setTitle(t.send, for: .normal)
        countDownLabel.layer.removeAllAnimations()
        countDownLabel.alpha = 0
        countDownLabel.text = nil
        bubbleView.layer.removeAllAnimations()
        bubbleView.alpha = 0
        bubbleView.transform = .identity
        hintLabel.alpha = 0
        hintLabel.attributedText = nil
        waveView.loading = false
        waveView.setLevel(0)
        textView.text = ""
        textView.isEditable = false
        textView.isUserInteractionEnabled = false
        textView.textColor = bubbleContentColor
        textView.tintColor = bubbleContentColor
        placeholderLabel.text = nil
        placeholderLabel.textColor = bubbleContentColor.withAlphaComponent(0.6)
        editActionsView.layer.removeAllAnimations()
        editActionsView.alpha = 1
        editActionsView.isHidden = true
        bubbleState = .send
    }

    private func layoutOverlay() {
        let bounds = overlay.bounds
        let width = bounds.width
        let height = bounds.height
        // 手机上操作区就是整个浮层
        stageLeft = 0
        stageWidth = width
        backgroundView.frame = bounds
        bottomView.frame = bounds
        // 底部弧形区域要盖住按住说话的按钮，手指按下时就在「松开 发送」区域内
        let buttonTop = overlayPoint(CGPoint(x: 0, y: buttonTopScreen)).y
        let arcTop = min(height - 110, buttonTop - 16)
        let touch = overlayPoint(touchScreenPoint)
        // 排查坐标用：正常时 touch 的 y 接近浮层高度减去底部安全区和输入栏的一半，buttonTop 比它小十几
        VoiceInputContext.log("overlay laid out, size \(width)x\(height), touch \(touch.x),\(touch.y), buttonTop \(buttonTop)")
        bottomView.setStage(left: stageLeft, right: stageLeft + stageWidth, arcTop: arcTop)
        // 录音时深灰背景从弧形按钮处开始，编辑文字时再升到气泡下方
        backgroundView.stageLeft = stageLeft
        backgroundView.stageRight = stageLeft + stageWidth
        panelTop.set(bottomView.pillTop() + 18)
        backgroundView.panelTop = panelTop.value
        // 气泡的尖角固定在按钮上方，内容变多时向上长高
        bubbleBottomMargin = height - max(160, bottomView.pillTop() - 141)
        editActionsBottomMargin = max(16, height - arcTop - 20)
        layoutCountDown()
        layoutEditActions()

        layoutReady = true
        let frame = computeBubbleFrame(bubbleState)
        bubbleFrom = frame
        bubbleTo = frame
        bubbleProgress.set(1)
        applyBubbleFrame(frame)
    }

    /// 屏幕坐标换算到浮层坐标：窗口不一定从屏幕原点开始（例如 iPad 分屏）
    func overlayPoint(_ screenPoint: CGPoint) -> CGPoint {
        guard let window = overlay.window else {
            return screenPoint
        }
        let inWindow = window.convert(screenPoint, from: window.screen.coordinateSpace)
        return overlay.convert(inWindow, from: window)
    }

    private func layoutCountDown() {
        // 和 Android 一致：底边在气泡尖角下方 44pt
        let bottom = overlay.bounds.height - (bubbleBottomMargin - 44) - keyboardShift
        countDownLabel.frame = CGRect(x: stageLeft, y: bottom - 24, width: stageWidth, height: 24)
    }

    private func layoutEditActions() {
        let rowY = overlay.bounds.height - editActionsBottomMargin - VoiceHoldPanel.editActionsHeight - keyboardShift
        editActionsView.frame = CGRect(x: stageLeft + 16, y: rowY, width: stageWidth - 40, height: VoiceHoldPanel.editActionsHeight)
        cancelActionView.frame = CGRect(x: 0, y: 0, width: 96, height: VoiceHoldPanel.editActionsHeight)
        sendVoiceActionView.frame = CGRect(x: 106, y: 0, width: 96, height: VoiceHoldPanel.editActionsHeight)
        sendTextButton.frame = CGRect(x: editActionsView.bounds.width - 124, y: 0, width: 124, height: 74)
    }

    private func playEnterAnimation() {
        backgroundProgress.animate(to: 1, duration: 0.2, easing: VoiceEasing.linear)
        panelLink.start()
        bottomView.show()
        bubbleView.alpha = 0
        bubbleView.transform = CGAffineTransform(translationX: 0, y: 24).scaledBy(x: 0.6, y: 0.6)
        UIView.animate(withDuration: 0.34, delay: 0.04, usingSpringWithDamping: 0.75, initialSpringVelocity: 0.5, options: [.allowUserInteraction], animations: {
            self.bubbleView.alpha = 1
            self.bubbleView.transform = .identity
        }, completion: nil)
    }

    /// 背景淡入淡出、深灰背景升降、气泡形变，都由这一个 display link 驱动
    func onFrame() {
        let now = CACurrentMediaTime()
        var running = false
        if backgroundProgress.update(now) {
            running = true
            backgroundView.progress = backgroundProgress.value
            if !backgroundProgress.running, let completion = backgroundCompletion {
                backgroundCompletion = nil
                completion()
                return
            }
        }
        if panelTop.update(now) {
            running = true
            backgroundView.panelTop = panelTop.value
        }
        if bubbleProgress.update(now) {
            running = true
            applyBubbleFrame(VoiceBubbleFrame.lerp(bubbleFrom, bubbleTo, bubbleProgress.value))
        }
        if !running {
            panelLink.pause()
        }
    }

    // MARK: - 手势目标与气泡

    func updateZone() {
        if !layoutReady || stage != .recording {
            return
        }
        let zone = bottomView.zoneAt(overlayPoint(touchScreenPoint))
        if zone == bottomView.zone {
            return
        }
        bottomView.selectZone(zone)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        switch zone {
        case .cancel:
            animateBubbleTo(.cancel)
        case .text:
            startSpeechToText()
            animateBubbleTo(.text)
        case .send:
            animateBubbleTo(.send)
        }
    }

    /// 气泡从当前的位置、大小、颜色平滑过渡到目标形态；内容变化时用同一个形态再调用一次，气泡会平滑地改变高度
    func animateBubbleTo(_ state: BubbleState) {
        let changed = bubbleState != state
        bubbleState = state
        if !layoutReady {
            return
        }
        bubbleFrom = bubbleFrame
        bubbleTo = computeBubbleFrame(state)
        bubbleProgress.set(0)
        bubbleProgress.animate(to: 1, duration: changed ? 0.32 : 0.18, easing: VoiceEasing.fastOutSlowIn)
        panelLink.start()
    }

    private func computeBubbleFrame(_ state: BubbleState) -> VoiceBubbleFrame {
        let tailHeight = bubbleView.tailHeight
        let maxWidth = stageWidth - 32
        let sendWidth = min(maxWidth, max(160, stageWidth * 0.475))
        var frame = VoiceBubbleFrame()
        let tailTargetX: CGFloat
        frame.waveColor = bubbleContentColor
        frame.textAlpha = 0
        frame.hintAlpha = 0
        frame.textBottomMargin = 20
        switch state {
        case .cancel:
            // 缩成红色的小方块，移到「取消」上方
            frame.width = 78
            frame.height = 78 + tailHeight
            tailTargetX = bottomView.cancelCenterX()
            frame.left = max(stageLeft + 16, tailTargetX - frame.width / 2)
            frame.color = VoicePalette.red
            frame.waveColor = .white
            frame.waveWidth = 34
            frame.waveHeight = 16
            frame.waveCenterX = frame.width / 2
            frame.waveCenterY = (frame.height - tailHeight) / 2
            frame.waveAlpha = 1
        case .text, .edit, .noText:
            // 展开成整行宽度显示文字，声波缩小到右下角，识别完成后消失；没有识别到文字时变成红色的提示
            let noText = state == .noText
            let showWave = state == .text || (state == .edit && !asrFinished)
            frame.left = stageLeft + 16
            frame.width = maxWidth
            frame.textBottomMargin = showWave ? 20 : 0
            frame.height = measureBubbleHeight(width: frame.width, textBottomMargin: frame.textBottomMargin)
            frame.color = noText ? VoicePalette.red : bubbleColor
            frame.waveColor = noText ? .white : bubbleContentColor
            frame.waveWidth = 34
            frame.waveHeight = 16
            frame.waveCenterX = frame.width - 20 - frame.waveWidth / 2
            frame.waveCenterY = frame.height - tailHeight - 18
            frame.waveAlpha = showWave ? 1 : 0
            frame.textAlpha = noText ? 0 : 1
            frame.hintAlpha = noText ? 1 : 0
            // 和微信一样，整行宽度的气泡尖角固定在同一个位置，转文字、编辑、没有识别到文字之间切换时不动
            tailTargetX = stageLeft + stageWidth * 0.755
        case .tooShort:
            // 保持松开发送时的样子，声波换成提示，提示放不下时加宽
            frame.width = min(maxWidth, max(sendWidth, measureHintWidth()))
            frame.height = 78 + tailHeight
            frame.left = stageLeft + (stageWidth - frame.width) / 2
            frame.color = bubbleColor
            frame.waveWidth = sendWidth * 0.46
            frame.waveHeight = 20
            frame.waveCenterX = frame.width / 2
            frame.waveCenterY = (frame.height - tailHeight) / 2
            frame.waveAlpha = 0
            frame.hintAlpha = 1
            tailTargetX = frame.left + frame.width / 2
        case .send:
            frame.width = sendWidth
            frame.height = 78 + tailHeight
            frame.left = stageLeft + (stageWidth - frame.width) / 2
            frame.color = bubbleColor
            frame.waveWidth = frame.width * 0.46
            frame.waveHeight = 20
            frame.waveCenterX = frame.width / 2
            frame.waveCenterY = (frame.height - tailHeight) / 2
            frame.waveAlpha = 1
            tailTargetX = frame.left + frame.width / 2
        }
        frame.tailX = tailTargetX - frame.left
        return frame
    }

    func applyBubbleFrame(_ frame: VoiceBubbleFrame) {
        bubbleFrame = frame
        let bottom = overlay.bounds.height - bubbleBottomMargin - keyboardShift
        // anchorPoint 在底边中点，改 bounds + center 不受缩放 transform 影响
        bubbleView.bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        bubbleView.center = CGPoint(x: frame.left + frame.width / 2, y: bottom)
        bubbleView.bubbleColor = frame.color
        bubbleView.tailX = frame.tailX

        waveView.frame = CGRect(x: frame.waveCenterX - frame.waveWidth / 2, y: frame.waveCenterY - frame.waveHeight / 2, width: frame.waveWidth, height: frame.waveHeight)
        waveView.barColor = frame.waveColor
        waveView.alpha = frame.waveAlpha

        let padding = VoiceHoldPanel.bubblePaddingHorizontal
        let top = VoiceHoldPanel.bubblePaddingTop
        let contentWidth = max(0, frame.width - 2 * padding)
        let textHeight = max(0, frame.height - top - VoiceHoldPanel.bubblePaddingBottom - frame.textBottomMargin)
        textView.frame = CGRect(x: padding, y: top, width: contentWidth, height: textHeight)
        textView.alpha = frame.textAlpha
        placeholderLabel.frame = CGRect(x: padding, y: top, width: contentWidth, height: min(textHeight, ceil(VoiceHoldPanel.textFont.lineHeight)))
        placeholderLabel.alpha = frame.textAlpha
        hintLabel.transform = .identity
        hintLabel.frame = CGRect(x: padding, y: top, width: contentWidth, height: max(0, frame.height - top - VoiceHoldPanel.bubblePaddingBottom))
        hintLabel.alpha = frame.hintAlpha
        // 提示淡入时轻微上浮
        hintLabel.transform = CGAffineTransform(translationX: 0, y: (1 - frame.hintAlpha) * 6)
    }

    /// 气泡按指定宽度显示当前文字时的高度，文字最多显示 6 行，超出后在输入框里滚动（同 Android 的 maxLines）
    private func measureBubbleHeight(width: CGFloat, textBottomMargin: CGFloat) -> CGFloat {
        let contentWidth = max(1, width - 2 * VoiceHoldPanel.bubblePaddingHorizontal)
        let current = textView.text ?? ""
        let text = current.isEmpty ? (placeholderLabel.text ?? "") : current
        var textHeight = VoiceHoldPanel.textMinHeight
        if !text.isEmpty {
            let font = VoiceHoldPanel.textFont
            let size = (text as NSString).boundingRect(with: CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude),
                                                       options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                       attributes: [.font: font], context: nil).size
            textHeight = max(VoiceHoldPanel.textMinHeight, min(ceil(font.lineHeight * CGFloat(VoiceHoldPanel.textMaxLines)), ceil(size.height)))
        }
        return VoiceHoldPanel.bubblePaddingTop + textHeight + textBottomMargin + VoiceHoldPanel.bubblePaddingBottom
    }

    /// 气泡完整显示提示所需的宽度
    private func measureHintWidth() -> CGFloat {
        let size = hintLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        return ceil(size.width) + 2 * VoiceHoldPanel.bubblePaddingHorizontal + 2
    }

    func setBubbleText(_ text: String) {
        if (textView.text ?? "") != text {
            textView.text = text
            if bubbleState == .text || bubbleState == .edit {
                animateBubbleTo(bubbleState)
                scrollTextToEnd()
            }
        }
        updateTextHint()
    }

    /// 文字超过最大行数时，滚动到最新识别出的文字
    private func scrollTextToEnd() {
        DispatchQueue.main.async { [weak self] in
            guard let textView = self?.textView else {
                return
            }
            let length = ((textView.text ?? "") as NSString).length
            if length == 0 {
                return
            }
            textView.layoutIfNeeded()
            textView.scrollRangeToVisible(NSRange(location: length - 1, length: 1))
        }
    }

    func updateTextHint() {
        // 按住转文字时出错，在气泡里提示；松手后没有文字时换成红色的提示气泡
        let show = asrFailed && stage == .recording && (textView.text ?? "").isEmpty
        placeholderLabel.text = show ? texts.recognizeFailed : nil
    }

    func showTooShortTip() {
        showHint(texts.tooShort, color: bubbleContentColor)
        animateBubbleTo(.tooShort)
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -10, 10, -7, 7, -3, 3, 0]
        shake.duration = 0.42
        shake.beginTime = CACurrentMediaTime() + 0.1
        shake.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        bubbleView.layer.add(shake, forKey: "shake")
        let item = DispatchWorkItem { [weak self] in
            self?.dismissOverlay()
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    /// 设置气泡里的提示，前面的感叹号图标和文字同色
    private func showHint(_ text: String, color: UIColor) {
        let font = VoiceHoldPanel.hintFont
        let icon = VoiceIcons.warningImage(color: color, size: 20)
        let attachment = NSTextAttachment()
        attachment.image = icon
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - icon.size.height) / 2, width: icon.size.width, height: icon.size.height)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(attachment: attachment))
        result.append(NSAttributedString(string: " " + text, attributes: [.font: font, .foregroundColor: color]))
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        hintLabel.attributedText = result
    }

    func showCountDown(_ seconds: Int) {
        countDownLabel.text = texts.countDown.replacingOccurrences(of: "%d", with: String(seconds))
        if !countDownShown {
            countDownShown = true
            UIView.animate(withDuration: 0.2) {
                self.countDownLabel.alpha = 1
            }
        }
    }

    // MARK: - 编辑文字

    /// 在「转文字」上松手：底部按钮落下，换成取消、发送原语音、发送；识别结果全部返回后可以编辑文字
    func enterEditing() {
        UIView.animate(withDuration: 0.15) {
            self.countDownLabel.alpha = 0
        }
        bottomView.hide()
        panelTop.animate(to: editPanelTop(), duration: 0.36, easing: VoiceEasing.fastOutSlowIn)
        panelLink.start()
        // 编辑文字时浮层才接管触摸
        overlay.interactive = true
        observeKeyboard()
        updateTextHint()
        updateEditActions()
        showEditActions()
        if let manager = asrManager {
            // 录音已经停止，声波换成等待动画，剩余识别结果返回后回调 onFinalResult
            waveView.loading = true
            animateBubbleTo(.edit)
            manager.stopRecognition()
        } else {
            // 识别已经结束，或者出错了
            asrFinished = true
            onRecognitionDoneInEditing()
        }
    }

    func onRecognitionDoneInEditing() {
        waveView.loading = false
        updateTextHint()
        updateEditActions()
        if (textView.text ?? "").isEmpty {
            // 没有识别到文字：红色提示，只能取消或者发送原语音
            showHint(asrFailed ? texts.recognizeFailed : texts.noText, color: .white)
            animateBubbleTo(.noText)
            return
        }
        // 和 ios-chat 一样不主动弹键盘，点文字再编辑
        textView.isEditable = true
        textView.isUserInteractionEnabled = true
        animateBubbleTo(.edit)
    }

    private func isVoiceAvailable() -> Bool {
        guard let pcm = recordedPcm else {
            return false
        }
        return !pcm.isEmpty && recordDuration >= VoiceHoldPanel.minDuration
    }

    private func updateEditActions() {
        sendTextButton.isEnabled = asrFinished && !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendVoiceButton.isEnabled = isVoiceAvailable()
    }

    private func showEditActions() {
        editActionsView.isHidden = false
        editActionsView.alpha = 1
        let children: [(view: UIView, delay: TimeInterval)] = [(cancelActionView, 0.14), (sendVoiceActionView, 0.18), (sendTextButton, 0.26)]
        for child in children {
            let view = child.view
            let alpha: CGFloat = view === sendVoiceActionView && !isVoiceAvailable() ? 0.4 : 1
            view.alpha = 0
            view.transform = CGAffineTransform(translationX: 0, y: VoiceHoldPanel.editActionOffset)
            // 等弧形按钮大部分落下后再升起，两组按钮不在同一时间重叠
            UIView.animate(withDuration: 0.3, delay: child.delay, options: [.curveEaseOut, .allowUserInteraction], animations: {
                view.alpha = alpha
                view.transform = .identity
            }, completion: nil)
        }
    }

    /// 编辑文字时深灰背景完全不透明处，在气泡下边缘稍上方
    private func editPanelTop() -> CGFloat {
        return overlay.bounds.height - keyboardShift - bubbleBottomMargin - bubbleView.tailHeight - 5
    }

    func textViewDidChange(_ textView: UITextView) {
        if stage == .editing && asrFinished && bubbleState == .edit {
            updateEditActions()
            animateBubbleTo(.edit)
        }
    }

    @objc func onEditCancelClick() {
        if stage != .editing {
            return
        }
        cancelSpeechToText()
        listener.onRecordFail(VoiceHoldPanel.reasonUserCanceled)
        dismissOverlay()
    }

    @objc func onSendVoiceClick() {
        if stage != .editing || !isVoiceAvailable() {
            return
        }
        cancelSpeechToText()
        sendVoice()
        dismissOverlay()
    }

    @objc func onSendTextClick() {
        if stage != .editing {
            return
        }
        let text = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return
        }
        listener.onSendText(text)
        dismissOverlay()
    }

    // MARK: - 软键盘

    private func observeKeyboard() {
        if keyboardObserver != nil {
            return
        }
        keyboardObserver = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            self?.onKeyboardFrameChange(note)
        }
    }

    func stopObservingKeyboard() {
        if let observer = keyboardObserver {
            NotificationCenter.default.removeObserver(observer)
            keyboardObserver = nil
        }
    }

    private func onKeyboardFrameChange(_ note: Notification) {
        guard stage == .editing, overlay.window != nil,
              let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else {
            return
        }
        let keyboard = overlay.convert(value.cgRectValue, from: nil)
        let overlap = max(0, overlay.bounds.maxY - keyboard.minY)
        // 和 Android 一致，只把按钮顶到键盘上方 12pt，气泡和深灰背景跟着一起移动，按钮和键盘之间不露出遮罩
        let shift = overlap > 0 ? max(0, overlap - editActionsBottomMargin + 12) : 0
        if abs(shift - keyboardShift) < 0.5 {
            return
        }
        keyboardShift = shift
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        panelTop.animate(to: editPanelTop(), duration: max(0.01, duration), easing: VoiceEasing.decelerate(1))
        panelLink.start()
        UIView.animate(withDuration: duration) {
            self.layoutCountDown()
            self.layoutEditActions()
            self.applyBubbleFrame(self.bubbleFrame)
        }
    }

    // MARK: - 退出

    /// 播放退出动画后关闭浮层
    func dismissOverlay() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        if overlay.superview == nil {
            releaseRecording()
            return
        }
        stage = .dismissing
        overlay.interactive = false
        overlay.endEditing(true)
        stopObservingKeyboard()
        let currentProgress = bubbleProgress.value
        bubbleProgress.set(currentProgress)
        bottomView.hide()
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseIn], animations: {
            self.bubbleView.alpha = 0
            self.bubbleView.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        }, completion: nil)
        UIView.animate(withDuration: 0.15) {
            self.countDownLabel.alpha = 0
            self.editActionsView.alpha = 0
        }
        backgroundCompletion = { [weak self] in
            self?.dismissNow()
        }
        backgroundProgress.animate(to: 0, duration: 0.24, easing: VoiceEasing.linear)
        panelLink.start()
    }

    /// 立即关闭浮层，停止录音和识别，不回调
    func dismissNow() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        // 先置为空闲，关闭浮层时不再当作用户取消
        releaseRecording()
        layoutReady = false
        stopObservingKeyboard()
        backgroundCompletion = nil
        panelLink.pause()
        waveView.stopAnimation()
        bubbleView.layer.removeAllAnimations()
        overlay.interactive = false
        if overlay.superview != nil {
            overlay.endEditing(true)
            overlay.removeFromSuperview()
        }
    }
}
