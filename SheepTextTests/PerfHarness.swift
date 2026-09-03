//
//  PerfHarness.swift
//  Shared timing helper for the PerfHarness*Tests classes.
//
//  Each workload prints one `PERF {...}` JSON line and appends the same line
//  to a results file. Checksums must match across runs — a faster number with
//  a different checksum is a behaviour change, not an optimisation.
//
//  Run with:  scratchpad/perf.sh <label>   (see Benchmarks/results/README)
//

import Foundation

nonisolated enum PerfHarness {

    /// Time `body` and record the median. `iterations` inner calls per sample
    /// amortise very short workloads.
    static func measure(
        _ name: String,
        samples: Int = 7,
        iterations: Int = 1,
        _ body: () -> Int
    ) {
        _ = body() // warm-up
        var times: [Double] = []
        var checksum = 0
        for _ in 0..<samples {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations { checksum &+= body() }
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        times.sort()
        let median = times[times.count / 2]
        let list = times.map { String(format: "%.3f", $0) }.joined(separator: ",")
        let line = "{\"name\":\"\(name)\",\"median_ms\":\(String(format: "%.3f", median)),\"checksum\":\(checksum),\"samples_ms\":[\(list)]}"
        print("PERF " + line)
        appendResult(line)
    }

    /// The test host is the app bundle, whose stdout never reaches the
    /// xcodebuild log — so results also go to a file. Path comes from
    /// `TEST_RUNNER_SHEEPTEXT_PERF_OUT` (xcodebuild strips the prefix) when it
    /// is writable from inside the sandbox, otherwise the container home:
    /// ~/Library/Containers/Bestchaan.SheepText/Data/sheeptext-perf.jsonl
    private static let outputURL: URL = {
        let env = ProcessInfo.processInfo.environment
        if let path = env["SHEEPTEXT_PERF_OUT"], !path.isEmpty,
           FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("sheeptext-perf.jsonl")
    }()

    private static let lock = NSLock()

    private static func appendResult(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: outputURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: outputURL)
        }
    }
}
