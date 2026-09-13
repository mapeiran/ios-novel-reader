import SwiftUI
import CoreImage.CIFilterBuiltins

struct WiFiImportView: View {
    @EnvironmentObject var library: LibraryStore
    @StateObject private var server = LocalHTTPServer()
    @State private var state: LocalHTTPServer.State = .stopped
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("让手机和电脑连接同一个 WiFi，在电脑浏览器打开下面的地址上传 TXT。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                switch state {
                case .running(let url):
                    Text(url.absoluteString)
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                    QRCodeView(text: url.absoluteString)
                        .frame(width: 180, height: 180)
                case .starting:
                    ProgressView("正在启动…")
                case .failed(let error):
                    Text("启动失败：\(error)").foregroundColor(.red)
                case .stopped:
                    Image(systemName: "wifi")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                }

                Button {
                    if case .running = state {
                        server.stop()
                    } else {
                        server.start()
                    }
                } label: {
                    Text(isRunning ? "停止服务" : "启动服务")
                        .frame(maxWidth: 220)
                }
                .buttonStyle(.borderedProminent)

                if let message {
                    Text(message).font(.footnote).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.top, 40)
            .navigationTitle("WiFi传书")
        }
        .onAppear {
            server.onStateChange = { state = $0 }
            server.onFilesReceived = { urls in importFiles(urls) }
        }
        .onDisappear {
            server.stop()
        }
    }

    private var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    private func importFiles(_ urls: [URL]) {
        let service = BookImportService(storage: library.storage)
        var finished = 0
        var imported = 0
        var duplicates: [String] = []
        for url in urls {
            service.importFile(at: url) { result in
                finished += 1
                switch result {
                case .success(let book):
                    if let existing = library.findDuplicate(hash: book.contentHash) {
                        library.discard(book)
                        duplicates.append(existing.title)
                    } else {
                        library.add(book)
                        library.parseChapters(for: book)
                        imported += 1
                    }
                case .failure(let error):
                    message = "第 \(finished)/\(urls.count) 个导入失败：\(error.localizedDescription)"
                }
                if finished == urls.count {
                    var parts: [String] = []
                    if imported > 0 { parts.append("已导入 \(imported) 本（后台解析中）") }
                    if !duplicates.isEmpty {
                        parts.append("已跳过重复：\n" + duplicates.map { "《\($0)》" }.joined(separator: "\n"))
                    }
                    if !parts.isEmpty { message = parts.joined(separator: "\n") }
                }
            }
        }
    }
}

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.generate(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.clear
        }
    }

    static func generate(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
