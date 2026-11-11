import CoreAudio
import Foundation

/// What the engine should do to its channels this round.
struct ChannelPlan: Equatable {
    var create: [String] = []
    /// The app's process list changed (a helper came or went).
    var update: [String] = []
    var destroy: [String] = []
}

/// Decides which apps get a channel (PLAN §5.3):
/// - an app needs one when it isn't at 100 % or is muted, as soon as its process appears;
/// - it keeps it while paused, loses it when the app quits,
///   and releases it 10 s after returning to 100 % and unmuted;
/// - without the permission, nobody gets one.
struct ChannelPlanner {
    static let releaseDelay: TimeInterval = 10

    /// When each existing channel's app went back to the default volume.
    private var atDefaultSince: [String: Date] = [:]

    mutating func plan(groups: [AppGroup], volume: (String) -> AppVolume,
                       existing: [String: [AudioObjectID]], permissionGranted: Bool, now: Date) -> ChannelPlan {
        guard permissionGranted else {
            atDefaultSince.removeAll()
            return ChannelPlan(destroy: existing.keys.sorted())
        }

        let groupsByKey = Dictionary(groups.map { ($0.identity.key, $0) }, uniquingKeysWith: { a, _ in a })
        var plan = ChannelPlan()

        for (key, objects) in existing {
            guard let group = groupsByKey[key] else {
                plan.destroy.append(key)
                continue
            }
            if volume(key).needsChannel {
                atDefaultSince.removeValue(forKey: key)
            } else {
                let since = atDefaultSince[key] ?? now
                atDefaultSince[key] = since
                if now.timeIntervalSince(since) >= Self.releaseDelay {
                    plan.destroy.append(key)
                    continue
                }
            }
            if group.processObjects != objects {
                plan.update.append(key)
            }
        }

        for group in groups where existing[group.identity.key] == nil && volume(group.identity.key).needsChannel {
            plan.create.append(group.identity.key)
        }

        for key in plan.destroy { atDefaultSince.removeValue(forKey: key) }
        atDefaultSince = atDefaultSince.filter { existing[$0.key] != nil }

        plan.create.sort()
        plan.update.sort()
        plan.destroy.sort()
        return plan
    }
}

/// Which apps get a row (PLAN §5.9): playing now, or stopped less than 5 s ago.
/// An app that quits disappears immediately.
struct RowVisibility {
    static let linger: TimeInterval = 5

    private var lastPlaying: [String: Date] = [:]

    mutating func visibleKeys(groups: [AppGroup], now: Date) -> [String] {
        var visible: [AppGroup] = []
        for group in groups {
            let key = group.identity.key
            if group.isPlaying {
                lastPlaying[key] = now
                visible.append(group)
            } else if let last = lastPlaying[key], now.timeIntervalSince(last) < Self.linger {
                visible.append(group)
            }
        }
        let present = Set(groups.map(\.identity.key))
        lastPlaying = lastPlaying.filter { present.contains($0.key) }
        return visible
            .sorted { $0.identity.name.localizedCaseInsensitiveCompare($1.identity.name) == .orderedAscending }
            .map(\.identity.key)
    }
}
