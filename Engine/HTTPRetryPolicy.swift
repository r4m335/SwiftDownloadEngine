import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Centralizes the retry boundary for foreground HTTP transfers.
/// Only transient transport failures, HTTP 5xx, and HTTP 429 are retryable.
enum HTTPRetryPolicy {
    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }

        if let probeError = error as? HTTPRangeProbeError {
            switch probeError {
            case .rateLimited:
                return true
            case .unsupportedResponse(let statusCode, _):
                return (500...599).contains(statusCode)
            case .networkError(_, let code):
                return code.map { isRetryableNetworkCode($0) } ?? true
            case .invalidURL, .resourceNotFound, .unauthorized, .forbidden,
                 .rangeNotSatisfiable, .invalidResponseFormat:
                return false
            }
        }

        if let segmentError = error as? SegmentDownloaderError {
            switch segmentError {
            case .rateLimited:
                return true
            case .unexpectedStatus(_, let actual):
                return (500...599).contains(actual)
            case .bodyLengthMismatch:
                // A premature EOF commonly surfaces as a short body after a
                // connection drop; retrying the range is safe.
                return true
            case .invalidHTTPResponse, .invalidContentRange, .contentRangeMismatch,
                 .totalSizeMismatch, .tokenExpired, .accessDenied, .linkExpired,
                 .htmlErrorPageReceived, .cancelled:
                return false
            }
        }

        if let urlError = error as? URLError {
            if isRetryableNetworkCode(urlError.code.rawValue) {
                return true
            }
            if urlError.code.rawValue == -1 {
                let desc = urlError.localizedDescription.lowercased()
                if desc.contains("missing") || desc.contains("partial") || desc.contains("closed") || desc.contains("connection") || desc.contains("eof") {
                    return true
                }
            }
            return false
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if isRetryableNetworkCode(nsError.code) {
                return true
            }
            if nsError.code == -1 {
                let desc = nsError.localizedDescription.lowercased()
                if desc.contains("missing") || desc.contains("partial") || desc.contains("closed") || desc.contains("connection") || desc.contains("eof") {
                    return true
                }
            }
            return false
        }
        return false
    }

    /// Background URLSession reports a smaller, transport-specific error
    /// vocabulary than the foreground segment downloader. Keep the same
    /// retry boundary: only 429, 5xx, short bodies, and transient transport
    /// failures may be scheduled again.
    static func isRetryableBackground(_ error: Error) -> Bool {
        if let status = backgroundHTTPStatusCode(error) {
            if status == 429 || (500...599).contains(status) {
                return true
            }
            if (400...499).contains(status) {
                return false
            }
        }

        if let backgroundError = error as? BackgroundTransportError {
            switch backgroundError {
            case .unexpectedStatus(_, let actual):
                return actual == 429 || (500...599).contains(actual)
            case .bodyLengthMismatch:
                return true
            case .invalidHTTPResponse, .invalidContentRange, .contentRangeMismatch,
                 .totalSizeMismatch, .contentRangeWildcardTotalRejected,
                 .htmlErrorPageReceived, .taskNotFound, .temporaryFileMissing,
                 .fileRelocationFailed, .corruptedMappingStore, .cancelled:
                return false
            }
        }

        return isRetryable(error)
    }

    static func backgroundHTTPStatusCode(_ error: Error) -> Int? {
        if let backgroundError = error as? BackgroundTransportError,
           case .unexpectedStatus(_, let actual) = backgroundError {
            return actual
        }
        let nsError = error as NSError
        if let response = (nsError.userInfo["response"] ?? nsError.userInfo["NSErrorFailingURLResponseKey"]) as? HTTPURLResponse {
            return response.statusCode
        }
        if let status = nsError.userInfo["HTTPStatus"] as? Int {
            return status
        }
        if let status = nsError.userInfo["statusCode"] as? Int {
            return status
        }
        if let status = nsError.userInfo["HTTPStatusCode"] as? Int {
            return status
        }
        return nil
    }

    static func shouldWaitForConnectivity(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else {
            if let probeError = error as? HTTPRangeProbeError,
               case .networkError(_, let code) = probeError,
               let code {
                return isOfflineNetworkCode(code)
            }
            return false
        }
        return isOfflineNetworkCode(urlError.code.rawValue)
    }

    private static func isRetryableNetworkCode(_ code: Int) -> Bool {
        isOfflineNetworkCode(code) || [
            URLError.Code.timedOut.rawValue,
            URLError.Code.networkConnectionLost.rawValue,
            URLError.Code.cannotConnectToHost.rawValue,
            URLError.Code.cannotFindHost.rawValue,
            URLError.Code.dnsLookupFailed.rawValue,
            URLError.Code.cannotLoadFromNetwork.rawValue,
            URLError.Code.secureConnectionFailed.rawValue
        ].contains(code)
    }

    private static func isOfflineNetworkCode(_ code: Int) -> Bool {
        [
            URLError.Code.notConnectedToInternet.rawValue,
            URLError.Code.networkConnectionLost.rawValue,
            URLError.Code.cannotConnectToHost.rawValue,
            URLError.Code.cannotFindHost.rawValue,
            URLError.Code.dnsLookupFailed.rawValue,
            URLError.Code.cannotLoadFromNetwork.rawValue
        ].contains(code)
    }
}
