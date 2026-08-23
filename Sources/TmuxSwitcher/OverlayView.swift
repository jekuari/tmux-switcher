import AppKit
import TmuxSwitcherCore

/// The content view of the HUD overlay: a picker-wheel of nearby tmux sessions,
/// current session always in the middle slot, with optional direction hints
/// above/below.
///
/// This view builds its full subview tree once (see `OverlayView.init`) and is
/// then repeatedly resized/relaid-out by `configure(window:config:scroll:)`.
/// Pills are reused across calls rather than recreated, since `render` can be
/// called while the panel is already on screen (sessions can change under the
/// user mid-chord).
///
/// The model is a `UIPickerView`-style wheel: a stack of pills scrolls inside
/// `pillStackView`, which holds the visible pills plus one bleed pill above and
/// one below. Every pill shares the exact same geometry, font, and backing
/// style; the only thing that ever differs between them is which one is
/// currently *selected* — the centre-slot pill is tinted (see `PillView.
/// setSelected(_:)`) instead of a separate static selection capsule sitting on
/// top of it, so the highlight reads the same way a native macOS picker
/// highlights its current row.
///
/// That near-uniformity is what makes the "slide, then silently swap content
/// and reset the offset" trick invisible: nothing but a pill's *text*, its
/// *selected* pill index, and (atomically, alongside selection) its text
/// colour ever change, and all of that happens in the same synchronous step
/// as the frame reset — so the frame at the end of a slide and the frame
/// right after the reset are pixel-identical. There is no snapshot and no
/// cross-fade — the previous implementation's ghosting came from
/// cross-fading two overlapping semi-transparent copies of the text, which
/// this design has no equivalent of.
///
/// `pillStackView` lives inside `rowsClipView`, which clips so nothing spills
/// past the panel padding, rounded corners, or the direction hints. Whether
/// glass or legacy pills are in play depends on BOTH `macOS 26.0` availability
/// AND `config.useLiquidGlass` (see `glassSupported`), and can flip at runtime
/// as config hot-reloads — `configure` detects the flip and calls
/// `rebuildPillBacking`.
///
/// `pillStackView` is added directly to `rowsClipView` on both the glass and
/// legacy paths. It is deliberately NOT wrapped in an
/// `NSGlassEffectContainerView`: that container batches the rendering of the
/// glass views beneath it, compositing their shapes from geometry it manages
/// rather than from each view's live frame. During a slide that left the pill
/// shapes painted in place while their `contentView` text — an ordinary view,
/// rendered normally — moved with the stack, producing static pills with
/// drifting labels, and a `tintColor` that never appeared. A container is only
/// needed to fuse neighbouring glass shapes into one, which we explicitly did
/// not want (its `spacing` was pinned to 0), so it bought nothing and cost the
/// animation.
///
/// When glass is inactive (pre-macOS-26, or `config.useLiquidGlass == false`),
/// `pillStackView` is added directly to `rowsClipView` and pills fall back to
/// a plain translucent layer.
@MainActor
final class OverlayView: NSView {

    // MARK: - Layout constants

    fileprivate static let rowHeight: CGFloat = 32
    fileprivate static let pillHeight: CGFloat = 26
    fileprivate static let pillHorizontalInset: CGFloat = 10
    fileprivate static let horizontalPadding: CGFloat = 14
    fileprivate static let verticalPadding: CGFloat = 10
    fileprivate static let minWidth: CGFloat = 200
    fileprivate static let maxWidth: CGFloat = 320
    fileprivate static let cornerRadius: CGFloat = 12
    fileprivate static let hintHeight: CGFloat = 14
    fileprivate static let pillFont = NSFont.systemFont(ofSize: 13)

    // MARK: - Subviews

    private let backgroundEffect: NSVisualEffectView

    /// Clips the rows area. Everything that must never spill past the panel's
    /// padding/corners/hints during a scroll animation lives inside this.
    private let rowsClipView: NSView

    /// Sliding layer: hosts the visible pills plus one bleed pill above and one
    /// below. This is the view that actually translates up/down during a scroll
    /// animation; its frame equals `rowsClipView.bounds` at rest. Never itself
    /// added straight to `rowsClipView` — see the type doc comment.
    private let pillStackView: NSView

    /// Whether the current subview tree is the glass one. Tracks what was
    /// last built by `rebuildPillBacking`, so `configure` only pays for a
    /// rebuild when `glassSupported(config)` actually changes.
    private var glassActive = false

    /// Pooled pills for `RingWindow.visible`, children of `pillStackView`.
    /// Reused across renders; the pool only grows, and excess pills are hidden
    /// rather than removed, avoiding per-render allocation. Emptied and
    /// rebuilt whenever the glass/legacy backing changes, since a `PillView`'s
    /// backing kind is fixed at construction.
    private var visiblePills: [PillView] = []

    /// The two bleed pills, positioned one row height above/below the visible
    /// stack inside `pillStackView`'s own (unclipped) coordinate space. They
    /// are invisible at rest because `rowsClipView` clips to bounds — they only
    /// become visible mid-slide, which is the entire trick that makes a slide
    /// gapless without fabricating placeholder content. Recreated (like
    /// `visiblePills`) whenever the glass/legacy backing changes.
    private var bleedAbovePill = PillView(frame: .zero, useGlass: false)
    private var bleedBelowPill = PillView(frame: .zero, useGlass: false)

    private let topHintLabel: NSTextField
    private let bottomHintLabel: NSTextField

    /// Empty, hidden container reserved for a future keyboard-shortcut cheatsheet
    /// section below the session rows. It contributes zero height today; a later
    /// feature can populate it and give it height without restructuring this view.
    let hintsView: NSView

    // MARK: - Scroll animation state

    /// Visible-row count from the previous `configure` call, or nil before the
    /// first one. Used to detect "first render" and "row count changed", both
    /// of which force `.none` regardless of the requested scroll direction.
    /// Also reset to nil by `rebuildPillBacking`, since a fresh pill pool has
    /// no prior arrangement to slide from either.
    private var previousVisibleCount: Int?

    /// True while a slide's `NSAnimationContext` group is in flight.
    private var isAnimating = false

    /// The window content a running (or just-finished) slide is building
    /// toward. Held rather than applied immediately so that, for the duration
    /// of the slide, the pills keep showing the *old* arrangement — whose bleed
    /// row already holds the name that's sliding into view. Applied (and
    /// cleared) the moment the slide is finalized, whether that's a natural
    /// completion or a new render cutting it short.
    private var pendingWindow: RingWindow?
    private var pendingAreaSize: NSSize?

    /// The direction of the slide `pendingWindow` belongs to. Set by
    /// `startSlide` alongside `pendingWindow`/`pendingAreaSize`, and consulted
    /// by `finalizeInFlightAnimation` to decide whether to rotate the pill
    /// ring (`.next`/`.previous`, the only directions `startSlide` ever runs
    /// for) or fall back to a full reassignment (`.none`, which should be
    /// unreachable here — see `finalizeSlide`).
    private var pendingDirection: ScrollDirection = .none

    /// Bumped every time an in-flight slide is finalized (including at the top
    /// of every `configure`, before a new one may start). A running slide's
    /// completion handler captures the generation it was started under and
    /// no-ops if the generation has since moved on — this is what stops a stale
    /// completion from re-applying content that a faster, later render already
    /// finalized (rapid j/k autorepeat fires renders faster than one slide's
    /// animation duration).
    private var animationGeneration: UInt64 = 0

    /// Callbacks waiting for the pill stack to have no slide in flight.
    /// Registered via `afterAnimationSettles`; drained (and cleared) by
    /// `finalizeInFlightAnimation`, which is the single choke point every
    /// slide passes through whether it completes naturally or is cut short —
    /// so every callback here is guaranteed to fire exactly once and never be
    /// dropped.
    private var settleCallbacks: [() -> Void] = []

    override init(frame frameRect: NSRect) {
        backgroundEffect = NSVisualEffectView(frame: frameRect)
        backgroundEffect.blendingMode = .behindWindow
        backgroundEffect.state = .active
        backgroundEffect.wantsLayer = true
        backgroundEffect.layer?.cornerRadius = Self.cornerRadius
        backgroundEffect.layer?.masksToBounds = true
        backgroundEffect.autoresizingMask = [.width, .height]

        rowsClipView = NSView(frame: .zero)
        rowsClipView.wantsLayer = true
        rowsClipView.layer?.masksToBounds = true

        pillStackView = NSView(frame: .zero)
        pillStackView.wantsLayer = true

        topHintLabel = Self.makeHintLabel()
        bottomHintLabel = Self.makeHintLabel()

        hintsView = NSView(frame: .zero)
        hintsView.isHidden = true

        super.init(frame: frameRect)

        addSubview(backgroundEffect)
        addSubview(rowsClipView)
        addSubview(topHintLabel)
        addSubview(bottomHintLabel)
        addSubview(hintsView)

        // Establishes the initial (legacy) hierarchy and background material.
        // `configure` corrects this to glass on its very first call if
        // macOS 26+ and `config.useLiquidGlass` both say so.
        rebuildPillBacking(useGlass: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeHintLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = NSColor.secondaryLabelColor
        label.alignment = .center
        label.isHidden = true
        return label
    }

    /// Whether glass pills should be used for `config`: requires BOTH
    /// macOS 26+ AND `config.useLiquidGlass`. Re-evaluated on every
    /// `configure` call since the flag can hot-reload at runtime.
    private static func glassSupported(_ config: Config) -> Bool {
        if #available(macOS 26.0, *) {
            return config.useLiquidGlass
        }
        return false
    }

    // MARK: - Sizing

    /// Computes the size this view needs to display `window` under `config`,
    /// without mutating any state. Used by `OverlayPanel` to size the window
    /// before laying out content. Only the visible rows factor into sizing —
    /// bleed rows never appear at rest.
    static func preferredSize(for window: RingWindow, config: Config) -> NSSize {
        var widest: CGFloat = 0
        for row in window.visible {
            let width = (row.name as NSString).size(withAttributes: [.font: pillFont]).width
            widest = max(widest, width)
        }

        let width = min(maxWidth, max(minWidth, widest + horizontalPadding * 2))

        var height = verticalPadding * 2 + CGFloat(window.visible.count) * rowHeight
        if config.showDirectionHints {
            height += hintHeight * 2
        }

        return NSSize(width: width, height: height)
    }

    // MARK: - Configuration

    /// Lays out the pill stack and hints to fill the view's current bounds,
    /// optionally animating a one-row slide. Call `preferredSize(for:config:)`
    /// first and set the view's frame accordingly.
    func configure(window: RingWindow, config: Config, scroll: ScrollDirection) {
        let showHints = config.showDirectionHints
        topHintLabel.isHidden = !showHints
        bottomHintLabel.isHidden = !showHints
        if showHints {
            topHintLabel.stringValue = "k \u{2191}"
            bottomHintLabel.stringValue = "j \u{2193}"
        }

        // Finalize any slide left in flight from a previous render BEFORE doing
        // anything else. Rapid j/k autorepeat can call `configure` every ~30ms,
        // faster than a 200ms slide completes, so each new render must first
        // synchronously settle the previous one: apply its pending content and
        // snap the stack back to rest with a direct (non-`animator()`) frame
        // assignment, which is what actually cancels the running Core Animation
        // frame animation. Only then do we start the new slide.
        finalizeInFlightAnimation()

        // If the config's glass flag hot-reloaded (or, on first call, differs
        // from the legacy default `rebuildPillBacking(useGlass: false)`
        // established at init), swap the whole pill-hosting hierarchy before
        // computing anything else about this render. The old pills are gone
        // and the new ones are blank, so this always forces a non-animated
        // full render regardless of what scroll direction was requested.
        let wantsGlass = Self.glassSupported(config)
        if wantsGlass != glassActive {
            rebuildPillBacking(useGlass: wantsGlass)
        }

        let visibleCount = window.visible.count

        // First render, a row-count change, a backing rebuild (both reset
        // `previousVisibleCount` to nil), or animation disabled by config all
        // force `.none` — a one-row slide is meaningless when the list resized
        // or the pill pool was just rebuilt from scratch, and there's nothing
        // to slide from before the first render.
        let effectiveScroll: ScrollDirection
        if previousVisibleCount == nil || previousVisibleCount != visibleCount || config.scrollAnimationMs <= 0 {
            effectiveScroll = .none
        } else {
            effectiveScroll = scroll
        }
        previousVisibleCount = visibleCount

        let bounds = self.bounds
        var y = bounds.height - Self.verticalPadding
        if showHints {
            y -= Self.hintHeight
            topHintLabel.frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.hintHeight)
        }

        let rowsAreaHeight = CGFloat(visibleCount) * Self.rowHeight
        y -= rowsAreaHeight
        let rowsAreaFrame = NSRect(x: 0, y: y, width: bounds.width, height: rowsAreaHeight)
        rowsClipView.frame = rowsAreaFrame

        let areaSize = rowsAreaFrame.size
        let restingFrame = NSRect(origin: .zero, size: areaSize)

        ensurePillPool(count: visibleCount)

        if showHints {
            y -= Self.hintHeight
            bottomHintLabel.frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.hintHeight)
        }

        // hintsView stays zero-height and hidden; reserved for future content.
        hintsView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 0)

        if effectiveScroll == .none {
            // No animation: apply the new content directly, at rest, and the
            // centre slot is simply the highlighted one.
            applyWindow(window, areaSize: areaSize)
            pillStackView.frame = restingFrame
            applySelection(centerSlot: visibleCount / 2, visibleCount: visibleCount)
        } else {
            // Leave the pills exactly as they are — they still show the OLD
            // arrangement, whose bleed row (in the direction we're about to
            // slide) already holds the name that's about to enter. Only start
            // the slide; the new `window` is applied at completion.
            pillStackView.frame = restingFrame
            startSlide(
                toward: window,
                direction: effectiveScroll,
                restingFrame: restingFrame,
                areaSize: areaSize,
                visibleCount: visibleCount,
                durationMs: config.scrollAnimationMs
            )
        }
    }

    // MARK: - Pill backing (glass vs. legacy)

    /// Tears down and rebuilds the entire pill-hosting hierarchy — the
    /// container structure, every pooled pill, and both bleed pills — for
    /// `useGlass`. Called once from `init` (legacy default) and again from
    /// `configure` whenever `glassSupported(config)` no longer matches
    /// `glassActive`.
    ///
    /// A `PillView`'s glass-or-legacy backing is fixed at construction (see
    /// `PillView.init`), so switching means recreating every pill rather than
    /// reconfiguring existing ones. Everything old is explicitly removed from
    /// its superview first so nothing is left attached (and retained) after
    /// the swap.
    private func rebuildPillBacking(useGlass: Bool) {
        pillStackView.removeFromSuperview()

        for pill in visiblePills {
            pill.removeFromSuperview()
        }
        visiblePills.removeAll()
        bleedAbovePill.removeFromSuperview()
        bleedBelowPill.removeFromSuperview()

        bleedAbovePill = PillView(frame: .zero, useGlass: useGlass)
        bleedBelowPill = PillView(frame: .zero, useGlass: useGlass)
        pillStackView.addSubview(bleedAbovePill)
        pillStackView.addSubview(bleedBelowPill)

        // Identical structure on both paths — see the type doc comment for why
        // no `NSGlassEffectContainerView` wraps this. Only `PillView`'s own
        // backing differs between glass and legacy.
        rowsClipView.addSubview(pillStackView)

        // `.hudWindow` on both paths too: it's the material the HUD was tuned
        // against, and glass has something solid to refract rather than
        // stacking translucency on an already-translucent terminal.
        backgroundEffect.material = .hudWindow

        glassActive = useGlass

        // The pool and bleed pills are all fresh with no prior arrangement;
        // the next `configure` must treat this as a first render.
        previousVisibleCount = nil
    }

    // MARK: - Pill content

    private func ensurePillPool(count: Int) {
        while visiblePills.count < count {
            let pill = PillView(frame: .zero, useGlass: glassActive)
            visiblePills.append(pill)
            pillStackView.addSubview(pill, positioned: .below, relativeTo: bleedAbovePill)
        }
    }

    /// Assigns `window`'s content (visible rows + both bleed rows) to the
    /// pooled pill views, positioned at their resting-layout slots within
    /// `pillStackView`'s local coordinate space. Never itself animated — the
    /// caller decides whether this happens instantly or as the tail end of a
    /// slide.
    private func applyWindow(_ window: RingWindow, areaSize: NSSize) {
        let visible = window.visible
        let rowsAreaHeight = areaSize.height

        for (index, row) in visible.enumerated() {
            let rowSlotY = rowsAreaHeight - CGFloat(index + 1) * Self.rowHeight
            let pill = visiblePills[index]
            pill.isHidden = false
            pill.frame = Self.pillRect(rowSlotY: rowSlotY, areaWidth: areaSize.width)
            pill.configure(name: row.name)
        }

        // Hide any pooled pills left over from a previous, larger render.
        if visiblePills.count > visible.count {
            for index in visible.count..<visiblePills.count {
                visiblePills[index].isHidden = true
            }
        }

        if let above = window.bleedAbove {
            bleedAbovePill.isHidden = false
            bleedAbovePill.frame = Self.pillRect(rowSlotY: rowsAreaHeight, areaWidth: areaSize.width)
            bleedAbovePill.configure(name: above.name)
        } else {
            bleedAbovePill.isHidden = true
        }

        if let below = window.bleedBelow {
            bleedBelowPill.isHidden = false
            bleedBelowPill.frame = Self.pillRect(rowSlotY: -Self.rowHeight, areaWidth: areaSize.width)
            bleedBelowPill.configure(name: below.name)
        } else {
            bleedBelowPill.isHidden = true
        }
    }

    /// Marks the pill at `centerSlot` as selected and every other pill
    /// (including the two bleed pills) as not. `centerSlot` is expressed in
    /// the same index space as `visiblePills`, extended by one slot in each
    /// direction: `-1` means "the pill above the visible stack"
    /// (`bleedAbovePill`) and `visibleCount` means "the pill below it"
    /// (`bleedBelowPill`) — the only way a bleed pill is ever the one that's
    /// about to land in the centre is when there's just a single visible row.
    ///
    /// Called from two places: once a slide's direction is known (so the
    /// highlight starts moving with the pill that will land in the centre,
    /// not the one leaving it — see `startSlide`), and for every `.none`
    /// render, where the centre pill is simply the highlighted one.
    ///
    /// Deliberately NOT called again when a `.next`/`.previous` slide
    /// finalizes: `finalizeSlide` rotates pill *identity* instead of
    /// reassigning content by index, which means the pill this method
    /// selected at slide start is, by construction, already the one sitting
    /// at the new centre slot once the rotation completes — see that
    /// method's doc comment. Calling this again there would be exactly the
    /// redundant selection flip that caused the second flash this whole
    /// scheme exists to eliminate.
    private func applySelection(centerSlot: Int, visibleCount: Int) {
        for index in 0..<visiblePills.count {
            visiblePills[index].setSelected(index < visibleCount && index == centerSlot)
        }
        bleedAbovePill.setSelected(centerSlot == -1)
        bleedBelowPill.setSelected(centerSlot == visibleCount)
    }

    /// Finalizes a `.next`/`.previous` slide by rotating pill *view identity*
    /// by one slot instead of reassigning every pill's content from `window`
    /// by index (which is what `applyWindow` does, and is only correct for
    /// `.none` renders).
    ///
    /// Why rotation is safe here: `OverlayState` only ever requests
    /// `.next`/`.previous` when the session list is unchanged and the step is
    /// exactly ±1 (any other case — first show, a row-count change, a
    /// session-list change, a config flip — arrives as `.none` and never
    /// reaches this method; `configure` also forces `.none` whenever
    /// `previousVisibleCount` doesn't match, so a stale rotation can never
    /// run against a resized window). Under that guarantee, `SessionRing`
    /// promises the new window is the old one's rows shifted by exactly one:
    /// for `.next`, new visible row *i* is old visible row *i+1* (with the
    /// old bottom-bleed row becoming the new bottom visible row), and the
    /// mirror holds for `.previous`. That means every pill view keeps
    /// showing correct content for its NEW slot after nothing but a frame
    /// change — except the single pill that fell out of the window on one
    /// end, which is recycled onto the opposite end and given the one truly
    /// new name.
    ///
    /// Because content is preserved on every view but that one, the pill
    /// `startSlide` selected before the slide began — which already holds
    /// the content of what's *becoming* current — is never one of the
    /// pills whose content changes, and rotation always lands it exactly on
    /// the new centre slot (index arithmetic: `.next` shifts every slot down
    /// by one, and `startSlide` selected the pill one slot below centre;
    /// `.previous` mirrors it with the pill one slot above centre). So no
    /// selection change is needed here — see `applySelection`'s doc comment.
    private func finalizeSlide(direction: ScrollDirection, window: RingWindow, areaSize: NSSize) {
        let activeCount = window.visible.count
        switch direction {
        case .next:
            if let newBelow = window.bleedBelow {
                rotateForward(activeCount: activeCount, newBelowName: newBelow.name)
            }
        case .previous:
            if let newAbove = window.bleedAbove {
                rotateBackward(activeCount: activeCount, newAboveName: newAbove.name)
            }
        case .none:
            // Unreachable: `pendingWindow`/`pendingDirection` are only ever
            // set together by `startSlide`, which returns immediately for
            // `.none` without setting either. Kept as a safe fallback rather
            // than `fatalError` so a violated assumption degrades to the
            // old (flash-prone, but correct) full reassignment instead of
            // corrupting the pill arrangement.
            applyWindow(window, areaSize: areaSize)
            applySelection(centerSlot: activeCount / 2, visibleCount: activeCount)
            return
        }
        repositionRing(areaSize: areaSize, activeCount: activeCount)
    }

    /// Rotates the ring one slot toward `.next`: conceptually
    /// `[bleedAbove] + visible + [bleedBelow]` shifts left by one, i.e. the
    /// current `bleedAbovePill` — already scrolled off the top, and no
    /// longer part of the new window at all — is recycled as the new
    /// `bleedBelowPill` and given the one name that's genuinely new
    /// (`window.bleedBelow`). Every other pill's content is untouched; only
    /// its ring position (and, via `repositionRing`, its frame) moves up by
    /// one slot.
    private func rotateForward(activeCount: Int, newBelowName: String) {
        guard activeCount > 0 else { return }
        let recycled = bleedAbovePill
        bleedAbovePill = visiblePills[0]
        for index in 0..<(activeCount - 1) {
            visiblePills[index] = visiblePills[index + 1]
        }
        visiblePills[activeCount - 1] = bleedBelowPill
        bleedBelowPill = recycled
        bleedBelowPill.configure(name: newBelowName)
    }

    /// Mirror of `rotateForward` for `.previous`: the ring shifts right by
    /// one. The current `bleedBelowPill` — no longer part of the new window
    /// — is recycled as the new `bleedAbovePill` and given the one genuinely
    /// new name (`window.bleedAbove`); everything else keeps its content and
    /// moves down by one slot.
    private func rotateBackward(activeCount: Int, newAboveName: String) {
        guard activeCount > 0 else { return }
        let recycled = bleedBelowPill
        bleedBelowPill = visiblePills[activeCount - 1]
        var index = activeCount - 1
        while index > 0 {
            visiblePills[index] = visiblePills[index - 1]
            index -= 1
        }
        visiblePills[0] = bleedAbovePill
        bleedAbovePill = recycled
        bleedAbovePill.configure(name: newAboveName)
    }

    /// Repositions every pill in the active ring (`bleedAbovePill`,
    /// `visiblePills[0..<activeCount]`, `bleedBelowPill`) to its resting slot
    /// frame within `pillStackView`'s local coordinate space. Content is not
    /// touched here — callers (`rotateForward`/`rotateBackward`) have
    /// already handled that by the time this runs. Pool pills beyond
    /// `activeCount` (left over from a previously larger render) are
    /// deliberately left alone, exactly as `applyWindow` leaves them.
    private func repositionRing(areaSize: NSSize, activeCount: Int) {
        let rowsAreaHeight = areaSize.height
        for index in 0..<activeCount {
            let rowSlotY = rowsAreaHeight - CGFloat(index + 1) * Self.rowHeight
            visiblePills[index].frame = Self.pillRect(rowSlotY: rowSlotY, areaWidth: areaSize.width)
        }
        bleedAbovePill.frame = Self.pillRect(rowSlotY: rowsAreaHeight, areaWidth: areaSize.width)
        bleedBelowPill.frame = Self.pillRect(rowSlotY: -Self.rowHeight, areaWidth: areaSize.width)
    }

    /// A pill's frame for a row slot whose bottom edge sits at local `rowSlotY`
    /// (in `pillStackView`'s coordinate space, y-up), inset horizontally and
    /// centered vertically within the row height.
    private static func pillRect(rowSlotY: CGFloat, areaWidth: CGFloat) -> NSRect {
        let verticalOffset = (rowHeight - pillHeight) / 2
        let width = max(0, areaWidth - 2 * pillHorizontalInset)
        return NSRect(x: pillHorizontalInset, y: rowSlotY + verticalOffset, width: width, height: pillHeight)
    }

    // MARK: - Scroll animation

    /// Starts the slide toward `window`: `pillStackView`'s frame animates from
    /// its current resting position to a one-row offset in `direction`. The
    /// pills' *content* is not touched here — they still show the arrangement
    /// from before this call, whose bleed row (already positioned one row
    /// height off-screen in exactly this direction) is what slides into view.
    /// `window` becomes the content applied when the slide is finalized.
    private func startSlide(
        toward window: RingWindow,
        direction: ScrollDirection,
        restingFrame: NSRect,
        areaSize: NSSize,
        visibleCount: Int,
        durationMs: Int
    ) {
        let rowHeight = Self.rowHeight
        let middleIndex = visibleCount / 2
        let targetFrame: NSRect
        let landingSlot: Int
        switch direction {
        case .next:
            // Names move up; the bleed pill below slides into view from the
            // bottom. The pill that will land in the centre is the one
            // currently one slot BELOW centre — it already holds the name
            // that's about to become current (see `applyWindow`'s doc comment
            // on `pendingWindow`).
            targetFrame = restingFrame.offsetBy(dx: 0, dy: rowHeight)
            landingSlot = middleIndex + 1
        case .previous:
            // Names move down; the bleed pill above slides into view from the
            // top. The pill that will land in the centre is one slot ABOVE
            // centre.
            targetFrame = restingFrame.offsetBy(dx: 0, dy: -rowHeight)
            landingSlot = middleIndex - 1
        case .none:
            return
        }

        // Move the highlight onto the landing pill now, before the animation
        // starts, so it travels into the centre together with its pill rather
        // than appearing to stay behind on the pill that's leaving. This is a
        // direct property set (not `.animator()`), so it's instant rather
        // than animated.
        applySelection(centerSlot: landingSlot, visibleCount: visibleCount)

        pendingWindow = window
        pendingAreaSize = areaSize
        pendingDirection = direction
        isAnimating = true

        animationGeneration &+= 1
        let gen = animationGeneration
        let duration = max(0.0, Double(durationMs) / 1000.0)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            self.pillStackView.animator().frame = targetFrame
        }, completionHandler: { [weak self] in
            // AppKit calls this handler back on the main thread; the compiler
            // just can't see that through the framework's (unannotated)
            // closure type, hence the explicit main-actor assumption here.
            MainActor.assumeIsolated {
                guard let self, self.animationGeneration == gen else { return }
                self.finalizeInFlightAnimation()
            }
        })
    }

    /// Invokes `callback` once no pill slide animation is in flight —
    /// immediately (synchronously) if idle. If a slide is running, `callback`
    /// is queued and fires the moment that slide settles, whether it
    /// completes naturally or is finalized early by a subsequent render or a
    /// dismiss — see `finalizeInFlightAnimation`, the single place every
    /// slide is settled and every queued callback is drained. Guaranteed to
    /// fire exactly once and never be dropped.
    func afterAnimationSettles(_ callback: @escaping () -> Void) {
        if isAnimating {
            settleCallbacks.append(callback)
        } else {
            callback()
        }
    }

    /// Settles any slide left in flight: applies its pending content and snaps
    /// `pillStackView` back to its resting origin with a direct (non-animated)
    /// frame assignment. That direct assignment is what actually cancels a
    /// running Core Animation frame animation on the view — the same technique
    /// `OverlayPanel.present` uses for `alphaValue`.
    ///
    /// Because the frame a slide animates *to* is, by construction, pixel-
    /// identical to the resting frame once the pending content is in place,
    /// this swap is invisible — whether it runs at a slide's natural
    /// completion or because a faster subsequent render cut it short.
    ///
    /// Idempotent, and safe to call with nothing in flight. Called at the top
    /// of every `configure` (so rapid j/k autorepeat never lets a slide's
    /// remaining animation time bleed into the next one) and by
    /// `OverlayPanel.dismiss` (so a dismiss mid-slide never leaves the stack at
    /// a mid-slide offset for a later re-present to inherit).
    ///
    /// Also drains every callback queued by `afterAnimationSettles`, copying
    /// and clearing the queue before invoking any of them so a callback that
    /// re-enters (e.g. triggers another `configure` or `dismiss`) can't see
    /// itself invoked twice.
    func finalizeInFlightAnimation() {
        // Invalidate the generation unconditionally so a completion handler
        // that fires after this point (from the animation this call is
        // finalizing) becomes a no-op rather than finalizing a second time.
        animationGeneration &+= 1

        guard isAnimating else { return }

        if let pending = pendingWindow, let area = pendingAreaSize {
            finalizeSlide(direction: pendingDirection, window: pending, areaSize: area)
        }
        pillStackView.frame = NSRect(origin: .zero, size: pillStackView.frame.size)

        pendingWindow = nil
        pendingAreaSize = nil
        pendingDirection = .none
        isAnimating = false

        let callbacks = settleCallbacks
        settleCallbacks.removeAll()
        for callback in callbacks {
            callback()
        }
    }
}

/// A single pill: a glass (macOS 26+, when enabled) or plain translucent
/// capsule background with a name drawn directly onto a custom view rather
/// than through an `NSTextField` (see `PillTextView`). Every pill in the
/// stack — visible or bleed — shares the same geometry, font, and backing
/// kind; the only things that ever differ between pills are which one is
/// currently selected and, atomically with that, its text colour (see
/// `setSelected(_:)`) — tinting/recolouring the selected pill itself instead
/// of relying on a separate static selection capsule layered on top of
/// everything.
///
/// `OverlayView`'s layout and animation code only ever calls `configure`,
/// `setSelected`, and sets `frame` on this type — it stays unaware of whether
/// the glass or legacy backing is in use underneath.
@MainActor
private final class PillView: NSView {

    private static let legacyNormalColor = NSColor.labelColor.withAlphaComponent(0.07)

    /// A solid, fully-opaque blue — Apple's standard UI blue, not the
    /// user-configurable `controlAccentColor` (System Settings' accent may
    /// not be blue at all) — so the selected pill reads like a selected
    /// macOS table row rather than a translucent wash.
    private static let legacySelectedColor = NSColor.systemBlue

    /// Left fully opaque (no `withAlphaComponent`) so the glass renders as
    /// confident a blue as its material allows, rather than the washed-out
    /// low-alpha accent tint this used to be — paired with white text (see
    /// `setSelected`), matching a selected macOS table row instead of a wash
    /// that leaves dark text sitting on top of a faint blue.
    private static let glassSelectedTint = NSColor.systemBlue

    private let textView: PillTextView

    /// Runtime type is `NSGlassEffectView` when `useGlass` was true at init
    /// (which itself requires macOS 26+); `nil` otherwise, where `self` is a
    /// plain layer-backed capsule instead. Typed as plain `NSView` (rather
    /// than `NSGlassEffectView?`) because a stored property's *declared*
    /// type is checked for availability regardless of whether it's ever
    /// non-nil — only the handful of call sites that actually need
    /// glass-specific members downcast, each behind its own `#available`.
    private let glassBacking: NSView?

    /// Current selected state, tracked so `setSelected` can no-op on a
    /// redundant call instead of touching layer properties / triggering a
    /// redraw for a state that isn't actually changing. Belt and braces
    /// alongside `OverlayView`'s rotation scheme, which already avoids
    /// calling this redundantly in the steady-state slide path — this just
    /// makes any remaining redundant call (e.g. a `.none` render re-applying
    /// the same selection) free too.
    private var isSelected = false

    /// - Parameter useGlass: Whether this pill should use its glass backing.
    ///   Only takes effect on macOS 26+ regardless of this value; on earlier
    ///   systems the legacy backing is always used. Decided once by the
    ///   caller (`OverlayView.rebuildPillBacking`, from `config.useLiquidGlass`)
    ///   and fixed for this pill's lifetime — flipping the config recreates
    ///   pills rather than reconfiguring existing ones.
    init(frame frameRect: NSRect, useGlass: Bool) {
        textView = PillTextView(frame: .zero)

        if useGlass, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.style = .regular
            glass.contentView = textView
            glassBacking = glass
        } else {
            glassBacking = nil
        }

        super.init(frame: frameRect)

        if let glassBacking {
            wantsLayer = true
            addSubview(glassBacking)
        } else {
            wantsLayer = true
            layer?.backgroundColor = Self.legacyNormalColor.cgColor
            addSubview(textView)
        }

        applyLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(name: String) {
        textView.setTitle(name)
    }

    /// Tints the selected pill instead of drawing a separate static selection
    /// capsule behind it — the same look and feel as a native macOS picker,
    /// which highlights its current row by changing that row's own
    /// background rather than overlaying something on top of it.
    ///
    /// Sets the background/tint AND the text colour in one synchronous call,
    /// so callers that apply selection atomically alongside a content swap
    /// (see `OverlayView.applySelection`) never produce a frame where one
    /// has updated and the other hasn't.
    ///
    /// Idempotent: a call that doesn't change `isSelected` returns
    /// immediately without touching the text colour, any layer property, or
    /// triggering a redraw.
    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected

        textView.setTextColor(selected ? .white : .labelColor)

        // Layer properties animate IMPLICITLY by default (~0.25s), so a pill
        // losing the selection would visibly tween blue -> clear instead of
        // switching. Washed-out blue over the HUD material reads as a grey
        // ghost in whichever neighbour just got deselected — alternating with
        // the scroll direction, which is exactly the reported symptom.
        // Selection is a discrete state; it must not tween. This nested
        // transaction only suppresses actions for these assignments and does
        // not touch the explicit slide animation running on the pill stack.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if #available(macOS 26.0, *), let glass = glassBacking as? NSGlassEffectView {
            glass.tintColor = selected ? Self.glassSelectedTint : nil
            // Belt and braces: also paint the pill's own layer, which sits
            // behind the glass subview. How strongly `NSGlassEffectView`
            // renders `tintColor` depends on the material and what's behind
            // it, and a selection that doesn't obviously read as selected is
            // a functional failure, not a cosmetic one. Painting behind the
            // glass guarantees blue while still letting it refract.
            layer?.backgroundColor = (selected ? Self.glassSelectedTint : .clear).cgColor
        } else {
            layer?.backgroundColor = (selected ? Self.legacySelectedColor : Self.legacyNormalColor).cgColor
        }
    }

    /// Intercepting the `frame` setter (rather than overriding `layout()`,
    /// which AppKit only invokes during its own layout pass) guarantees the
    /// corner radius and content frame are always in sync with whatever frame
    /// `OverlayView` just assigned, including the one-shot direct assignments
    /// used outside of any animation.
    override var frame: NSRect {
        get { super.frame }
        set {
            super.frame = newValue
            applyLayout()
        }
    }

    private func applyLayout() {
        let contentFrame = NSRect(origin: .zero, size: bounds.size)

        // Same reasoning as `setSelected`: cornerRadius and frame changes on a
        // layer-backed view tween implicitly, which would make pills visibly
        // morph when the panel resizes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Corner radius on both paths: the glass path now paints its own layer
        // behind the glass for the selected state (see `setSelected`), so that
        // layer has to be pill-shaped too or the blue shows up as a rectangle.
        layer?.cornerRadius = bounds.height / 2
        if #available(macOS 26.0, *), let glass = glassBacking as? NSGlassEffectView {
            glass.cornerRadius = bounds.height / 2
            glass.frame = contentFrame
        }
        textView.frame = contentFrame
    }
}

/// Draws a pill's name directly instead of through an `NSTextField`, whose
/// cell layout fights precise baseline placement with its own padding rules
/// built around the full ascender-to-descender line box rather than the
/// visually-relevant cap-height box.
///
/// In an unflipped view (the AppKit default — deliberately not overridden
/// here), drawing the string with its origin at
/// `bounds.midY - font.capHeight / 2 + font.descender` centers its
/// CAP-HEIGHT box exactly on `bounds`. That's what actually reads as
/// centered: the ascender reserves headroom for diacritics and tall glyphs
/// that session names essentially never use, so centering on the full line
/// box instead sits visibly high.
@MainActor
private final class PillTextView: NSView {

    private var title: String = ""

    /// Set atomically alongside selection by `PillView.setSelected(_:)`:
    /// white on the selected pill, `labelColor` otherwise.
    private var textColor: NSColor = .labelColor

    func setTitle(_ newTitle: String) {
        guard newTitle != title else { return }
        title = newTitle
        needsDisplay = true
    }

    func setTextColor(_ newColor: NSColor) {
        guard newColor != textColor else { return }
        textColor = newColor
        needsDisplay = true
    }

    override var frame: NSRect {
        get { super.frame }
        set {
            super.frame = newValue
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = OverlayView.pillFont
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let text = Self.truncated(title, toFit: bounds.width, attributes: attrs) as NSString
        let size = text.size(withAttributes: attrs)

        let origin = NSPoint(
            x: (bounds.width - size.width).rounded() / 2,
            y: bounds.midY - font.capHeight / 2 + font.descender
        )
        text.draw(at: origin, withAttributes: attrs)
    }

    /// Tail-truncates `string` with an ellipsis so it fits within `width`,
    /// measuring with `attributes`. An `NSTextField`'s cell did this for
    /// free; drawing the string ourselves means truncating it ourselves too.
    private static func truncated(_ string: String, toFit width: CGFloat, attributes: [NSAttributedString.Key: Any]) -> String {
        guard width > 0 else { return "" }
        if (string as NSString).size(withAttributes: attributes).width <= width {
            return string
        }

        let ellipsis = "\u{2026}"
        guard (ellipsis as NSString).size(withAttributes: attributes).width <= width else {
            return ""
        }

        var candidate = string
        while !candidate.isEmpty {
            candidate.removeLast()
            let attempt = candidate + ellipsis
            if (attempt as NSString).size(withAttributes: attributes).width <= width {
                return attempt
            }
        }
        return ellipsis
    }
}
