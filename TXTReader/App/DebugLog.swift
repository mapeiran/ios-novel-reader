import Foundation

/// 轻量诊断日志：同时写沙盒文件与系统日志，便于真机排查
enum DebugLog {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("txtreader.log")
    }()

    static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
        NSLog("[TXTReader] %@", message)
    }
}
