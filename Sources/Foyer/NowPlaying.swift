import MediaPlayer

/// MPNowPlayingInfoCenter is process-wide, but two players can overlap (the AVPlayer-to-mpv handoff
/// opens the new window before the old one closes; two windows can also play at once). Only the
/// player that claimed last writes, and a closing player clears the info only if it still owns it.
@MainActor
enum NowPlaying {
    private static var owner: ObjectIdentifier?

    static func claim(_ player: AnyObject) { owner = ObjectIdentifier(player) }

    static func publish(_ player: AnyObject, info: [String: Any], paused: Bool) {
        guard owner == ObjectIdentifier(player) else { return }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = paused ? .paused : .playing
    }

    static func release(_ player: AnyObject) {
        guard owner == ObjectIdentifier(player) else { return }
        owner = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}
