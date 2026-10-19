//
//  TorrentSessionBridge.h
//  SwiftDownloadEngine - Torrent Subsystem (Milestone 1)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C bridge wrapping libtorrent 2.0.x session lifecycle and status operations.
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

@end

NS_ASSUME_NONNULL_END
