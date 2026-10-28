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
            return isRetryableNetworkCode(urlError.code.rawValue)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return isRetryableNetworkCode(nsError.code)
        }
        return false
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
