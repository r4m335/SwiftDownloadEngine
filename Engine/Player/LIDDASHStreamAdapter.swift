import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Result of inspecting a DASH manifest for playback eligibility, DRM, and representations.
public struct DASHInspectionResult: Equatable, Sendable {
    public let manifest: DASHManifest
    public let hasDRM: Bool
    public let drmDetails: String?
    public let availableRepresentations: [DASHRepresentation]
    public let selectedRepresentation: DASHRepresentation?
    public let isDynamicLive: Bool
    public let durationSeconds: Double?

    public init(
        manifest: DASHManifest,
        hasDRM: Bool,
        drmDetails: String? = nil,
        availableRepresentations: [DASHRepresentation] = [],
        selectedRepresentation: DASHRepresentation? = nil,
        isDynamicLive: Bool = false,
        durationSeconds: Double? = nil
    ) {
        self.manifest = manifest
        self.hasDRM = hasDRM
        self.drmDetails = drmDetails
        self.availableRepresentations = availableRepresentations
        self.selectedRepresentation = selectedRepresentation
        self.isDynamicLive = isDynamicLive
        self.durationSeconds = durationSeconds
    }
}

/// MPEG-DASH streaming adapter for parsing manifests, detecting DRM protection (Widevine/PlayReady),
/// selecting appropriate representations, and serving clear streams to AVFoundation.
public final class LIDDASHStreamAdapter: NSObject, Sendable {

    public let manifestURL: URL
    public let selectedRepresentationID: String?
    public let requestContext: BrowserRequestContext?
    public let customSchemeURL: URL
    public let dispatchQueue = DispatchQueue(label: "com.r4m335.LIDDASHStreamAdapter", qos: .userInitiated)

    public init(
        manifestURL: URL,
        selectedRepresentationID: String? = nil,
        requestContext: BrowserRequestContext? = nil
    ) {
        self.manifestURL = manifestURL
        self.selectedRepresentationID = selectedRepresentationID
        self.requestContext = requestContext
        self.customSchemeURL = URL(string: "liddash://\(manifestURL.host ?? "stream")\(manifestURL.path)") ?? manifestURL
        super.init()
    }

    // MARK: - Manifest Inspection & DRM Detection

    /// Parses and evaluates an MPD manifest for DRM protection, track representations, and duration.
    public static func inspect(
        manifestData: Data,
        baseURL: URL,
        preferredRepresentationID: String? = nil
    ) throws -> DASHInspectionResult {
        let manifest = try DASHManifestParser.parse(manifestData, baseURL: baseURL)

        var drmDetected = false
        var drmReason = ""
        var allReps: [DASHRepresentation] = []

        for period in manifest.periods {
            for adaptation in period.adaptationSets {
                if adaptation.hasContentProtection {
                    drmDetected = true
                    drmReason = "AdaptationSet (id: \(adaptation.id ?? "default"), content: \(adaptation.contentType ?? "unknown")) specifies ContentProtection."
                }
                for rep in adaptation.representations {
                    allReps.append(rep)
                    if rep.hasContentProtection {
                        drmDetected = true
                        drmReason = "Representation (id: \(rep.id ?? "default")) specifies ContentProtection."
                    }
                }
            }
        }

        // Representation Selection
        var selected: DASHRepresentation? = nil
        if let targetID = preferredRepresentationID, !targetID.isEmpty {
            selected = allReps.first(where: { $0.id == targetID })
        }
        if selected == nil {
            // Rank by highest bandwidth
            selected = allReps.sorted(by: { ($0.bandwidth ?? 0) > ($1.bandwidth ?? 0) }).first
        }

        let isLive = manifest.presentationType == .dynamicPresentation
        let duration = manifest.mediaPresentationDuration

        return DASHInspectionResult(
            manifest: manifest,
            hasDRM: drmDetected,
            drmDetails: drmDetected ? drmReason : nil,
            availableRepresentations: allReps,
            selectedRepresentation: selected,
            isDynamicLive: isLive,
            durationSeconds: duration
        )
    }

    /// Evaluates if an MPD manifest can be played directly, throwing `LIDPlaybackError.drmProtectedDASHUnsupported` if encrypted.
    public static func validateForPlayback(
        manifestData: Data,
        baseURL: URL,
        preferredRepresentationID: String? = nil
    ) throws -> DASHInspectionResult {
        let result = try inspect(manifestData: manifestData, baseURL: baseURL, preferredRepresentationID: preferredRepresentationID)
        if result.hasDRM {
            throw LIDPlaybackError.drmProtectedDASHUnsupported(details: result.drmDetails ?? "Widevine / PlayReady ContentProtection detected in MPD manifest.")
        }
        return result
    }
}

#if canImport(AVFoundation)
extension LIDDASHStreamAdapter: AVAssetResourceLoaderDelegate {

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == "liddash" else {
            return false
        }

        dispatchQueue.async { [weak self] in
            guard let self = self else { return }
            self.handleResourceRequest(loadingRequest)
        }
        return true
    }

    public func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        // Handled upon cancellation
    }

    private func handleResourceRequest(_ loadingRequest: AVAssetResourceLoadingRequest) {
        var req = URLRequest(url: manifestURL)
        if let headers = requestContext?.effectiveHeaders(for: manifestURL) {
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }
        }

        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            if let error = error {
                loadingRequest.finishLoading(with: error)
                return
            }
            guard let data = data else {
                loadingRequest.finishLoading(with: NSError(domain: "com.r4m335.LIDDASHStreamAdapter", code: 404, userInfo: [NSLocalizedDescriptionKey: "Empty DASH manifest response."]))
                return
            }

            do {
                let inspection = try Self.validateForPlayback(manifestData: data, baseURL: self.manifestURL, preferredRepresentationID: self.selectedRepresentationID)
                if let contentInfo = loadingRequest.contentInformationRequest {
                    contentInfo.contentType = "public.mpeg-4"
                    contentInfo.contentLength = Int64(inspection.durationSeconds ?? 0) * 1024 * 1024
                    contentInfo.isByteRangeAccessSupported = true
                }
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        task.resume()
    }
}
#endif
