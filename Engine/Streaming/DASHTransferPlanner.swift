import Foundation

public enum DASHMediaType: String, Sendable, Equatable {
    case video
    case audio
}

public enum DASHPlannedResourceKind: String, Sendable, Equatable {
    case initialization
    case mediaSegment
}

public struct DASHByteRange: Sendable, Equatable, Hashable {
    public let start: Int64
    public let end: Int64

    public init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    public var length: Int64 {
        guard end >= start else { return 0 }
        let difference = end - start
        return difference == Int64.max ? Int64.max : difference + 1
    }
}

public struct DASHPlannedResource: Sendable, Equatable {
    public let order: Int
    public let mediaType: DASHMediaType
    public let kind: DASHPlannedResourceKind
    public let url: URL
    public let byteRange: DASHByteRange?
    public let segmentNumber: Int64?
    public let segmentTime: Int64?
    public let duration: Int64?
    public let timescale: Int64

    public init(
        order: Int,
        mediaType: DASHMediaType,
        kind: DASHPlannedResourceKind,
        url: URL,
        byteRange: DASHByteRange? = nil,
        segmentNumber: Int64? = nil,
        segmentTime: Int64? = nil,
        duration: Int64? = nil,
        timescale: Int64 = 1
    ) {
        self.order = order
        self.mediaType = mediaType
        self.kind = kind
        self.url = url
        self.byteRange = byteRange
        self.segmentNumber = segmentNumber
        self.segmentTime = segmentTime
        self.duration = duration
        self.timescale = timescale
    }
}

public struct DASHTransferPlanningLimits: Sendable, Equatable {
    public let maxPeriodDuration: Double
    public let maxSegmentsPerRepresentation: Int
    public let maxTotalSegments: Int
    public let maxExpandedURLLength: Int

    public init(
        maxPeriodDuration: Double = 24 * 60 * 60,
        maxSegmentsPerRepresentation: Int = 100_000,
        maxTotalSegments: Int = 200_000,
        maxExpandedURLLength: Int = 8_192
    ) {
        self.maxPeriodDuration = max(0.01, maxPeriodDuration)
        self.maxSegmentsPerRepresentation = max(1, maxSegmentsPerRepresentation)
        self.maxTotalSegments = max(1, maxTotalSegments)
        self.maxExpandedURLLength = max(128, maxExpandedURLLength)
    }

    public static let `default` = DASHTransferPlanningLimits()
}

public enum DASHVODTransferPlanError: Error, LocalizedError, Sendable, Equatable {
    case dynamicMPD
    case multiplePeriodsUnsupported
    case invalidPeriodDuration
    case periodDurationLimitExceeded
    case noSupportedRepresentation
    case representationNotFound
    case incompatibleMediaTypes
    case drmProtectedRepresentation
    case unsupportedSegmentAddressing
    case missingInitialization
    case malformedTemplate
    case unboundedTimeline
    case timelineExpansionLimitExceeded
    case invalidResourceURL
    case invalidByteRange
    case noMediaSegments

    public var errorDescription: String? {
        switch self {
        case .dynamicMPD:
            return "Dynamic DASH MPDs are not supported for finite VOD planning."
        case .multiplePeriodsUnsupported:
            return "This DASH planner supports one finite Period at a time."
        case .invalidPeriodDuration:
            return "DASH Period duration is missing or invalid for finite planning."
        case .periodDurationLimitExceeded:
            return "DASH Period duration exceeds the planning safety limit."
        case .noSupportedRepresentation:
            return "DASH MPD contains no supported audio or video representation."
        case .representationNotFound:
            return "The requested DASH representation was not found."
        case .incompatibleMediaTypes:
            return "The requested DASH representation is not compatible with its media track."
        case .drmProtectedRepresentation:
            return "DRM-protected DASH representations are not supported by this planner."
        case .unsupportedSegmentAddressing:
            return "DASH segment addressing is unsupported or incomplete."
        case .missingInitialization:
            return "DASH representation is missing its initialization segment."
        case .malformedTemplate:
            return "DASH segment template is malformed or requires unavailable attributes."
        case .unboundedTimeline:
            return "DASH segment timeline is unbounded and cannot produce a finite plan."
        case .timelineExpansionLimitExceeded:
            return "DASH segment expansion exceeds the planning safety limit."
        case .invalidResourceURL:
            return "DASH contains an invalid or unsupported transfer URL."
        case .invalidByteRange:
            return "DASH contains an invalid byte range."
        case .noMediaSegments:
            return "DASH representation contains no media segments."
        }
    }
}

public struct DASHRepresentationTransferPlan: Sendable, Equatable {
    public let mediaType: DASHMediaType
    public let adaptationSetID: String?
    public let representationID: String?
    public let bandwidth: Int64?
    public let codecs: String?
    public let resources: [DASHPlannedResource]
    public let estimatedSegmentCount: Int
    public let estimatedDurationSeconds: Double?
    public let estimatedTransferBytes: Int64?

    public init(
        mediaType: DASHMediaType,
        adaptationSetID: String?,
        representationID: String?,
        bandwidth: Int64?,
        codecs: String?,
        resources: [DASHPlannedResource],
        estimatedSegmentCount: Int,
        estimatedDurationSeconds: Double?,
        estimatedTransferBytes: Int64?
    ) {
        self.mediaType = mediaType
        self.adaptationSetID = adaptationSetID
        self.representationID = representationID
        self.bandwidth = bandwidth
        self.codecs = codecs
        self.resources = resources
        self.estimatedSegmentCount = estimatedSegmentCount
        self.estimatedDurationSeconds = estimatedDurationSeconds
        self.estimatedTransferBytes = estimatedTransferBytes
    }
}

public struct DASHVODTransferPlan: Sendable, Equatable {
    public let manifestURL: URL
    public let periodID: String?
    public let video: DASHRepresentationTransferPlan?
    public let audio: DASHRepresentationTransferPlan?
    public let browserRequestContext: BrowserRequestContext?
    public let estimatedTransferBytes: Int64?

    public init(
        manifestURL: URL,
        periodID: String?,
        video: DASHRepresentationTransferPlan?,
        audio: DASHRepresentationTransferPlan?,
        browserRequestContext: BrowserRequestContext? = nil,
        estimatedTransferBytes: Int64? = nil
    ) {
        self.manifestURL = manifestURL
        self.periodID = periodID
        self.video = video
        self.audio = audio
        self.browserRequestContext = browserRequestContext
        self.estimatedTransferBytes = estimatedTransferBytes
    }

    public var resources: [DASHPlannedResource] {
        (video?.resources ?? []) + (audio?.resources ?? [])
    }

    public var estimatedSegmentCount: Int {
        (video?.estimatedSegmentCount ?? 0) + (audio?.estimatedSegmentCount ?? 0)
    }

    /// Returns headers eligible for this resource. Sensitive credentials are stripped
    /// automatically when a resource is on another origin from the MPD.
    public func requestHeaders(for resource: DASHPlannedResource) -> [String: String] {
        guard let browserRequestContext else { return [:] }
        let headers = browserRequestContext.effectiveHeaders(for: resource.url)
        return BrowserHeaderFilter.stripCredentialsOnRedirect(
            headers: headers,
            from: manifestURL,
            to: resource.url
        )
    }
}

/// Creates a finite, single-Period DASH VOD plan without performing network or
/// download-state operations.
public enum DASHTransferPlanner {

    public static func makeVODPlan(
        from manifest: DASHManifest,
        videoRepresentationID: String? = nil,
        audioRepresentationID: String? = nil,
        browserRequestContext: BrowserRequestContext? = nil,
        limits: DASHTransferPlanningLimits = .default
    ) throws -> DASHVODTransferPlan {
        guard manifest.presentationType == .staticPresentation else {
            throw DASHVODTransferPlanError.dynamicMPD
        }
        guard manifest.periods.count == 1 else {
            throw manifest.periods.isEmpty
                ? DASHVODTransferPlanError.noSupportedRepresentation
                : DASHVODTransferPlanError.multiplePeriodsUnsupported
        }
        guard let period = manifest.periods.first else {
            throw DASHVODTransferPlanError.noSupportedRepresentation
        }

        let manifestURL = try validatedURL(manifest.url, against: manifest.url, limits: limits)
        let manifestBaseURL = try validatedURL(
            manifest.baseURL ?? manifestURL,
            against: manifestURL,
            limits: limits
        )
        let periodDuration = try finitePeriodDuration(
            period: period,
            fallback: manifest.mediaPresentationDuration,
            limits: limits
        )
        let videoSelection = try select(
            mediaType: .video,
            requestedID: videoRepresentationID,
            from: period.adaptationSets
        )
        let audioSelection = try select(
            mediaType: .audio,
            requestedID: audioRepresentationID,
            from: period.adaptationSets
        )

        guard videoSelection != nil || audioSelection != nil else {
            throw DASHVODTransferPlanError.noSupportedRepresentation
        }

        var totalSegments = 0
        let videoPlan = try videoSelection.map {
            try buildRepresentationPlan(
                mediaType: .video,
                adaptationSet: $0.adaptationSet,
                representation: $0.representation,
                period: period,
                manifestURL: manifestURL,
                fallbackBaseURL: manifestBaseURL,
                periodDuration: periodDuration,
                limits: limits,
                totalSegments: &totalSegments
            )
        }
        let audioPlan = try audioSelection.map {
            try buildRepresentationPlan(
                mediaType: .audio,
                adaptationSet: $0.adaptationSet,
                representation: $0.representation,
                period: period,
                manifestURL: manifestURL,
                fallbackBaseURL: manifestBaseURL,
                periodDuration: periodDuration,
                limits: limits,
                totalSegments: &totalSegments
            )
        }

        let allResources = (videoPlan?.resources ?? []) + (audioPlan?.resources ?? [])
        let estimatedBytes = calculateEstimatedBytes(for: allResources)

        return DASHVODTransferPlan(
            manifestURL: manifestURL,
            periodID: period.id,
            video: videoPlan,
            audio: audioPlan,
            browserRequestContext: browserRequestContext,
            estimatedTransferBytes: estimatedBytes
        )
    }

    private struct Selection {
        let adaptationSet: DASHAdaptationSet
        let representation: DASHRepresentation
    }

    private static func select(
        mediaType: DASHMediaType,
        requestedID: String?,
        from adaptationSets: [DASHAdaptationSet]
    ) throws -> Selection? {
        let candidates = adaptationSets.filter { adaptationSet in
            inferredMediaType(adaptationSet) == mediaType
        }
        guard !candidates.isEmpty else {
            if requestedID != nil { throw DASHVODTransferPlanError.representationNotFound }
            return nil
        }

        if let requestedID {
            for adaptationSet in candidates {
                if let representation = adaptationSet.representations.first(where: { $0.id == requestedID }) {
                    return Selection(adaptationSet: adaptationSet, representation: representation)
                }
            }
            throw DASHVODTransferPlanError.representationNotFound
        }

        guard let adaptationSet = candidates.first,
              let representation = adaptationSet.representations.first else {
            throw DASHVODTransferPlanError.noSupportedRepresentation
        }
        return Selection(adaptationSet: adaptationSet, representation: representation)
    }

    private static func inferredMediaType(_ adaptationSet: DASHAdaptationSet) -> DASHMediaType? {
        if let contentType = adaptationSet.contentType?.lowercased() {
            if contentType == "video" { return .video }
            if contentType == "audio" { return .audio }
        }
        if let mimeType = adaptationSet.mimeType?.lowercased() {
            if mimeType.hasPrefix("video/") { return .video }
            if mimeType.hasPrefix("audio/") { return .audio }
        }
        for representation in adaptationSet.representations {
            if let mimeType = representation.mimeType?.lowercased() {
                if mimeType.hasPrefix("video/") { return .video }
                if mimeType.hasPrefix("audio/") { return .audio }
            }
        }
        return nil
    }

    private static func buildRepresentationPlan(
        mediaType: DASHMediaType,
        adaptationSet: DASHAdaptationSet,
        representation: DASHRepresentation,
        period: DASHPeriod,
        manifestURL: URL,
        fallbackBaseURL: URL,
        periodDuration: Double,
        limits: DASHTransferPlanningLimits,
        totalSegments: inout Int
    ) throws -> DASHRepresentationTransferPlan {
        guard !adaptationSet.hasContentProtection, !representation.hasContentProtection else {
            throw DASHVODTransferPlanError.drmProtectedRepresentation
        }
        if let representationMIME = representation.mimeType?.lowercased() {
            let isCompatible = mediaType == .video
                ? representationMIME.hasPrefix("video/")
                : representationMIME.hasPrefix("audio/")
            guard isCompatible else {
                throw DASHVODTransferPlanError.incompatibleMediaTypes
            }
        }
        let baseURL = representation.baseURL ?? adaptationSet.baseURL ?? period.baseURL ?? fallbackBaseURL
        let resolvedBaseURL = try validatedURL(baseURL, against: manifestURL, limits: limits)
        guard !(representation.segmentTemplate != nil && representation.segmentList != nil) else {
            throw DASHVODTransferPlanError.unsupportedSegmentAddressing
        }

        let resources: [DASHPlannedResource]
        let estimatedDuration: Double?
        if let template = representation.segmentTemplate {
            let result = try buildTemplatePlan(
                mediaType: mediaType,
                representation: representation,
                template: template,
                baseURL: resolvedBaseURL,
                periodDuration: periodDuration,
                limits: limits,
                totalSegments: &totalSegments
            )
            resources = result.resources
            estimatedDuration = result.duration
        } else if let list = representation.segmentList {
            let result = try buildListPlan(
                mediaType: mediaType,
                representation: representation,
                list: list,
                baseURL: resolvedBaseURL,
                periodDuration: periodDuration,
                limits: limits,
                totalSegments: &totalSegments
            )
            resources = result.resources
            estimatedDuration = result.duration
        } else {
            throw DASHVODTransferPlanError.unsupportedSegmentAddressing
        }

        guard resources.contains(where: { $0.kind == .mediaSegment }) else {
            throw DASHVODTransferPlanError.noMediaSegments
        }
        let estimatedBytes = calculateEstimatedBytes(for: resources)

        return DASHRepresentationTransferPlan(
            mediaType: mediaType,
            adaptationSetID: adaptationSet.id,
            representationID: representation.id,
            bandwidth: representation.bandwidth,
            codecs: representation.codecs ?? adaptationSet.codecs,
            resources: resources,
            estimatedSegmentCount: resources.filter { $0.kind == .mediaSegment }.count,
            estimatedDurationSeconds: estimatedDuration,
            estimatedTransferBytes: estimatedBytes
        )
    }

    private struct BuiltResources {
        let resources: [DASHPlannedResource]
        let duration: Double?
    }

    private static func buildTemplatePlan(
        mediaType: DASHMediaType,
        representation: DASHRepresentation,
        template: DASHSegmentTemplate,
        baseURL: URL,
        periodDuration: Double,
        limits: DASHTransferPlanningLimits,
        totalSegments: inout Int
    ) throws -> BuiltResources {
        guard let initialization = template.initialization, !initialization.isEmpty,
              let media = template.media, !media.isEmpty else {
            throw DASHVODTransferPlanError.missingInitialization
        }

        let initializationURL = try expandURL(
            initialization,
            representation: representation,
            number: template.startNumber,
            time: template.presentationTimeOffset,
            baseURL: baseURL,
            limits: limits
        )
        var resources = [DASHPlannedResource(
            order: 0,
            mediaType: mediaType,
            kind: .initialization,
            url: initializationURL,
            timescale: template.timescale
        )]

        let entries = try timelineEntries(
            template: template,
            periodDuration: periodDuration,
            limits: limits,
            totalSegments: &totalSegments
        )
        guard !entries.isEmpty else { throw DASHVODTransferPlanError.noMediaSegments }

        var segmentDuration = 0.0
        var allDurationsKnown = true
        for (index, entry) in entries.enumerated() {
            let number = try adding(template.startNumber, Int64(index))
            let url = try expandURL(
                media,
                representation: representation,
                number: number,
                time: entry.time,
                baseURL: baseURL,
                limits: limits
            )
            resources.append(DASHPlannedResource(
                order: resources.count,
                mediaType: mediaType,
                kind: .mediaSegment,
                url: url,
                segmentNumber: number,
                segmentTime: entry.time,
                duration: entry.duration,
                timescale: template.timescale
            ))
            segmentDuration += Double(entry.duration) / Double(template.timescale)
        }
        if entries.contains(where: { $0.duration <= 0 }) { allDurationsKnown = false }
        if !allDurationsKnown || !segmentDuration.isFinite { segmentDuration = 0 }

        return BuiltResources(
            resources: resources,
            duration: segmentDuration > 0 ? segmentDuration : nil
        )
    }

    private struct TimelineEntry {
        let time: Int64
        let duration: Int64
    }

    private static func timelineEntries(
        template: DASHSegmentTemplate,
        periodDuration: Double,
        limits: DASHTransferPlanningLimits,
        totalSegments: inout Int
    ) throws -> [TimelineEntry] {
        if template.timeline.isEmpty {
            guard let duration = template.duration, duration > 0 else {
                throw DASHVODTransferPlanError.unboundedTimeline
            }
            let units = Double(template.timescale) * periodDuration
            guard units.isFinite, units > 0 else { throw DASHVODTransferPlanError.invalidPeriodDuration }
            let countDouble = ceil(units / Double(duration))
            guard countDouble <= Double(limits.maxSegmentsPerRepresentation),
                  countDouble <= Double(Int.max) else {
                throw DASHVODTransferPlanError.timelineExpansionLimitExceeded
            }
            let count = Int(countDouble)
            try reserveSegments(count, limits: limits, totalSegments: &totalSegments)
            return try (0..<count).map { index in
                let offset = try multiplying(duration, Int64(index))
                return TimelineEntry(
                    time: try adding(template.presentationTimeOffset, offset),
                    duration: duration
                )
            }
        }

        var entries: [TimelineEntry] = []
        var currentTime: Int64 = 0
        let periodUnits = try durationUnits(periodDuration, timescale: template.timescale)

        for (index, timeline) in template.timeline.enumerated() {
            guard timeline.duration > 0 else { throw DASHVODTransferPlanError.malformedTemplate }
            let start = timeline.start ?? currentTime
            guard start >= currentTime || index == 0 else {
                throw DASHVODTransferPlanError.malformedTemplate
            }
            let repeatCount: Int
            if timeline.repeatCount >= 0 {
                guard timeline.repeatCount < limits.maxSegmentsPerRepresentation else {
                    throw DASHVODTransferPlanError.timelineExpansionLimitExceeded
                }
                repeatCount = timeline.repeatCount
            } else if timeline.repeatCount == -1 {
                let bound: Int64
                if let nextStart = template.timeline.dropFirst(index + 1).first?.start {
                    bound = nextStart
                } else {
                    bound = try adding(template.presentationTimeOffset, periodUnits)
                }
                guard bound > start else { throw DASHVODTransferPlanError.unboundedTimeline }
                let span = bound - start
                guard span % timeline.duration == 0 else {
                    throw DASHVODTransferPlanError.malformedTemplate
                }
                let count = span / timeline.duration
                guard count > 0, count <= Int64(limits.maxSegmentsPerRepresentation) else {
                    throw DASHVODTransferPlanError.timelineExpansionLimitExceeded
                }
                repeatCount = Int(count - 1)
            } else {
                throw DASHVODTransferPlanError.malformedTemplate
            }

            let count = repeatCount + 1
            try reserveSegments(count, limits: limits, totalSegments: &totalSegments)
            for repetition in 0..<count {
                let offset = try multiplying(timeline.duration, Int64(repetition))
                entries.append(TimelineEntry(time: try adding(start, offset), duration: timeline.duration))
            }
            let totalOffset = try multiplying(timeline.duration, Int64(count))
            currentTime = try adding(start, totalOffset)
        }
        return entries
    }

    private static func buildListPlan(
        mediaType: DASHMediaType,
        representation: DASHRepresentation,
        list: DASHSegmentList,
        baseURL: URL,
        periodDuration: Double,
        limits: DASHTransferPlanningLimits,
        totalSegments: inout Int
    ) throws -> BuiltResources {
        guard let initialization = list.initialization,
              let initializationURL = initialization.sourceURL else {
            throw DASHVODTransferPlanError.missingInitialization
        }
        guard list.segmentURLs.count <= limits.maxSegmentsPerRepresentation else {
            throw DASHVODTransferPlanError.timelineExpansionLimitExceeded
        }
        guard !list.segmentURLs.isEmpty else { throw DASHVODTransferPlanError.noMediaSegments }
        try reserveSegments(list.segmentURLs.count, limits: limits, totalSegments: &totalSegments)

        let initURL = try validatedURL(initializationURL, against: baseURL, limits: limits)
        var resources = [DASHPlannedResource(
            order: 0,
            mediaType: mediaType,
            kind: .initialization,
            url: initURL,
            byteRange: try parseRange(initialization.range),
            timescale: list.timescale
        )]
        var durationSeconds = 0.0
        for (index, segment) in list.segmentURLs.enumerated() {
            guard segment.indexURL == nil, let mediaURL = segment.mediaURL else {
                throw DASHVODTransferPlanError.unsupportedSegmentAddressing
            }
            let url = try validatedURL(mediaURL, against: baseURL, limits: limits)
            let number = try adding(list.startNumber, Int64(index))
            resources.append(DASHPlannedResource(
                order: resources.count,
                mediaType: mediaType,
                kind: .mediaSegment,
                url: url,
                byteRange: try parseRange(segment.mediaRange),
                segmentNumber: number,
                duration: list.duration,
                timescale: list.timescale
            ))
            if let duration = list.duration {
                durationSeconds += Double(duration) / Double(list.timescale)
            }
        }
        let estimatedDuration = list.duration == nil ? nil : durationSeconds
        if let estimatedDuration, estimatedDuration > periodDuration + 0.001 {
            throw DASHVODTransferPlanError.malformedTemplate
        }
        return BuiltResources(resources: resources, duration: estimatedDuration)
    }

    private static func finitePeriodDuration(
        period: DASHPeriod,
        fallback: Double?,
        limits: DASHTransferPlanningLimits
    ) throws -> Double {
        guard let duration = period.duration ?? fallback,
              duration.isFinite, duration > 0 else {
            throw DASHVODTransferPlanError.invalidPeriodDuration
        }
        guard duration <= limits.maxPeriodDuration else {
            throw DASHVODTransferPlanError.periodDurationLimitExceeded
        }
        return duration
    }

    private static func durationUnits(_ duration: Double, timescale: Int64) throws -> Int64 {
        let value = duration * Double(timescale)
        guard value.isFinite, value >= 0, value <= Double(Int64.max), value.rounded() == value else {
            throw DASHVODTransferPlanError.invalidPeriodDuration
        }
        return Int64(value)
    }

    private static func reserveSegments(
        _ count: Int,
        limits: DASHTransferPlanningLimits,
        totalSegments: inout Int
    ) throws {
        guard count >= 0,
              count <= limits.maxSegmentsPerRepresentation,
              totalSegments <= limits.maxTotalSegments - count else {
            throw DASHVODTransferPlanError.timelineExpansionLimitExceeded
        }
        totalSegments += count
    }

    private static func expandURL(
        _ template: String,
        representation: DASHRepresentation,
        number: Int64,
        time: Int64,
        baseURL: URL,
        limits: DASHTransferPlanningLimits
    ) throws -> URL {
        let characters = Array(template)
        var output = ""
        var index = 0
        while index < characters.count {
            guard characters[index] == "$" else {
                output.append(characters[index])
                index += 1
                continue
            }
            if index + 1 < characters.count, characters[index + 1] == "$" {
                output.append("$")
                index += 2
                continue
            }
            guard let end = characters[(index + 1)...].firstIndex(of: "$"), end > index + 1 else {
                throw DASHVODTransferPlanError.malformedTemplate
            }
            let token = String(characters[(index + 1)..<end])
            output += try substitute(token, representation: representation, number: number, time: time)
            guard output.utf8.count <= limits.maxExpandedURLLength else {
                throw DASHVODTransferPlanError.timelineExpansionLimitExceeded
            }
            index = end + 1
        }
        guard let rawURL = URL(string: output, relativeTo: baseURL)?.absoluteURL else {
            throw DASHVODTransferPlanError.invalidResourceURL
        }
        return try validatedURL(rawURL, against: baseURL, limits: limits)
    }

    private static func substitute(
        _ token: String,
        representation: DASHRepresentation,
        number: Int64,
        time: Int64
    ) throws -> String {
        let pieces = token.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(pieces[0])
        let value: String
        switch name {
        case "RepresentationID":
            guard let id = representation.id, !id.isEmpty else { throw DASHVODTransferPlanError.malformedTemplate }
            value = id
        case "Bandwidth":
            guard let bandwidth = representation.bandwidth else { throw DASHVODTransferPlanError.malformedTemplate }
            value = String(bandwidth)
        case "Number":
            value = String(number)
        case "Time":
            value = String(time)
        default:
            throw DASHVODTransferPlanError.malformedTemplate
        }
        guard pieces.count == 1 || pieces[1].hasSuffix("d") else {
            throw DASHVODTransferPlanError.malformedTemplate
        }
        guard pieces.count == 2 else { return value }
        let format = String(pieces[1].dropLast())
        guard format.hasPrefix("0"), let width = Int(format), width >= 1, width <= 32 else {
            throw DASHVODTransferPlanError.malformedTemplate
        }
        return String(repeating: "0", count: max(0, width - value.count)) + value
    }

    private static func parseRange(_ value: String?) throws -> DASHByteRange? {
        guard let value else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = Int64(parts[0]),
              let end = Int64(parts[1]),
              start >= 0,
              end >= start,
              end < Int64.max else {
            throw DASHVODTransferPlanError.invalidByteRange
        }
        return DASHByteRange(start: start, end: end)
    }

    private static func calculateEstimatedBytes(for resources: [DASHPlannedResource]) -> Int64? {
        guard resources.allSatisfy({ $0.byteRange != nil }) else { return nil }
        var total: Int64 = 0
        for resource in resources {
            guard let length = resource.byteRange?.length else { return nil }
            let result = total.addingReportingOverflow(length)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    private static func validatedURL(
        _ rawURL: URL,
        against baseURL: URL,
        limits: DASHTransferPlanningLimits
    ) throws -> URL {
        guard let resolved = URL(string: rawURL.absoluteString, relativeTo: baseURL)?.absoluteURL,
              resolved.absoluteString.utf8.count <= limits.maxExpandedURLLength,
              let components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            throw DASHVODTransferPlanError.invalidResourceURL
        }
        return resolved
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else { throw DASHVODTransferPlanError.timelineExpansionLimitExceeded }
        return result.partialValue
    }

    private static func multiplying(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw DASHVODTransferPlanError.timelineExpansionLimitExceeded }
        return result.partialValue
    }
}
