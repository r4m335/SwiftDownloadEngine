//
//  TorrentSessionBridge.mm
//  SwiftDownloadEngine - Torrent Subsystem (Milestone 1)
//

#import "TorrentSessionBridge.h"

#include <memory>
#include <string>
#include <mutex>

#include <libtorrent/version.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/alert_types.hpp>

@interface TorrentSessionBridge () {
    std::unique_ptr<libtorrent::session> _session;
    std::mutex _sessionMutex;
    NSUInteger _portStart;
    NSUInteger _portEnd;
}
@property (nonatomic, readwrite, copy) NSString *storagePath;
@end

@implementation TorrentSessionBridge

+ (NSString *)libtorrentVersion {
    return [NSString stringWithUTF8String:libtorrent::version()];
}

- (instancetype)initWithStoragePath:(NSString *)storagePath
                          portStart:(NSUInteger)portStart
                            portEnd:(NSUInteger)portEnd {
    self = [super init];
    if (self) {
        _storagePath = [storagePath copy];
        _portStart = portStart > 0 ? portStart : 6881;
        _portEnd = portEnd >= _portStart ? portEnd : _portStart + 10;
    }
    return self;
}

- (BOOL)startSession:(NSError * _Nullable * _Nullable)error {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    if (_session) {
        return YES; // already running
    }

    try {
        libtorrent::settings_pack sp;

        // Configure network interfaces and ports
        std::string listenInterfaces = "0.0.0.0:" + std::to_string(_portStart);
        sp.set_str(libtorrent::settings_pack::listen_interfaces, listenInterfaces);

        // Bounded resources for mobile (iPhone / iOS memory efficiency)
        sp.set_int(libtorrent::settings_pack::alert_queue_limit, 2000);
        sp.set_int(libtorrent::settings_pack::connections_limit, 100);
        sp.set_int(libtorrent::settings_pack::connection_speed, 20);
        sp.set_bool(libtorrent::settings_pack::enable_dht, true);
        sp.set_bool(libtorrent::settings_pack::enable_lsd, true);
        sp.set_bool(libtorrent::settings_pack::enable_upnp, true);
        sp.set_bool(libtorrent::settings_pack::enable_natpmp, true);

        // Enable essential alerts
        sp.set_int(libtorrent::settings_pack::alert_mask,
                   libtorrent::alert_category::error
                   | libtorrent::alert_category::status
                   | libtorrent::alert_category::storage);

        _session = std::make_unique<libtorrent::session>(sp);
        return YES;
    } catch (const std::exception &ex) {
        if (error) {
            NSString *msg = [NSString stringWithUTF8String:ex.what()];
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:1001
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return NO;
    } catch (...) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:1002
                                     userInfo:@{NSLocalizedDescriptionKey: @"Unknown exception initializing libtorrent session"}];
        }
        return NO;
    }
}

- (void)stopSession {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    if (!_session) {
        return;
    }
    // Cleanly abort all transfers and shut down threads
    _session->abort();
    _session.reset();
}

- (BOOL)isListening {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    if (!_session) {
        return NO;
    }
    return _session->is_listening();
}

- (NSUInteger)listenPort {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    if (!_session) {
        return 0;
    }
    return static_cast<NSUInteger>(_session->listen_port());
}

- (void)dealloc {
    [self stopSession];
}

@end
