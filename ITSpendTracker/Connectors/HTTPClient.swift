import Foundation

/// Minimal HTTP abstraction so connectors can be tested with recorded responses.
protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "ITSpendTracker/1.0 (macOS; personal)"]
        session = URLSession(configuration: configuration, delegate: SameHostRedirects(), delegateQueue: nil)
    }

    /// Credentials travel in headers, so redirects are only followed within the same https host.
    private final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            let original = task.originalRequest?.url
            guard request.url?.scheme == "https", request.url?.host() == original?.host() else { return nil }
            return request
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.malformedResponse("not an HTTP response")
        }
        return (data, http)
    }
}

extension HTTPClient {
    /// Sends the request and returns the body of a 2xx response, mapping errors to `ConnectorError`.
    func fetchData(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200..<300:
            return data
        case 401:
            throw ConnectorError.unauthorized
        case 403:
            throw ConnectorError.forbidden(Self.providerMessage(data))
        default:
            let message = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw ConnectorError.http(status: response.statusCode, message: message)
        }
    }

    /// The provider's human-readable error message (`message` or `error.message`), else the raw body start.
    static func providerMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["message"] as? String { return message }
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        }
        return String(data: data.prefix(300), encoding: .utf8) ?? ""
    }

    func fetchJSON<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> T {
        let data = try await fetchData(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ConnectorError.malformedResponse(String(describing: error))
        }
    }
}

extension URL {
    /// Builds a URL with repeated query items allowed (e.g. `group_by[]`).
    static func api(_ base: String, _ items: [(String, String)]) -> URL {
        var components = URLComponents(string: base)!
        if !items.isEmpty {
            components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
            // `+` is not encoded by URLComponents but is treated as a space by many servers.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        return components.url!
    }
}

/// Parses decimal values that providers send either as JSON numbers or strings.
struct FlexibleDecimal: Decodable, Sendable {
    let value: Decimal

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), let parsed = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")) {
            value = parsed
        } else if let double = try? container.decode(Double.self) {
            value = Decimal(string: String(double), locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(double)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a decimal")
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A number that providers send either as a JSON number or a numeric string (e.g. timestamps, cursors).
struct FlexibleNumber: Decodable, Sendable, Equatable {
    let value: Double
    /// The value as sent, for echoing back as a cursor.
    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
            text = number.rounded() == number ? String(Int64(number)) : String(number)
        } else if let string = try? container.decode(String.self), let number = Double(string) {
            value = number
            text = string
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a number")
        }
    }
}
