import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol ProviderHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: ProviderHTTPTransport {}

public struct ProviderHTTPResponse: Sendable {
    public let data: Data
    public let response: HTTPURLResponse

    public init(data: Data, response: HTTPURLResponse) {
        self.data = data
        self.response = response
    }

    public var statusCode: Int {
        self.response.statusCode
    }
}

public struct ProviderHTTPTransportHandler: ProviderHTTPTransport {
    private let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(_ handler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.handler(request)
    }
}

extension ProviderHTTPTransport {
    public func response(for request: URLRequest) async throws -> ProviderHTTPResponse {
        let (data, response) = try await self.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return ProviderHTTPResponse(data: data, response: httpResponse)
    }
}

public final class ProviderHTTPClient: ProviderHTTPTransport, @unchecked Sendable {
    public static let shared = ProviderHTTPClient()

    private let session: URLSession

    public init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: Self.defaultConfiguration())
    }

    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        #if !os(Linux)
        configuration.waitsForConnectivity = false
        #endif
        return configuration
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.session.data(for: request)
    }
}
