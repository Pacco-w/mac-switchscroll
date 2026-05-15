import Foundation

enum DebugLog {
    static func write(_ message: String) {
        #if DEBUG
        let line = "\(Date()) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/SwitchScrollDebug.log")

        guard let data = line.data(using: .utf8) else {
            return
        }

        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        #endif
    }
}
