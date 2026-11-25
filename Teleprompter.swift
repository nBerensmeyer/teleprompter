import AppKit

// Minimal teleprompter: a floating panel just below the camera.
// Esc = edit/read · Space or click = play/pause · ↑/↓ speed · +/- size · R = top · drag = move · ⌘Q quit

final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PrompterTextView: NSTextView {
    weak var controller: Controller?

    override func keyDown(with e: NSEvent) {
        if controller?.handleKey(e) == true { return }
        super.keyDown(with: e)
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.modifierFlags.contains(.command),
              let c = e.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: e)
        }
        switch c {
        case "v": paste(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "a": selectAll(nil)
        case "z": e.modifierFlags.contains(.shift) ? undoManager?.redo() : undoManager?.undo()
        case "q", "w": NSApp.terminate(nil)
        case "\r": controller?.toggleEditing()
        default: return super.performKeyEquivalent(with: e)
        }
        return true
    }

    // In read mode: click = play/pause, drag = move window.
    override func mouseDown(with e: NSEvent) {
        guard let c = controller, !c.editing, let w = window else {
            super.mouseDown(with: e); return
        }
        let before = w.frame.origin
        w.performDrag(with: e)
        if w.frame.origin == before { c.togglePlay() }
    }

    override func scrollWheel(with e: NSEvent) {
        super.scrollWheel(with: e)
        controller?.syncOffset()
    }
}

final class Controller: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    let defaults = UserDefaults.standard
    var panel: Panel!
    var scrollView: NSScrollView!
    var textView: PrompterTextView!
    var hint: NSTextField!
    var link: CADisplayLink?
    var editing = true
    var playing: Bool { link != nil }
    var offset: CGFloat = 0
    var lastTick: CFTimeInterval = 0

    var speed: CGFloat {
        get { let v = defaults.double(forKey: "speed"); return v > 0 ? v : 40 }
        set { defaults.set(Double(max(5, min(400, newValue))), forKey: "speed") }
    }
    var fontSize: CGFloat {
        get { let v = defaults.double(forKey: "fontSize"); return v > 0 ? v : 32 }
        set { defaults.set(Double(max(14, min(96, newValue))), forKey: "fontSize") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon, can float over fullscreen apps

        let screen = NSScreen.main!
        let size = NSSize(width: 720, height: 210)
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.visibleFrame.maxY - size.height,
                           width: size.width, height: size.height)

        panel = Panel(contentRect: frame,
                      styleMask: [.borderless, .resizable, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = NSSize(width: 300, height: 100)
        panel.setFrameAutosaveName("TeleprompterPanel")

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(white: 0, alpha: 0.88).cgColor
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true
        panel.contentView = content

        scrollView = NSScrollView(frame: content.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        textView = PrompterTextView(frame: scrollView.bounds)
        textView.controller = self
        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 28, height: 18)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.string = defaults.string(forKey: "text") ?? ""
        scrollView.documentView = textView
        content.addSubview(scrollView)

        hint = NSTextField(labelWithString: "")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = NSColor(white: 1, alpha: 0.45)
        hint.alignment = .center
        hint.frame = NSRect(x: 0, y: 4, width: size.width, height: 16)
        hint.autoresizingMask = [.width]
        content.addSubview(hint)

        applyStyle()
        setEditing(textView.string.isEmpty)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    func applyStyle() {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.lineHeightMultiple = 1.2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: p,
        ]
        textView.typingAttributes = attrs
        textView.textStorage?.setAttributes(attrs, range: NSRange(location: 0, length: textView.string.utf16.count))
        updateHint()
    }

    func updateHint() {
        if editing {
            hint.stringValue = textView.string.isEmpty
                ? "Text einfügen (⌘V) · dann Esc zum Lesen · ⌘Q beenden"
                : "BEARBEITEN · Esc zum Lesen · ⌘Q beenden"
        } else {
            hint.stringValue = "Leertaste/Klick ▶︎❙❙ · ↑↓ Tempo \(Int(speed)) · +/− Größe \(Int(fontSize)) · R Anfang · Esc Bearbeiten · Ziehen = verschieben"
        }
        hint.isHidden = playing
    }

    // MARK: modes

    func toggleEditing() { setEditing(!editing) }

    func setEditing(_ on: Bool) {
        if on { pause() }
        editing = on
        textView.isEditable = on
        if !on { textView.setSelectedRange(NSRange(location: 0, length: 0)); syncOffset() }
        updateHint()
    }

    func togglePlay() { playing ? pause() : play() }

    func play() {
        if editing { setEditing(false) }
        syncOffset()
        if offset >= maxOffset - 1 { offset = 0; scroll() } // restart from top when at end
        lastTick = CACurrentMediaTime()
        // Fires once per display refresh (no wasted ticks), and only while playing.
        link = scrollView.displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
        updateHint()
    }

    func pause() {
        link?.invalidate(); link = nil
        updateHint()
    }

    // MARK: scrolling

    var maxOffset: CGFloat {
        max(0, textView.frame.height - scrollView.contentView.bounds.height)
    }

    func syncOffset() { offset = scrollView.contentView.bounds.origin.y }

    // Snap to whole device pixels and skip frames where that doesn't move anything:
    // at slow speeds most frames advance less than a pixel.
    func scroll() {
        let clip = scrollView.contentView
        let scale = panel.backingScaleFactor
        let y = (offset * scale).rounded() / scale
        if clip.bounds.origin.y != y { clip.scroll(to: NSPoint(x: 0, y: y)) }
    }

    @objc func tick() {
        let now = CACurrentMediaTime()
        offset += speed * CGFloat(now - lastTick)
        lastTick = now
        if offset >= maxOffset { offset = maxOffset; scroll(); pause(); return }
        scroll()
    }

    // MARK: keys (read mode only; edit mode only intercepts Esc)

    func handleKey(_ e: NSEvent) -> Bool {
        if e.keyCode == 53 { toggleEditing(); return true } // Esc
        if editing { return false }
        switch e.keyCode {
        case 49: togglePlay()                         // Space
        case 126: speed += 5; updateHint()            // ↑
        case 125: speed -= 5; updateHint()            // ↓
        case 123: offset = max(0, offset - fontSize * 2); scroll()        // ← nudge back
        case 124: offset = min(maxOffset, offset + fontSize * 2); scroll() // → nudge forward
        default:
            switch e.charactersIgnoringModifiers ?? "" {
            case "+", "=": fontSize += 2; applyStyle()
            case "-": fontSize -= 2; applyStyle()
            case "r", "R": pause(); offset = 0; scroll()
            default: break
            }
        }
        return true // swallow everything else in read mode
    }

    func textDidChange(_ n: Notification) {
        defaults.set(textView.string, forKey: "text")
        updateHint()
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.run()
