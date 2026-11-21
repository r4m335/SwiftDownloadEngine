import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses a bounded DASH MPD document without resolving or fetching external data.
public typealias MPDManifestParser = DASHManifestParser

public enum DASHManifestParser {

    public static func parse(
        _ data: Data,
        baseURL: URL,
        limits: ManifestParsingLimits = .default
    ) throws -> DASHManifest {
        guard data.count <= limits.maxBytes else {
            throw ManifestParserError.inputTooLarge(limit: limits.maxBytes)
        }
        guard isHTTPURL(baseURL) else {
            throw ManifestParserError.invalidURL
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ManifestParserError.malformed(reason: "MPD is not valid UTF-8.")
        }
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "\u{FEFF}" })
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<html") || lower.hasPrefix("<!doctype html") || (lower.hasPrefix("<!doctype") && lower.contains("html")) {
            let snippet = String(text.prefix(500))
            PipelineLogger.shared.log("[DASH Pipeline] Server returned HTML block page instead of manifest. Snippet: \(snippet)")
            throw ManifestParserError.malformed(reason: "Server blocked request. Returned HTML instead of manifest.")
        }
        if text.range(of: "<!DOCTYPE", options: [.caseInsensitive]) != nil ||
            text.range(of: "<!ENTITY", options: [.caseInsensitive]) != nil {
            throw ManifestParserError.unsupported(reason: "DOCTYPE and entity declarations are not accepted.")
        }

        let treeBuilder = DASHXMLTreeBuilder(data: data, limits: limits)
        guard treeBuilder.parse() else {
            throw treeBuilder.failure ?? ManifestParserError.malformed(reason: "XML parser rejected the MPD.")
        }
        guard let root = treeBuilder.root, root.localName == "MPD" else {
            throw ManifestParserError.malformed(reason: "Document root must be MPD.")
        }
        return try parseManifest(root, baseURL: baseURL)
    }

    public static func parse(
        _ text: String,
        baseURL: URL,
        limits: ManifestParsingLimits = .default
    ) throws -> DASHManifest {
        try parse(Data(text.utf8), baseURL: baseURL, limits: limits)
    }

    private static func parseManifest(_ node: DASHXMLNode, baseURL: URL) throws -> DASHManifest {
        let presentationType: DASHPresentationType
        switch node.attribute("type")?.lowercased() {
        case nil, "static": presentationType = .staticPresentation
        case "dynamic": presentationType = .dynamicPresentation
        default:
            throw ManifestParserError.unsupported(reason: "MPD type is not static or dynamic.")
        }

        let resolvedBase = try resolveBaseURL(node.child(named: "BaseURL")?.text, against: baseURL)
        let manifestBase = resolvedBase ?? baseURL
        let mpdTemplate = try parseSegmentTemplate(node.child(named: "SegmentTemplate"), baseURL: manifestBase)
        let mpdList = try parseSegmentList(node.child(named: "SegmentList"), baseURL: manifestBase)
        let mpdBase = try parseSegmentBase(node.child(named: "SegmentBase"), baseURL: manifestBase)

        let periodNodes = node.children(named: "Period")
        guard !periodNodes.isEmpty else {
            throw ManifestParserError.malformed(reason: "MPD must contain at least one Period.")
        }

        let periods = try periodNodes.map {
            try parsePeriod(
                $0,
                baseURL: manifestBase,
                inheritedTemplate: mpdTemplate,
                inheritedList: mpdList,
                inheritedBase: mpdBase
            )
        }

        return DASHManifest(
            url: baseURL,
            presentationType: presentationType,
            profiles: node.attribute("profiles"),
            mediaPresentationDuration: try parseOptionalDuration(node.attribute("mediaPresentationDuration"), name: "mediaPresentationDuration"),
            minBufferTime: try parseOptionalDuration(node.attribute("minBufferTime"), name: "minBufferTime"),
            baseURL: resolvedBase,
            periods: periods
        )
    }

    private static func parsePeriod(
        _ node: DASHXMLNode,
        baseURL: URL,
        inheritedTemplate: DASHSegmentTemplate? = nil,
        inheritedList: DASHSegmentList? = nil,
        inheritedBase: DASHSegmentBase? = nil
    ) throws -> DASHPeriod {
        let resolvedBase = try resolveBaseURL(node.child(named: "BaseURL")?.text, against: baseURL) ?? baseURL
        let ownTemplate = try parseSegmentTemplate(node.child(named: "SegmentTemplate"), baseURL: resolvedBase)
        let ownList = try parseSegmentList(node.child(named: "SegmentList"), baseURL: resolvedBase)
        let ownBase = try parseSegmentBase(node.child(named: "SegmentBase"), baseURL: resolvedBase)

        let periodTemplate = ownTemplate ?? inheritedTemplate
        let periodList = ownList ?? inheritedList
        let periodBase = ownBase ?? inheritedBase

        let adaptationNodes = node.children(named: "AdaptationSet")
        guard !adaptationNodes.isEmpty else {
            throw ManifestParserError.malformed(reason: "Period contains no AdaptationSet elements.")
        }
        let adaptations = try adaptationNodes.map {
            try parseAdaptationSet(
                $0,
                baseURL: resolvedBase,
                inheritedTemplate: periodTemplate,
                inheritedList: periodList,
                inheritedBase: periodBase
            )
        }
        return DASHPeriod(
            id: node.attribute("id"),
            start: try parseOptionalDuration(node.attribute("start"), name: "Period@start"),
            duration: try parseOptionalDuration(node.attribute("duration"), name: "Period@duration"),
            baseURL: resolvedBase,
            adaptationSets: adaptations
        )
    }

    private static func parseAdaptationSet(
        _ node: DASHXMLNode,
        baseURL: URL,
        inheritedTemplate: DASHSegmentTemplate? = nil,
        inheritedList: DASHSegmentList? = nil,
        inheritedBase: DASHSegmentBase? = nil
    ) throws -> DASHAdaptationSet {
        let resolvedBase = try resolveBaseURL(node.child(named: "BaseURL")?.text, against: baseURL) ?? baseURL
        let ownTemplate = try parseSegmentTemplate(node.child(named: "SegmentTemplate"), baseURL: resolvedBase)
        let ownList = try parseSegmentList(node.child(named: "SegmentList"), baseURL: resolvedBase)
        let ownBase = try parseSegmentBase(node.child(named: "SegmentBase"), baseURL: resolvedBase)

        let adaptationTemplate = ownTemplate ?? inheritedTemplate
        let adaptationList = ownList ?? inheritedList
        let adaptationBase = ownBase ?? inheritedBase

        let contentType = node.attribute("contentType")
        let mimeType = node.attribute("mimeType")
        let codecs = node.attribute("codecs")
        let language = node.attribute("lang") ?? node.attribute("xml:lang") ?? node.attribute("language")

        let protectionNodes = node.children(named: "ContentProtection")
        let hasProtection = !protectionNodes.isEmpty
        let contentProtections = protectionNodes.map { parseContentProtection($0) }

        let representationNodes = node.children(named: "Representation")
        guard !representationNodes.isEmpty else {
            throw ManifestParserError.malformed(reason: "AdaptationSet contains no Representation elements.")
        }
        let representations = try representationNodes.map {
            try parseRepresentation(
                $0,
                baseURL: resolvedBase,
                inheritedTemplate: adaptationTemplate,
                inheritedList: adaptationList,
                inheritedBase: adaptationBase,
                inheritedMimeType: mimeType,
                inheritedCodecs: codecs,
                inheritedContentProtection: hasProtection,
                inheritedProtections: contentProtections
            )
        }
        return DASHAdaptationSet(
            id: node.attribute("id"),
            contentType: contentType,
            mimeType: mimeType,
            codecs: codecs,
            language: language,
            hasContentProtection: hasProtection,
            contentProtections: contentProtections,
            baseURL: resolvedBase,
            segmentTemplate: adaptationTemplate,
            segmentList: adaptationList,
            segmentBase: adaptationBase,
            representations: representations
        )
    }

    private static func parseRepresentation(
        _ node: DASHXMLNode,
        baseURL: URL,
        inheritedTemplate: DASHSegmentTemplate?,
        inheritedList: DASHSegmentList?,
        inheritedBase: DASHSegmentBase?,
        inheritedMimeType: String?,
        inheritedCodecs: String?,
        inheritedContentProtection: Bool,
        inheritedProtections: [DASHContentProtection]
    ) throws -> DASHRepresentation {
        let resolvedBase = try resolveBaseURL(node.child(named: "BaseURL")?.text, against: baseURL) ?? baseURL
        let ownTemplate = try parseSegmentTemplate(node.child(named: "SegmentTemplate"), baseURL: resolvedBase)
        let ownList = try parseSegmentList(node.child(named: "SegmentList"), baseURL: resolvedBase)
        let ownBase = try parseSegmentBase(node.child(named: "SegmentBase"), baseURL: resolvedBase)

        let ownProtectionNodes = node.children(named: "ContentProtection")
        let ownHasProtection = !ownProtectionNodes.isEmpty
        let ownProtections = ownProtectionNodes.map { parseContentProtection($0) }

        let hasProtection = ownHasProtection || inheritedContentProtection
        let protections = ownProtections.isEmpty ? inheritedProtections : ownProtections

        return DASHRepresentation(
            id: node.attribute("id"),
            bandwidth: try parseOptionalNonNegativeInt64(node.attribute("bandwidth"), name: "Representation@bandwidth"),
            width: try parseOptionalPositiveInt(node.attribute("width"), name: "Representation@width"),
            height: try parseOptionalPositiveInt(node.attribute("height"), name: "Representation@height"),
            mimeType: node.attribute("mimeType") ?? inheritedMimeType,
            codecs: node.attribute("codecs") ?? inheritedCodecs,
            hasContentProtection: hasProtection,
            contentProtections: protections,
            baseURL: resolvedBase,
            segmentTemplate: ownTemplate ?? inheritedTemplate,
            segmentList: ownList ?? inheritedList,
            segmentBase: ownBase ?? inheritedBase
        )
    }

    private static func parseSegmentBase(_ node: DASHXMLNode?, baseURL: URL) throws -> DASHSegmentBase? {
        guard let node else { return nil }
        let initialization: DASHInitialization?
        if let initNode = node.child(named: "Initialization") {
            initialization = DASHInitialization(
                sourceURL: try optionalURL(initNode.attribute("sourceURL"), against: baseURL),
                range: initNode.attribute("range")
            )
        } else {
            initialization = nil
        }
        let timescale = try parsePositiveInt64(node.attribute("timescale"), defaultValue: 1, name: "SegmentBase@timescale")
        let presentationTimeOffset = try parseNonNegativeInt64(node.attribute("presentationTimeOffset"), defaultValue: 0, name: "SegmentBase@presentationTimeOffset")
        let indexRange = node.attribute("indexRange")
        let indexRangeExact = node.attribute("indexRangeExact")?.lowercased() == "true"
        let availabilityTimeOffset = Double(node.attribute("availabilityTimeOffset") ?? "")
        let mediaRange = node.attribute("mediaRange")

        guard initialization != nil || indexRange != nil || mediaRange != nil else {
            throw ManifestParserError.malformed(reason: "SegmentBase contains no initialization, indexRange, or mediaRange.")
        }

        return DASHSegmentBase(
            timescale: timescale,
            presentationTimeOffset: presentationTimeOffset,
            indexRange: indexRange,
            indexRangeExact: indexRangeExact,
            availabilityTimeOffset: availabilityTimeOffset,
            initialization: initialization,
            mediaRange: mediaRange
        )
    }

    private static func parseContentProtection(_ node: DASHXMLNode) -> DASHContentProtection {
        DASHContentProtection(
            schemeIdUri: node.attribute("schemeIdUri") ?? node.attribute("schemeIdURI") ?? node.attribute("schemeiduri"),
            value: node.attribute("value"),
            defaultKID: node.attribute("cenc:default_KID") ?? node.attribute("default_KID") ?? node.attribute("default_kid")
        )
    }

    private static func parseSegmentTemplate(_ node: DASHXMLNode?, baseURL: URL) throws -> DASHSegmentTemplate? {
        guard let node else { return nil }
        let timeline = try parseTimeline(node.child(named: "SegmentTimeline"))
        return DASHSegmentTemplate(
            media: node.attribute("media"),
            initialization: node.attribute("initialization"),
            timescale: try parsePositiveInt64(node.attribute("timescale"), defaultValue: 1, name: "SegmentTemplate@timescale"),
            presentationTimeOffset: try parseNonNegativeInt64(node.attribute("presentationTimeOffset"), defaultValue: 0, name: "SegmentTemplate@presentationTimeOffset"),
            startNumber: try parsePositiveInt64(node.attribute("startNumber"), defaultValue: 1, name: "SegmentTemplate@startNumber"),
            duration: try parseOptionalPositiveInt64(node.attribute("duration"), name: "SegmentTemplate@duration"),
            timeline: timeline
        )
    }

    private static func parseTimeline(_ node: DASHXMLNode?) throws -> [DASHSegmentTimelineEntry] {
        guard let node else { return [] }
        return try node.children(named: "S").map { item in
            guard let duration = try parseOptionalPositiveInt64(item.attribute("d"), name: "SegmentTimeline.S@d") else {
                throw ManifestParserError.malformed(reason: "SegmentTimeline.S requires a positive d attribute.")
            }
            let repeatCount = try parseNonNegativeInt(item.attribute("r"), defaultValue: 0, name: "SegmentTimeline.S@r", allowNegativeOne: true)
            return DASHSegmentTimelineEntry(
                start: try parseOptionalNonNegativeInt64(item.attribute("t"), name: "SegmentTimeline.S@t"),
                duration: duration,
                repeatCount: repeatCount
            )
        }
    }

    private static func parseSegmentList(_ node: DASHXMLNode?, baseURL: URL) throws -> DASHSegmentList? {
        guard let node else { return nil }
        let initialization: DASHInitialization?
        if let initNode = node.child(named: "Initialization") {
            initialization = DASHInitialization(
                sourceURL: try optionalURL(initNode.attribute("sourceURL"), against: baseURL),
                range: initNode.attribute("range")
            )
        } else {
            initialization = nil
        }
        let segmentURLs = try node.children(named: "SegmentURL").map { item in
            guard item.attribute("media") != nil || item.attribute("index") != nil else {
                throw ManifestParserError.malformed(reason: "SegmentURL requires media or index.")
            }
            return DASHSegmentURL(
                mediaURL: try optionalURL(item.attribute("media"), against: baseURL),
                mediaRange: item.attribute("mediaRange"),
                indexURL: try optionalURL(item.attribute("index"), against: baseURL),
                indexRange: item.attribute("indexRange")
            )
        }
        guard initialization != nil || !segmentURLs.isEmpty else {
            throw ManifestParserError.malformed(reason: "SegmentList contains no initialization or segment URLs.")
        }
        return DASHSegmentList(
            timescale: try parsePositiveInt64(node.attribute("timescale"), defaultValue: 1, name: "SegmentList@timescale"),
            duration: try parseOptionalPositiveInt64(node.attribute("duration"), name: "SegmentList@duration"),
            startNumber: try parsePositiveInt64(node.attribute("startNumber"), defaultValue: 1, name: "SegmentList@startNumber"),
            initialization: initialization,
            segmentURLs: segmentURLs
        )
    }

    private static func resolveBaseURL(_ value: String?, against baseURL: URL) throws -> URL? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try optionalURL(value.trimmingCharacters(in: .whitespacesAndNewlines), against: baseURL)
    }

    private static func optionalURL(_ value: String?, against baseURL: URL) throws -> URL? {
        guard let value else { return nil }
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL, isHTTPURL(url) else {
            throw ManifestParserError.invalidURL
        }
        return url
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    private static func parseOptionalDuration(_ value: String?, name: String) throws -> Double? {
        guard let value else { return nil }
        guard let duration = parseDuration(value), duration.isFinite, duration >= 0 else {
            throw ManifestParserError.malformed(reason: "\(name) contains an invalid duration.")
        }
        return duration
    }

    private static func parseDuration(_ value: String) -> Double? {
        guard value.hasPrefix("PT") else { return nil }
        let body = value.dropFirst(2)
        var number = ""
        var total = 0.0
        var found = false
        for character in body {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            guard let parsed = Double(number) else { return nil }
            switch character {
            case "H": total += parsed * 3600
            case "M": total += parsed * 60
            case "S": total += parsed
            default: return nil
            }
            number = ""
            found = true
        }
        return found && number.isEmpty ? total : nil
    }

    private static func parsePositiveInt64(_ value: String?, defaultValue: Int64, name: String) throws -> Int64 {
        guard let value else { return defaultValue }
        guard let parsed = Int64(value), parsed > 0 else {
            throw ManifestParserError.malformed(reason: "\(name) must be positive.")
        }
        return parsed
    }

    private static func parseNonNegativeInt64(_ value: String?, defaultValue: Int64, name: String) throws -> Int64 {
        guard let value else { return defaultValue }
        guard let parsed = Int64(value), parsed >= 0 else {
            throw ManifestParserError.malformed(reason: "\(name) must be non-negative.")
        }
        return parsed
    }

    private static func parseOptionalPositiveInt64(_ value: String?, name: String) throws -> Int64? {
        guard let value else { return nil }
        guard let parsed = Int64(value), parsed > 0 else {
            throw ManifestParserError.malformed(reason: "\(name) must be positive.")
        }
        return parsed
    }

    private static func parseOptionalNonNegativeInt64(_ value: String?, name: String) throws -> Int64? {
        guard let value else { return nil }
        guard let parsed = Int64(value), parsed >= 0 else {
            throw ManifestParserError.malformed(reason: "\(name) must be non-negative.")
        }
        return parsed
    }

    private static func parseOptionalPositiveInt(_ value: String?, name: String) throws -> Int? {
        guard let value else { return nil }
        guard let parsed = Int(value), parsed > 0 else {
            throw ManifestParserError.malformed(reason: "\(name) must be positive.")
        }
        return parsed
    }

    private static func parseNonNegativeInt(
        _ value: String?,
        defaultValue: Int,
        name: String,
        allowNegativeOne: Bool = false
    ) throws -> Int {
        guard let value else { return defaultValue }
        guard let parsed = Int(value), parsed >= 0 || (allowNegativeOne && parsed == -1) else {
            throw ManifestParserError.malformed(reason: "\(name) must be non-negative.")
        }
        return parsed
    }
}

private final class DASHXMLNode {
    let localName: String
    let attributes: [String: String]
    var text = ""
    var children: [DASHXMLNode] = []

    init(localName: String, attributes: [String: String]) {
        self.localName = localName
        self.attributes = attributes
    }

    func attribute(_ name: String) -> String? {
        attributes[name] ?? attributes[name.lowercased()] ?? attributes[name.uppercased()]
    }

    func child(named name: String) -> DASHXMLNode? {
        children.first { $0.localName == name }
    }

    func children(named name: String) -> [DASHXMLNode] {
        children.filter { $0.localName == name }
    }
}

private final class DASHXMLTreeBuilder: NSObject, XMLParserDelegate {
    private let data: Data
    private let limits: ManifestParsingLimits
    private let deadline: Date
    private var stack: [DASHXMLNode] = []
    private(set) var root: DASHXMLNode?
    private(set) var failure: ManifestParserError?
    private var elementCount = 0

    init(data: Data, limits: ManifestParsingLimits) {
        self.data = data
        self.limits = limits
        self.deadline = Date().addingTimeInterval(limits.maxParsingDuration)
    }

    func parse() -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        let success = parser.parse()
        return success && failure == nil && stack.isEmpty
    }

    func parserDidStartDocument(_ parser: XMLParser) {
        if Date() > deadline { fail(.parsingTimedOut, parser: parser) }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard failure == nil else { return }
        guard Date() <= deadline else { fail(.parsingTimedOut, parser: parser); return }
        elementCount += 1
        guard elementCount <= limits.maxElements else {
            fail(.elementLimitExceeded(limit: limits.maxElements), parser: parser)
            return
        }
        guard stack.count < limits.maxNestingDepth else {
            fail(.nestingLimitExceeded(limit: limits.maxNestingDepth), parser: parser)
            return
        }

        let localName = Self.localName(qName ?? elementName)
        let attributes = attributeDict.reduce(into: [String: String]()) { result, item in
            result[Self.localName(item.key)] = item.value
        }
        let node = DASHXMLNode(localName: localName, attributes: attributes)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard failure == nil, let current = stack.last else { return }
        current.text.append(string)
        guard Date() <= deadline else { fail(.parsingTimedOut, parser: parser); return }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard failure == nil else { return }
        guard !stack.isEmpty else {
            fail(.malformed(reason: "XML element nesting is invalid."), parser: parser)
            return
        }
        _ = stack.removeLast()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil {
            failure = .malformed(reason: parseError.localizedDescription)
        }
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        fail(.unsupported(reason: "External XML entities are not accepted."), parser: parser)
        return nil
    }

    private func fail(_ error: ManifestParserError, parser: XMLParser) {
        failure = error
        parser.abortParsing()
    }

    private static func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}
