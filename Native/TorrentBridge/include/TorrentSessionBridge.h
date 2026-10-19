//
//  TorrentSessionBridge.h
//  SwiftDownloadEngine - Torrent Subsystem (Milestones 1-3)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Lifecycle state reported by libtorrent for an individual torrent.
typedef NS_ENUM(NSInteger, TorrentBridgeState) {
    TorrentBridgeStateQueued = 0,
    TorrentBridgeStateChecking = 1,
    TorrentBridgeStateDownloading = 2,
    TorrentBridgeStateFinished = 3,
    TorrentBridgeStateSeeding = 4,
    TorrentBridgeStatePaused = 5,
    TorrentBridgeStateError = 6,
    TorrentBridgeStateRemoved = 7
};

/// Point-in-time status snapshot for a torrent managed by libtorrent.
NS_SWIFT_NAME(TorrentBridgeStatus)
@interface TorrentBridgeStatus : NSObject

@property (nonatomic, readonly, copy) NSString *infoHash;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, copy) NSString *savePath;
@property (nonatomic, readonly) TorrentBridgeState state;
@property (nonatomic, readonly) int64_t totalDone;
@property (nonatomic, readonly) int64_t totalWanted;
@property (nonatomic, readonly) double downloadPayloadRate;
@property (nonatomic, readonly) double uploadPayloadRate;
@property (nonatomic, readonly) NSInteger numPeers;
@property (nonatomic, readonly) NSInteger numSeeds;
@property (nonatomic, readonly) float progress;
@property (nonatomic, readonly, nullable, copy) NSString *errorMessage;

- (instancetype)initWithInfoHash:(NSString *)infoHash
                            name:(NSString *)name
                        savePath:(NSString *)savePath
                           state:(TorrentBridgeState)state
                       totalDone:(int64_t)totalDone
                     totalWanted:(int64_t)totalWanted
             downloadPayloadRate:(double)downloadPayloadRate
               uploadPayloadRate:(double)uploadPayloadRate
                        numPeers:(NSInteger)numPeers
                        numSeeds:(NSInteger)numSeeds
                        progress:(float)progress
                    errorMessage:(nullable NSString *)errorMessage NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

/// Objective-C bridge wrapping libtorrent 2.0.x session lifecycle and transfer operations.
/// Exposes clean, pure Objective-C types to Swift without leaking C++ symbols into Swift layers.
NS_SWIFT_NAME(TorrentSessionBridge)
@interface TorrentSessionBridge : NSObject

/// Returns the libtorrent version string (e.g. "2.0.10.0").
+ (NSString *)libtorrentVersion;

/// Initializes a new torrent session bridge instance.
/// @param storagePath Root filesystem path where session data and downloaded payload files reside.
/// @param portStart Lower bound of the TCP/UDP listen port range.
/// @param portEnd Upper bound of the TCP/UDP listen port range.
- (instancetype)initWithStoragePath:(NSString *)storagePath
                          portStart:(NSUInteger)portStart
                            portEnd:(NSUInteger)portEnd NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Starts the libtorrent session and binds to the specified port range.
/// @param error Populated if session creation or socket binding fails.
/// @return YES if session initialized successfully, NO otherwise.
- (BOOL)startSession:(NSError * _Nullable * _Nullable)error;

/// Cleanly terminates the libtorrent session, releasing all listening sockets and threads.
- (void)stopSession;

/// Whether the underlying libtorrent session is running and listening.
@property (nonatomic, readonly) BOOL isListening;

/// The active port number that libtorrent is currently listening on, or 0 if inactive.
@property (nonatomic, readonly) NSUInteger listenPort;

/// The root storage path configured for this session.
@property (nonatomic, readonly, copy) NSString *storagePath;

// MARK: - Milestone 3: Core Torrent Transfer Operations

/// Adds a torrent from a Magnet URI.
/// @param magnetURI RFC-compliant magnet link (e.g. magnet:?xt=urn:btih:...).
/// @param savePath Destination directory where the payload files will be stored (or nil for default storage path).
/// @param error Populated if the magnet URI is invalid or addition fails.
/// @return Lowercase hexadecimal info-hash of the added torrent, or nil on failure.
- (nullable NSString *)addTorrentWithMagnetURI:(NSString *)magnetURI
                                     savePath:(nullable NSString *)savePath
                                        error:(NSError * _Nullable * _Nullable)error;

/// Adds a torrent from a local .torrent file path.
/// @param filePath Path to the .torrent file on disk.
/// @param savePath Destination directory where the payload files will be stored (or nil for default storage path).
/// @param error Populated if the file cannot be read or parsed.
/// @return Lowercase hexadecimal info-hash of the added torrent, or nil on failure.
- (nullable NSString *)addTorrentWithFilePath:(NSString *)filePath
                                    savePath:(nullable NSString *)savePath
                                       error:(NSError * _Nullable * _Nullable)error;

/// Adds a torrent from raw .torrent file bytes.
/// @param data NSData containing bencoded torrent file.
/// @param savePath Destination directory where the payload files will be stored (or nil for default storage path).
/// @param error Populated if the data cannot be parsed.
/// @return Lowercase hexadecimal info-hash of the added torrent, or nil on failure.
- (nullable NSString *)addTorrentWithData:(NSData *)data
                                 savePath:(nullable NSString *)savePath
                                    error:(NSError * _Nullable * _Nullable)error;

/// Pauses an active torrent transfer.
- (BOOL)pauseTorrentWithHash:(NSString *)infoHash
                       error:(NSError * _Nullable * _Nullable)error;

/// Resumes a paused torrent transfer.
- (BOOL)resumeTorrentWithHash:(NSString *)infoHash
                        error:(NSError * _Nullable * _Nullable)error;

/// Removes a torrent from the session, optionally deleting downloaded payload files.
- (BOOL)removeTorrentWithHash:(NSString *)infoHash
                  deleteFiles:(BOOL)deleteFiles
                        error:(NSError * _Nullable * _Nullable)error;

/// Returns the current transfer status for a specific torrent.
- (nullable TorrentBridgeStatus *)statusForTorrentWithHash:(NSString *)infoHash;

/// Returns the statuses of all active torrents currently tracked by this session.
- (NSArray<TorrentBridgeStatus *> *)allTorrentStatuses;

/// Drains session alerts and updates internal status caches.
- (void)pollAlerts;

@end

NS_ASSUME_NONNULL_END
