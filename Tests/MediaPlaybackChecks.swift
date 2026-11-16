import Foundation

@main
struct MediaPlaybackChecks {
    static func main() {
        func decode(_ json: String) -> MediaPlaybackResult { .decode(Data(json.utf8)) }
        assert(decode("{\"status\":\"confirmed\",\"playing\":true}") == .confirmed(playing: true))
        assert(decode("{\"status\":\"confirmed\",\"playing\":false}") == .confirmed(playing: false))
        assert(decode("{\"status\":\"confirmed\"}") == .failed)
        assert(decode("{\"status\":\"noPlayer\"}") == .noPlayer)
        assert(decode("{\"status\":\"failed\",\"playing\":true}") == .failed)
        assert(decode("invalid") == .failed)
        print("Media result checks passed: no success HUD without confirmed state")

        guard CommandLine.arguments.contains("--live") else { return }
        func perform(_ command: MediaPlaybackController.Command) -> MediaPlaybackResult {
            var result: MediaPlaybackResult?
            MediaPlaybackController.perform(command) { result = $0 }
            let deadline = Date().addingTimeInterval(4)
            while result == nil && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return result ?? .failed
        }
        func toggle() -> MediaPlaybackResult {
            var result: MediaPlaybackResult?
            MediaPlaybackController.toggle { result = $0 }
            let deadline = Date().addingTimeInterval(8)
            while result == nil && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            return result ?? .failed
        }
        guard case .confirmed(let original) = perform(.query) else {
            print("No active player; live check skipped")
            exit(1)
        }
        let changed = toggle()
        // Always use an explicit command to restore the original state, even
        // if the toggle was applied but its confirmation failed.
        let restored = perform(original ? .play : .pause)
        assert(restored == .confirmed(playing: original), "Failed to restore original playback state")
        assert(changed == .confirmed(playing: !original), "The active player did not change state")
        print("Live media check passed: toggled active player and restored original playback state")
    }
}
