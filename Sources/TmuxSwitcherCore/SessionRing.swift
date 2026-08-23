import Foundation

public struct Row: Equatable, Sendable {
    public let name: String
    /// negative = above (where Meh+k leads), 0 = current, positive = below (Meh+j)
    public let offset: Int

    public var isCurrent: Bool { offset == 0 }

    public init(name: String, offset: Int) {
        self.name = name
        self.offset = offset
    }
}

/// The rows on screen plus the two just outside it.
///
/// The bleed rows are what make a gapless scroll possible: they already hold real
/// text just past the clip boundary, so when the stack slides by one row a real
/// pill moves into view. Without them the entering row would have to be
/// fabricated mid-animation, which is what forces ugly cross-fade tricks.
public struct RingWindow: Equatable, Sendable {
    public let visible: [Row]
    public let bleedAbove: Row?
    public let bleedBelow: Row?

    public init(visible: [Row], bleedAbove: Row?, bleedBelow: Row?) {
        self.visible = visible
        self.bleedAbove = bleedAbove
        self.bleedBelow = bleedBelow
    }
}

public enum SessionRing {
    /// Signed shortest step from `from` to `to` around a ring of `count` items.
    ///
    /// Used to decide which way the HUD should scroll: +1 means the user advanced
    /// one session (Meh+j), -1 means they went back one (Meh+k). Wraparound is
    /// handled, so moving from the last session to the first is +1, not -(count-1).
    /// Ties on an even ring (exact opposites) resolve forward.
    public static func ringStep(from: Int, to: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let forward = ((to - from) % count + count) % count   // 0..<count
        return forward <= count / 2 ? forward : forward - count
    }

    /// Rows shown above (and below) the current one.
    ///
    /// For an odd count every session appears exactly once. For an even count the
    /// radius is deliberately count/2, which makes the diametrically opposite
    /// ("antipodal") session appear at BOTH ends — that is a truthful picture of
    /// the ring, since it really is reachable by the same number of presses in
    /// either direction. Clamped to `maxRadius` for long lists.
    public static func radius(count: Int, maxRadius: Int) -> Int {
        guard count > 1 else { return 0 }
        let full = count % 2 == 1 ? (count - 1) / 2 : count / 2
        return min(full, maxRadius)
    }

    /// Returns rows top-to-bottom, current in the middle. nil if nothing should be shown.
    public static func rows(sessions: [String], currentIndex: Int, maxRadius: Int) -> [Row]? {
        let n = sessions.count
        guard n > 0, currentIndex >= 0, currentIndex < n else { return nil }

        let k = radius(count: n, maxRadius: maxRadius)
        return (-k...k).map { offset in
            Row(name: sessions[wrap(currentIndex + offset, n)], offset: offset)
        }
    }

    /// The visible rows plus the two bleed rows just outside the clip.
    public static func window(sessions: [String], currentIndex: Int, maxRadius: Int) -> RingWindow? {
        guard let visible = rows(sessions: sessions, currentIndex: currentIndex, maxRadius: maxRadius) else {
            return nil
        }
        let n = sessions.count
        // A single session can't scroll anywhere, so there is nothing to bleed in.
        guard n > 1 else {
            return RingWindow(visible: visible, bleedAbove: nil, bleedBelow: nil)
        }

        let k = radius(count: n, maxRadius: maxRadius)
        let above = -(k + 1)
        let below = k + 1
        return RingWindow(
            visible: visible,
            bleedAbove: Row(name: sessions[wrap(currentIndex + above, n)], offset: above),
            bleedBelow: Row(name: sessions[wrap(currentIndex + below, n)], offset: below)
        )
    }

    /// Swift's `%` keeps the sign of the dividend, so a plain `% n` returns a
    /// negative index for rows above the current one. Normalise into `0..<n`.
    private static func wrap(_ index: Int, _ count: Int) -> Int {
        ((index % count) + count) % count
    }
}
