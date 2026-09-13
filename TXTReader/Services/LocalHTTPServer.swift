import Foundation
import Network
import Combine

/// 极简局域网 HTTP 服务：手机开服务，电脑浏览器上传 TXT。
/// 骨架实现：串行处理、单文件上传；生产环境建议替换为成熟 HTTP 库。
final class LocalHTTPServer: ObservableObject {

    enum State: Equatable {
        case stopped
        case starting
        case running(URL)
        case failed(String)
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.txtreader.http")
    private(set) var port: UInt16 = 8080

    var onStateChange: ((State) -> Void)?
    var onFilesReceived: (([URL]) -> Void)?

    var serverURL: URL? {
        guard let ip = LocalHTTPServer.wifiIPv4() else { return nil }
        return URL(string: "http://\(ip):\(port)")
    }

    func start(port: UInt16 = 8080) {
        stop()
        self.port = port
        onStateChange?(.starting)

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                onStateChange?(.failed("端口无效"))
                return
            }
            let listener = try NWListener(using: params, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let url = self.serverURL {
                        self.onStateChange?(.running(url))
                    } else {
                        self.onStateChange?(.failed("未获取到局域网 IP"))
                    }
                case .failed(let error):
                    self.onStateChange?(.failed(error.localizedDescription))
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onStateChange?(.failed(error.localizedDescription))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        onStateChange?(.stopped)
    }

    // MARK: - 连接处理

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel() } else { self.receive(on: connection, buffer: buffer) }
                return
            }

            let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
            let header = String(decoding: headerData, as: UTF8.self)
            let body = buffer.subdata(in: headerEnd.upperBound..<buffer.count)
            let contentLength = self.contentLength(from: header)

            if let contentLength, body.count < contentLength, !isComplete {
                self.receive(on: connection, buffer: buffer)
                return
            }

            self.route(header: header, body: body, connection: connection)
        }
    }

    private func route(header: String, body: Data, connection: NWConnection) {
        let firstLine = header.components(separatedBy: "\r\n").first ?? ""

        if firstLine.hasPrefix("GET") {
            respond(connection: connection, html: Self.uploadPage)
        } else if firstLine.hasPrefix("POST") {
            if let boundary = boundary(from: header) {
                let files = parseMultipartAll(body, boundary: boundary)
                var urls: [URL] = []
                for (filename, data) in files {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(filename)
                    try? data.write(to: url, options: .atomic)
                    urls.append(url)
                }
                if !urls.isEmpty {
                    onFilesReceived?(urls)
                    respond(connection: connection, html: Self.successPage(count: urls.count))
                } else {
                    respond(connection: connection, html: Self.failPage)
                }
            } else {
                respond(connection: connection, html: Self.failPage)
            }
        } else {
            respond(connection: connection, html: Self.failPage)
        }
    }

    private func respond(connection: NWConnection, html: String) {
        let body = Data(html.utf8)
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: text/html; charset=utf-8\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - 解析辅助

    private func contentLength(from header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n")
        where line.lowercased().hasPrefix("content-length:") {
            let value = line.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces)
            return value.flatMap { Int($0) }
        }
        return nil
    }

    private func boundary(from header: String) -> String? {
        for line in header.components(separatedBy: "\r\n")
        where line.lowercased().hasPrefix("content-type:") && line.lowercased().contains("boundary=") {
            if let range = line.range(of: "boundary=") {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func parseMultipartAll(_ body: Data, boundary: String) -> [(String, Data)] {
        let delimiter = Data(("--" + boundary).utf8)
        var results: [(String, Data)] = []
        var searchStart = body.startIndex

        while let range = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            var cursor = range.upperBound
            // 结束标记 --boundary--
            if cursor + 1 < body.endIndex, body[cursor] == 0x2D, body[cursor + 1] == 0x2D {
                break
            }
            while cursor < body.endIndex, body[cursor] == 0x0D || body[cursor] == 0x0A {
                cursor += 1
            }
            guard let headerEnd = body.range(of: Data("\r\n\r\n".utf8), in: cursor..<body.endIndex) else { break }
            let header = String(decoding: body.subdata(in: cursor..<headerEnd.lowerBound), as: UTF8.self)
            let dataStart = headerEnd.upperBound
            guard let next = body.range(of: delimiter, in: dataStart..<body.endIndex) else { break }
            var dataEnd = next.lowerBound
            if dataEnd >= dataStart + 2,
               body[dataEnd - 2] == 0x0D, body[dataEnd - 1] == 0x0A {
                dataEnd -= 2
            }
            let filename = self.filename(from: header) ?? "upload.txt"
            results.append((filename, body.subdata(in: dataStart..<dataEnd)))
            // 从下一个 boundary 处继续（不能跳过它，否则会漏掉后续文件）
            searchStart = next.lowerBound
        }
        return results
    }

    private func filename(from header: String) -> String? {
        guard let range = header.range(of: "filename=\"") else { return nil }
        let rest = header[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    // MARK: - 局域网 IPv4

    static func wifiIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr,
                                socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
            pointer = interface.ifa_next
        }
        return address
    }

    // MARK: - 页面

    private static let uploadPage = """
    <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>TXTReader 局域网传书</title>
    <style>
    body{font-family:-apple-system,sans-serif;margin:0;padding:40px;background:#f5f5f7;color:#1d1d1f}
    .card{max-width:560px;margin:0 auto;background:#fff;border-radius:16px;padding:32px;box-shadow:0 8px 30px rgba(0,0,0,.08)}
    h1{font-size:20px;margin:0 0 8px}p{color:#6e6e73;font-size:14px}
    input[type=file]{margin:20px 0;display:block}
    button{background:#0071e3;color:#fff;border:0;border-radius:999px;padding:12px 28px;font-size:15px}
    </style></head><body>
    <div class="card">
      <h1>上传 TXT 到手机</h1>
      <p>可一次选择多个文件，传输完成后手机会自动导入。</p>
      <form method="post" enctype="multipart/form-data" action="/upload">
        <input type="file" name="files" accept=".txt,text/plain" multiple>
        <button type="submit">上传</button>
      </form>
    </div></body></html>
    """

    private static func successPage(count: Int) -> String {
        "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><title>上传成功</title></head>"
        + "<body style=\"font-family:-apple-system;padding:40px\"><h2>上传成功 ✅</h2>"
        + "<p>已接收 \(count) 个文件，正在导入到书架。</p></body></html>"
    }

    private static let failPage = """
    <!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><title>上传失败</title></head>
    <body style="font-family:-apple-system;padding:40px"><h2>上传失败</h2><p>请重试。</p></body></html>
    """
}
