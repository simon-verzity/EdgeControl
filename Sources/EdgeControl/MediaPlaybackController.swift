import Foundation

enum MediaPlaybackResult: Equatable {
    case confirmed(playing: Bool)
    case noPlayer
    case failed

    static func decode(_ data: Data) -> Self {
        struct Response: Decodable { let status: String; let playing: Bool? }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return .failed }
        if response.status == "noPlayer" { return .noPlayer }
        guard response.status == "confirmed", let playing = response.playing else { return .failed }
        return .confirmed(playing: playing)
    }
}

enum MediaPlaybackController {
    enum Command: String { case query, toggle, play, pause }

    // Use the same system media session for reading and controlling playback.
    // Simulated media keys depend on Accessibility grants, which can become
    // stale when an ad-hoc-signed development build changes.
    private static let script = """
    ObjC.import('Foundation');
    function run(argv) {
        try {
            const framework = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework');
            if (!framework.load) return JSON.stringify({status: 'failed'});
            const request = $.NSClassFromString('MRNowPlayingRequest');
            const bundle = request.localNowPlayingPlayerPath.client.bundleIdentifier.js;
            if (!bundle) return JSON.stringify({status: 'noPlayer'});
            const before = !!request.localIsPlaying;
            const action = argv[0];
            if (action === 'query') return JSON.stringify({status: 'confirmed', playing: before});
            if (['toggle', 'play', 'pause'].indexOf(action) < 0) return JSON.stringify({status: 'failed'});
            const target = action === 'toggle' ? !before : action === 'play';
            const controller = $.NSClassFromString('MRNowPlayingController').localRouteController;
            // Explicit play/pause commands avoid accidental double toggles.
            controller.sendCommandOptionsCompletion(target ? 0 : 1, $.NSDictionary.alloc.init, null);
            for (let n = 0; n < 12; n++) {
                $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));
                const currentBundle = request.localNowPlayingPlayerPath.client.bundleIdentifier.js;
                if (currentBundle !== bundle) return JSON.stringify({status: 'failed'});
                if (!!request.localIsPlaying === target) {
                    return JSON.stringify({status: 'confirmed', playing: target});
                }
            }
            return JSON.stringify({status: 'failed'});
        } catch (error) {
            return JSON.stringify({status: 'failed'});
        }
    }
    """

    static func perform(_ command: Command = .toggle, completion: @escaping (MediaPlaybackResult) -> Void) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script, command.rawValue]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // All completion bookkeeping runs on the main queue, including timeout.
        var finished = false
        let finish: (MediaPlaybackResult) -> Void = { result in
            guard !finished else { return }
            finished = true
            completion(result)
        }
        process.terminationHandler = { process in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let result = process.terminationStatus == 0 ? MediaPlaybackResult.decode(data) : .failed
            DispatchQueue.main.async { finish(result) }
        }
        do { try process.run() }
        catch { finish(.failed); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard !finished else { return }
            if process.isRunning { process.terminate() }
            // Do not retry with a synthetic toggle: the first command may have
            // reached the player even when confirmation timed out.
            finish(.failed)
        }
    }

    /// Determines the desired state first, then retries only an explicit
    /// play/pause command after a failed confirmation. A second toggle would
    /// be unsafe because the first command may already have reached the player.
    static func toggle(completion: @escaping (MediaPlaybackResult) -> Void) {
        func issue(target: Bool, canRetry: Bool) {
            perform(target ? .play : .pause) { result in
                switch result {
                case .confirmed:
                    completion(result)
                case .noPlayer where canRetry:
                    query(retry: false)
                case .failed where canRetry:
                    verify(target: target)
                default:
                    completion(result)
                }
            }
        }

        func verify(target: Bool) {
            perform(.query) { result in
                switch result {
                case .confirmed(let playing) where playing == target:
                    completion(.confirmed(playing: playing))
                case .confirmed:
                    issue(target: target, canRetry: false)
                default:
                    completion(result)
                }
            }
        }

        func query(retry: Bool) {
            perform(.query) { result in
                switch result {
                case .confirmed(let playing):
                    issue(target: !playing, canRetry: true)
                case .failed where retry:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        query(retry: false)
                    }
                case .noPlayer where retry:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        query(retry: false)
                    }
                default:
                    completion(result)
                }
            }
        }

        query(retry: true)
    }
}
