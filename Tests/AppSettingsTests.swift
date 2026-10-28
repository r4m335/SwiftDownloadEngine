import XCTest
@testable import DM_Reverse_engineering

final class AppSettingsTests: XCTestCase {

    func testAppSettings_DefaultValues() {
        let settings = AppSettings.default
        XCTAssertEqual(settings.version, AppSettings.currentVersion)
        XCTAssertEqual(settings.maxConcurrentDownloads, 3)
        XCTAssertEqual(settings.maxGlobalRequests, 12)
        XCTAssertEqual(settings.timeoutSeconds, 30)
        XCTAssertNil(settings.customUserAgent)
        XCTAssertEqual(settings.maxRetryAttempts, 3)
        XCTAssertEqual(settings.duplicateNamingRule, .autoRename)
        XCTAssertTrue(settings.allowCellular)
        XCTAssertFalse(settings.enableGlobalSpeedLimit)
        XCTAssertEqual(settings.globalSpeedLimitKBps, 2048)
        XCTAssertEqual(settings.maxConcurrentTorrents, 3)
        XCTAssertEqual(settings.defaultTorrentPriority, .normal)
        XCTAssertEqual(settings.seedingMode, .ratio)
        XCTAssertEqual(settings.targetRatio, 1.0)
        XCTAssertEqual(settings.targetDurationMinutes, 60)
    }

    func testAppSettings_JSONRoundTrip() throws {
        var original = AppSettings.default
        original.maxConcurrentDownloads = 5
        original.maxGlobalRequests = 20
        original.timeoutSeconds = 45
        original.customUserAgent = "MyCustomDownloader/2.0"
        original.maxRetryAttempts = 5
        original.duplicateNamingRule = .overwrite
        original.allowCellular = false
        original.enableGlobalSpeedLimit = true
        original.globalSpeedLimitKBps = 4096
        original.maxConcurrentTorrents = 4
        original.defaultTorrentPriority = .high
        original.seedingMode = .duration
        original.targetDurationMinutes = 120

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.customUserAgent, "MyCustomDownloader/2.0")
        XCTAssertEqual(decoded.duplicateNamingRule, .overwrite)
        XCTAssertFalse(decoded.allowCellular)
        XCTAssertEqual(decoded.globalSpeedLimitKBps, 4096)
    }

    func testAppSettings_MappingToEngineConfiguration() {
        var settings = AppSettings.default
        settings.maxConcurrentDownloads = 4
        settings.maxGlobalRequests = 16
        settings.timeoutSeconds = 25
        settings.customUserAgent = "Safari/Test"
        settings.maxRetryAttempts = 2
        settings.duplicateNamingRule = .skip
        settings.allowCellular = false
        settings.enableGlobalSpeedLimit = true
        settings.globalSpeedLimitKBps = 1024
        settings.maxConcurrentTorrents = 2
        settings.defaultTorrentPriority = .low
        settings.seedingMode = .doNotSeed

        let engineConfig = settings.makeEngineConfiguration()

        XCTAssertEqual(engineConfig.maxConcurrentDownloads, 4)
        XCTAssertEqual(engineConfig.maxGlobalRequests, 16)
        XCTAssertEqual(engineConfig.requestTimeoutSeconds, 25.0)
        XCTAssertEqual(engineConfig.resourceTimeoutSeconds, 250.0)
        XCTAssertEqual(engineConfig.userAgent, "Safari/Test")
        XCTAssertEqual(engineConfig.maxRetryAttempts, 2)
        XCTAssertEqual(engineConfig.duplicateNamingRule, .skip)
        XCTAssertFalse(engineConfig.allowCellular)
        XCTAssertEqual(engineConfig.globalBandwidthLimitBytesPerSecond, 1024 * 1024)
        XCTAssertEqual(engineConfig.maxConcurrentTorrents, 2)
        XCTAssertEqual(engineConfig.defaultTorrentPriority, .low)
        XCTAssertEqual(engineConfig.defaultSeedingPreference.mode, .doNotSeed)
    }

    func testAppSettings_MappingDefaultsWhenCustomUANil() {
        var settings = AppSettings.default
        settings.customUserAgent = nil
        let config = settings.makeEngineConfiguration()
        XCTAssertEqual(config.userAgent, "SwiftDownloadEngine/1.0 (iOS; iPadOS)")

        settings.customUserAgent = "   "
        let config2 = settings.makeEngineConfiguration()
        XCTAssertEqual(config2.userAgent, "SwiftDownloadEngine/1.0 (iOS; iPadOS)")
    }

    func testAppSettings_VersionMigration() throws {
        let legacyDefaults = UserDefaults(suiteName: "test_migration_\(UUID().uuidString)")!
        defer { legacyDefaults.removePersistentDomain(forName: legacyDefaults.description) }

        // Simulate an older schema version (version 0)
        let legacyJSON = """
        {
            "version": 0,
            "maxConcurrentDownloads": 2,
            "maxGlobalRequests": 8,
            "timeoutSeconds": 20,
            "maxRetryAttempts": 1,
            "duplicateNamingRule": "Auto-rename with index",
            "allowCellular": true,
            "enableGlobalSpeedLimit": false,
            "globalSpeedLimitKBps": 2048,
            "maxConcurrentTorrents": 2,
            "defaultTorrentPriority": 2,
            "seedingMode": "Stop upon Completion",
            "targetRatio": 1.0,
            "targetDurationMinutes": 60
        }
        """.data(using: .utf8)!

        legacyDefaults.set(legacyJSON, forKey: AppSettings.userDefaultsKey)

        let loaded = AppSettings.load(from: legacyDefaults)
        XCTAssertEqual(loaded.version, AppSettings.currentVersion, "Should migrate to currentVersion")
        XCTAssertEqual(loaded.maxConcurrentDownloads, 2)
        XCTAssertEqual(loaded.maxGlobalRequests, 8)
    }

    func testDownloadEngine_DecoupledConfigurationInit() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("AppSettingsTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let customConfig = EngineConfiguration(
            maxConcurrentDownloads: 5,
            maxGlobalRequests: 24,
            requestTimeoutSeconds: 40.0,
            resourceTimeoutSeconds: 400.0,
            userAgent: "TestAgent/1.0",
            maxRetryAttempts: 4,
            globalBandwidthLimitBytesPerSecond: 500_000,
            duplicateNamingRule: .overwrite,
            allowCellular: true,
            maxConcurrentTorrents: 4,
            defaultTorrentPriority: .high
        )

        let engine = try DownloadEngine(
            configuration: customConfig,
            storageDirectoryURL: tempDir
        )

        let activeConfig = await engine.configuration
        XCTAssertEqual(activeConfig.maxConcurrentDownloads, 5)
        XCTAssertEqual(activeConfig.maxGlobalRequests, 24)
        XCTAssertEqual(activeConfig.userAgent, "TestAgent/1.0")
        XCTAssertEqual(activeConfig.maxRetryAttempts, 4)
        XCTAssertEqual(activeConfig.duplicateNamingRule, .overwrite)

        // Test runtime configuration update
        var updatedConfig = customConfig
        updatedConfig.maxConcurrentDownloads = 2
        updatedConfig.maxGlobalRequests = 8
        try await engine.updateConfiguration(updatedConfig)

        let updatedActive = await engine.configuration
        XCTAssertEqual(updatedActive.maxConcurrentDownloads, 2)
        XCTAssertEqual(updatedActive.maxGlobalRequests, 8)
    }

    func testStreamingDownloadOrchestrator_DecoupledConfigurationInit() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("OrchestratorConfigTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let customConfig = EngineConfiguration(
            maxConcurrentDownloads: 4,
            maxGlobalRequests: 16,
            userAgent: "CustomOrchestrator/1.0",
            maxRetryAttempts: 5
        )

        let engine = try DownloadEngine(configuration: customConfig, storageDirectoryURL: tempDir)
        let coordinator = await engine.coordinator
        let orchestrator = StreamingDownloadOrchestrator(
            configuration: customConfig,
            downloadCoordinator: coordinator,
            downloadEngine: engine
        )

        let config = await orchestrator.configuration
        XCTAssertEqual(config.maxConcurrentDownloads, 4)
        XCTAssertEqual(config.userAgent, "CustomOrchestrator/1.0")
        XCTAssertEqual(config.maxRetryAttempts, 5)
    }

    func testTorrentInfoHash_V1_V2_and_Hybrid() {
        let v1Hex = "da39a3ee5e6b4b0d3255bfef95601890afd80709" // 40 chars
        let v2Hex = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592" // 64 chars

        let v1Hash = TorrentInfoHash(v1: v1Hex)
        XCTAssertTrue(v1Hash.isV1Only)
        XCTAssertFalse(v1Hash.isV2Only)
        XCTAssertFalse(v1Hash.isHybrid)
        XCTAssertEqual(v1Hash.bestIdentifier, v1Hex)

        let v2Hash = TorrentInfoHash(v2: v2Hex)
        XCTAssertTrue(v2Hash.isV2Only)
        XCTAssertFalse(v2Hash.isV1Only)
        XCTAssertFalse(v2Hash.isHybrid)
        XCTAssertEqual(v2Hash.bestIdentifier, v2Hex)

        let hybridHash = TorrentInfoHash(v1: v1Hex, v2: v2Hex)
        XCTAssertTrue(hybridHash.isHybrid)
        XCTAssertFalse(hybridHash.isV1Only)
        XCTAssertFalse(hybridHash.isV2Only)
        XCTAssertEqual(hybridHash.v1, v1Hex)
        XCTAssertEqual(hybridHash.v2, v2Hex)

        // Hex string constructor auto-detection
        let autoV1 = TorrentInfoHash(hexString: v1Hex)
        XCTAssertTrue(autoV1.isV1Only)

        let autoV2 = TorrentInfoHash(hexString: v2Hex)
        XCTAssertTrue(autoV2.isV2Only)
    }

    func testKeychainSecurity_CredentialsStoredSeparatelyFromAppSettings() {
        let manager = KeychainManager.shared
        let server = "auth.example.com"
        let username = "admin"
        let password = "SuperSecretPassword123!"

        let stored = manager.storeInternetPassword(
            username: username,
            password: password,
            server: server
        )
        XCTAssertTrue(stored)

        let retrieved = manager.getInternetPassword(server: server)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.username, username)
        XCTAssertEqual(retrieved?.password, password)

        // Verify AppSettings does not store any sensitive auth fields
        let settings = AppSettings.default
        let mirror = Mirror(reflecting: settings)
        for child in mirror.children {
            XCTAssertFalse(child.label?.lowercased().contains("password") == true, "AppSettings must never store passwords")
            XCTAssertFalse(child.label?.lowercased().contains("secret") == true, "AppSettings must never store secrets")
        }

        manager.deleteInternetPassword(server: server)
    }
}
