import Foundation
import DM_Reverse_engineering

@main
struct InterruptionCLI {
    static func main() async throws {
        let args = ProcessInfo.processInfo.arguments
        guard args.count >= 6 else {
            print("Usage: DM_InterruptionTestCLI <id> <url> <destPath> <storePath> <threads>")
            exit(1)
        }

        let downloadID = args[1]
        guard let url = URL(string: args[2]) else { exit(2) }
        let destURL = URL(fileURLWithPath: args[3])
        let storeURL = URL(fileURLWithPath: args[4])
        let threads = Int(args[5]) ?? 4

        let store = try DownloadPersistenceStore(storageDirectoryURL: storeURL)
        let coordinator = try DownloadCoordinator(session: .shared, persistenceStore: store)

        let request = DownloadRequest(
            id: downloadID,
            url: url,
            destinationURL: destURL,
            configuredThreadCount: threads,
            reserveDiskBytes: 1024
        )

        // Signal readiness by writing marker file
        let readyFile = storeURL.appendingPathComponent("cli_ready.marker")
        try? "ready".write(to: readyFile, atomically: true, encoding: .utf8)

        do {
            try await coordinator.start(request)
            exit(0)
        } catch {
            exit(3)
        }
    }
}
