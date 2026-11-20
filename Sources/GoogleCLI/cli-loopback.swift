import Darwin
import Foundation

/// A one-shot HTTP listener on 127.0.0.1 that receives the OAuth redirect.
final class LoopbackReceiver: @unchecked Sendable {
    let port: UInt16
    private let socket: Int32

    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socket, 4) == 0 else {
            let code = errno
            close(socket)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &length)
            }
        }
        self.socket = socket
        port = UInt16(bigEndian: assigned.sin_port)
    }

    deinit {
        close(socket)
    }

    var redirectURI: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    /// The first request carrying OAuth parameters; other requests (such as
    /// a favicon) get a 404. Nil when nothing arrives in time.
    func receive(timeoutSeconds: Int) -> URL? {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(deadline.timeIntervalSinceNow * 1000, 0))
            guard poll(&descriptor, 1, remaining) > 0 else {
                continue
            }
            let connection = accept(socket, nil, nil)
            guard connection >= 0 else {
                continue
            }
            defer { close(connection) }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else {
                continue
            }
            let head = String(decoding: buffer[0..<count], as: UTF8.self)
            let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
            guard parts.count >= 2, let url = URL(string: "http://127.0.0.1:\(port)\(parts[1])") else {
                respond(connection, status: "400 Bad Request", text: "Bad request.")
                continue
            }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard query.contains(where: { $0.name == "state" }) else {
                respond(connection, status: "404 Not Found", text: "Not found.")
                continue
            }
            respond(connection, status: "200 OK", text: "Google authorization received. You can close this tab.")
            return url
        }
        return nil
    }

    private func respond(_ connection: Int32, status: String, text: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(text.utf8.count)\r\nConnection: close\r\n\r\n\(text)"
        _ = response.withCString { write(connection, $0, strlen($0)) }
    }
}
