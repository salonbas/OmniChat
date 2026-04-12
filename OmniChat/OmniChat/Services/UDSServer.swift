// UDSServer.swift
// OmniChat
// Unix Domain Socket 伺服器，接收 CLI 的 IPC 請求

import Foundation

/// UDS 伺服器：監聽 CLI 的連線請求
@MainActor
class UDSServer {
    private var serverFD: Int32 = -1
    private var socketPath: String = ""
    private var isRunning = false
    private var onRequest: ((IPCRequest, @escaping (IPCResponse) -> Void) -> Void)?

    /// 啟動伺服器
    func start(config: AppConfig, onRequest: @escaping ((IPCRequest, @escaping (IPCResponse) -> Void) -> Void)) {
        self.onRequest = onRequest
        self.socketPath = config.resolvedSocketPath

        // 清除舊 socket
        unlink(socketPath)

        // 建立 socket
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            print("UDS: 無法建立 socket")
            return
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    let count = min(src.count, 104)
                    dest.update(from: src.baseAddress!, count: count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            print("UDS: bind 失敗 (\(String(cString: strerror(errno))))")
            close(serverFD)
            return
        }

        // Listen
        guard listen(serverFD, 5) == 0 else {
            print("UDS: listen 失敗")
            close(serverFD)
            return
        }

        isRunning = true
        print("UDS: 正在監聽 \(socketPath)")

        // 在背景執行緒接受連線
        Task.detached { [weak self] in
            await self?.acceptLoop()
        }
    }

    /// 停止伺服器
    func stop() {
        isRunning = false
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Private

    private nonisolated func acceptLoop() async {
        while await isRunning {
            let clientFD = accept(await serverFD, nil, nil)
            if clientFD < 0 { continue }

            Task.detached {
                await self.handleClient(clientFD)
            }
        }
    }

    private nonisolated func handleClient(_ fd: Int32) async {
        // 讀取請求
        var buffer = Data()
        let readBuf = UnsafeMutableRawPointer.allocate(byteCount: 8192, alignment: 1)
        defer { readBuf.deallocate() }

        while true {
            let bytesRead = recv(fd, readBuf, 8192, 0)
            if bytesRead <= 0 { close(fd); return }
            buffer.append(readBuf.assumingMemoryBound(to: UInt8.self), count: bytesRead)
            if buffer.contains(0x0A) { break } // 收到換行，表示請求結束
        }

        // 解析換行前的 JSON
        guard let newlineIndex = buffer.firstIndex(of: 0x0A) else { close(fd); return }
        let jsonData = Data(buffer[buffer.startIndex..<newlineIndex])

        guard let request = try? JSONDecoder().decode(IPCRequest.self, from: jsonData) else {
            let err = IPCResponse(status: .error, message: "無法解析請求")
            sendResponse(err, to: fd)
            close(fd)
            return
        }

        // 用 continuation 等待所有回應完成後才關閉 fd
        // respond 回呼中 .ok / .done / .error 表示結束
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            Task { @MainActor in
                self.onRequest?(request) { [fd] response in
                    self.sendResponse(response, to: fd)
                    // 非 streaming 狀態表示結束，關閉 fd
                    if response.status != .streaming && !finished {
                        finished = true
                        close(fd)
                        continuation.resume()
                    }
                }
            }
        }
    }

    private nonisolated func sendResponse(_ response: IPCResponse, to fd: Int32) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        var toSend = data
        toSend.append(0x0A) // 換行分隔
        toSend.withUnsafeBytes { ptr in
            _ = send(fd, ptr.baseAddress!, ptr.count, 0)
        }
    }
}
