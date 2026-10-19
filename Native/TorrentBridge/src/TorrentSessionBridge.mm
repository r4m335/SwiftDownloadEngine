//
//  TorrentSessionBridge.mm
//  SwiftDownloadEngine - Torrent Subsystem (Milestones 1-3)
//

#import "TorrentSessionBridge.h"

#include <memory>
#include <string>
#include <vector>
#include <map>
#include <mutex>
#include <cstdint>

#include <libtorrent/version.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/span.hpp>
#include <libtorrent/info_hash.hpp>

static std::string hexEncode(const uint8_t *bytes, size_t length) {
    static const char hexDigits[] = "0123456789abcdef";
    std::string hex;
    hex.reserve(length * 2);
    for (size_t i = 0; i < length; ++i) {
        hex.push_back(hexDigits[(bytes[i] >> 4) & 0x0F]);
        hex.push_back(hexDigits[bytes[i] & 0x0F]);
    }
    return hex;
}

static std::string infoHashToHex(const libtorrent::info_hash_t &ih) {
    if (ih.has_v1()) {
        return hexEncode(reinterpret_cast<const uint8_t *>(ih.v1.data()), 20);
    } else if (ih.has_v2()) {
        return hexEncode(reinterpret_cast<const uint8_t *>(ih.v2.data()), 32);
    }
    return "";
}

@implementation TorrentBridgeStatus

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
                    errorMessage:(nullable NSString *)errorMessage {
    self = [super init];
    if (self) {
        _infoHash = [infoHash copy];
        _name = [name copy];
        _savePath = [savePath copy];
        _state = state;
        _totalDone = totalDone;
        _totalWanted = totalWanted;
        _downloadPayloadRate = downloadPayloadRate;
        _uploadPayloadRate = uploadPayloadRate;
        _numPeers = numPeers;
        _numSeeds = numSeeds;
        _progress = progress;
        _errorMessage = [errorMessage copy];
    }
    return self;
}

@end

@interface TorrentSessionBridge () {
    std::unique_ptr<libtorrent::session> _session;
    std::mutex _sessionMutex;
    NSUInteger _portStart;
    NSUInteger _portEnd;
    std::map<std::string, libtorrent::torrent_handle> _torrents;
    std::map<std::string, NSString *> _torrentErrors;
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
        sp.set_int(libtorrent::settings_pack::alert_queue_size, 2000);
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
    _torrents.clear();
    _torrentErrors.clear();
    auto proxy = _session->abort();
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

// MARK: - Internal Alert Processing

- (void)processAlertsLocked {
    if (!_session) {
        return;
    }
    std::vector<libtorrent::alert *> alerts;
    _session->pop_alerts(&alerts);
    for (libtorrent::alert const *a : alerts) {
        if (auto const *te = libtorrent::alert_cast<libtorrent::torrent_error_alert>(a)) {
            std::string hash = infoHashToHex(te->handle.info_hashes());
            if (!hash.empty()) {
                _torrentErrors[hash] = [NSString stringWithUTF8String:te->error.message().c_str()];
            }
        }
    }
}

- (void)pollAlerts {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    [self processAlertsLocked];
}

// MARK: - Helper Status Builder

- (TorrentBridgeStatus *)statusFromLibtorrentStatus:(const libtorrent::torrent_status &)st
                                     infoHashString:(NSString *)hashStr {
    std::string key = [hashStr UTF8String];
    NSString *err = _torrentErrors.count(key) ? _torrentErrors[key] : nil;

    TorrentBridgeState bridgeState = TorrentBridgeStateQueued;
    if (st.errc) {
        bridgeState = TorrentBridgeStateError;
        if (!err) {
            err = [NSString stringWithUTF8String:st.errc.message().c_str()];
        }
    } else if (err != nil) {
        bridgeState = TorrentBridgeStateError;
    } else if (static_cast<bool>(st.flags & libtorrent::torrent_flags::paused)
               && st.state != libtorrent::torrent_status::finished
               && st.state != libtorrent::torrent_status::seeding) {
        bridgeState = TorrentBridgeStatePaused;
    } else {
        switch (st.state) {
            case libtorrent::torrent_status::checking_files:
            case libtorrent::torrent_status::checking_resume_data:
                bridgeState = TorrentBridgeStateChecking;
                break;
            case libtorrent::torrent_status::downloading_metadata:
            case libtorrent::torrent_status::downloading:
                bridgeState = TorrentBridgeStateDownloading;
                break;
            case libtorrent::torrent_status::finished:
                bridgeState = TorrentBridgeStateFinished;
                break;
            case libtorrent::torrent_status::seeding:
                bridgeState = TorrentBridgeStateSeeding;
                break;
            default:
                bridgeState = TorrentBridgeStateQueued;
                break;
        }
    }

    NSString *name = st.name.empty() ? hashStr : [NSString stringWithUTF8String:st.name.c_str()];
    NSString *savePath = [NSString stringWithUTF8String:st.save_path.c_str()];

    return [[TorrentBridgeStatus alloc] initWithInfoHash:hashStr
                                                    name:name
                                                savePath:savePath
                                                   state:bridgeState
                                               totalDone:st.total_done
                                             totalWanted:st.total_wanted
                                     downloadPayloadRate:static_cast<double>(st.download_payload_rate)
                                       uploadPayloadRate:static_cast<double>(st.upload_payload_rate)
                                                numPeers:static_cast<NSInteger>(st.num_peers)
                                                numSeeds:static_cast<NSInteger>(st.num_seeds)
                                                progress:st.progress
                                            errorMessage:err];
}

// MARK: - Milestone 3: Transfer Ingestion & Controls

- (nullable NSString *)addTorrentWithMagnetURI:(NSString *)magnetURI
                                     savePath:(nullable NSString *)savePath
                                        error:(NSError * _Nullable * _Nullable)error {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    if (!_session) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Torrent session is not running"}];
        }
        return nil;
    }

    try {
        libtorrent::error_code ec;
        libtorrent::add_torrent_params atp = libtorrent::parse_magnet_uri([magnetURI UTF8String], ec);
        if (ec) {
            if (error) {
                *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                             code:2002
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ec.message().c_str()]}];
            }
            return nil;
        }

        NSString *effectiveSavePath = (savePath.length > 0) ? savePath : _storagePath;
        [[NSFileManager defaultManager] createDirectoryAtPath:effectiveSavePath
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        atp.save_path = [effectiveSavePath UTF8String];

        libtorrent::torrent_handle handle = _session->add_torrent(atp, ec);
        if (ec || !handle.is_valid()) {
            if (error) {
                NSString *msg = ec ? [NSString stringWithUTF8String:ec.message().c_str()] : @"Failed to add torrent handle";
                *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                             code:2003
                                         userInfo:@{NSLocalizedDescriptionKey: msg}];
            }
            return nil;
        }

        std::string hexHash = infoHashToHex(handle.info_hashes());
        if (hexHash.empty()) {
            if (error) {
                *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                             code:2004
                                         userInfo:@{NSLocalizedDescriptionKey: @"Torrent has invalid info-hash"}];
            }
            return nil;
        }

        _torrents[hexHash] = handle;
        return [NSString stringWithUTF8String:hexHash.c_str()];
    } catch (const std::exception &ex) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2005
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ex.what()]}];
        }
        return nil;
    }
}

- (nullable NSString *)addTorrentWithFilePath:(NSString *)filePath
                                    savePath:(nullable NSString *)savePath
                                       error:(NSError * _Nullable * _Nullable)error {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    if (!_session) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Torrent session is not running"}];
        }
        return nil;
    }

    try {
        libtorrent::add_torrent_params atp = libtorrent::load_torrent_file([filePath UTF8String]);

        NSString *effectiveSavePath = (savePath.length > 0) ? savePath : _storagePath;
        [[NSFileManager defaultManager] createDirectoryAtPath:effectiveSavePath
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        atp.save_path = [effectiveSavePath UTF8String];

        libtorrent::error_code ec;
        libtorrent::torrent_handle handle = _session->add_torrent(atp, ec);
        if (ec || !handle.is_valid()) {
            if (error) {
                NSString *msg = ec ? [NSString stringWithUTF8String:ec.message().c_str()] : @"Failed to add torrent handle";
                *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                             code:2003
                                         userInfo:@{NSLocalizedDescriptionKey: msg}];
            }
            return nil;
        }

        std::string hexHash = infoHashToHex(handle.info_hashes());
        if (hexHash.empty()) {
            if (error) {
                *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                             code:2004
                                         userInfo:@{NSLocalizedDescriptionKey: @"Torrent has invalid info-hash"}];
            }
            return nil;
        }

        _torrents[hexHash] = handle;
        return [NSString stringWithUTF8String:hexHash.c_str()];
    } catch (const std::exception &ex) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2005
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ex.what()]}];
        }
        return nil;
    }
}

- (nullable NSString *)addTorrentWithData:(NSData *)data
                                 savePath:(nullable NSString *)savePath
                                    error:(NSError * _Nullable * _Nullable)error {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    if (!_session) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Torrent session is not running"}];
        }
        return nil;
    }

    if (data.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2006
                                     userInfo:@{NSLocalizedDescriptionKey: @"Torrent data is empty"}];
        }
        return nil;
    }

    try {
        libtorrent::span<char const> buffer(reinterpret_cast<char const *>(data.bytes), data.length);
        libtorrent::add_torrent_params atp = libtorrent::load_torrent_buffer(buffer);

        NSString *effectiveSavePath = (savePath.length > 0) ? savePath : _storagePath;
        [[NSFileManager defaultManager] createDirectoryAtPath:effectiveSavePath
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        atp.save_path = [effectiveSavePath UTF8String];

        libtorrent::error_code ec;
        libtorrent::torrent_handle handle = _session->add_torrent(atp, ec);
        if (ec || !handle.is_valid()) {
            if (error) {
                NSString *msg = ec ? [NSString stringWithUTF8String:ec.message().c_str()] : @"Failed to add torrent handle";
                *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                             code:2003
                                         userInfo:@{NSLocalizedDescriptionKey: msg}];
            }
            return nil;
        }

        std::string hexHash = infoHashToHex(handle.info_hashes());
        if (hexHash.empty()) {
            if (error) {
                *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                             code:2004
                                         userInfo:@{NSLocalizedDescriptionKey: @"Torrent has invalid info-hash"}];
            }
            return nil;
        }

        _torrents[hexHash] = handle;
        return [NSString stringWithUTF8String:hexHash.c_str()];
    } catch (const std::exception &ex) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2005
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ex.what()]}];
        }
        return nil;
    }
}

- (BOOL)pauseTorrentWithHash:(NSString *)infoHash
                       error:(NSError * _Nullable * _Nullable)error {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    std::string key = [[infoHash lowercaseString] UTF8String];
    auto it = _torrents.find(key);
    if (it == _torrents.end() || !it->second.is_valid()) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2007
                                     userInfo:@{NSLocalizedDescriptionKey: @"Torrent not found"}];
        }
        return NO;
    }
    it->second.pause();
    return YES;
}

- (BOOL)resumeTorrentWithHash:(NSString *)infoHash
                        error:(NSError * _Nullable * _Nullable)error {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    std::string key = [[infoHash lowercaseString] UTF8String];
    auto it = _torrents.find(key);
    if (it == _torrents.end() || !it->second.is_valid()) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2007
                                     userInfo:@{NSLocalizedDescriptionKey: @"Torrent not found"}];
        }
        return NO;
    }
    _torrentErrors.erase(key);
    it->second.resume();
    return YES;
}

- (BOOL)removeTorrentWithHash:(NSString *)infoHash
                  deleteFiles:(BOOL)deleteFiles
                        error:(NSError * _Nullable * _Nullable)error {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    if (!_session) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Torrent session is not running"}];
        }
        return NO;
    }

    std::string key = [[infoHash lowercaseString] UTF8String];
    auto it = _torrents.find(key);
    if (it == _torrents.end()) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2007
                                     userInfo:@{NSLocalizedDescriptionKey: @"Torrent not found"}];
        }
        return NO;
    }

    if (it->second.is_valid()) {
        if (deleteFiles) {
            _session->remove_torrent(it->second, libtorrent::session_handle::delete_files);
        } else {
            _session->remove_torrent(it->second);
        }
    }
    _torrents.erase(it);
    _torrentErrors.erase(key);
    return YES;
}

- (nullable TorrentBridgeStatus *)statusForTorrentWithHash:(NSString *)infoHash {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    [self processAlertsLocked];

    std::string key = [[infoHash lowercaseString] UTF8String];
    auto it = _torrents.find(key);
    if (it == _torrents.end() || !it->second.is_valid()) {
        return nil;
    }

    libtorrent::torrent_status st = it->second.status();
    return [self statusFromLibtorrentStatus:st infoHashString:[NSString stringWithUTF8String:key.c_str()]];
}

- (NSArray<TorrentBridgeStatus *> *)allTorrentStatuses {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    [self processAlertsLocked];

    NSMutableArray<TorrentBridgeStatus *> *list = [NSMutableArray arrayWithCapacity:_torrents.size()];
    for (auto const &pair : _torrents) {
        if (pair.second.is_valid()) {
            libtorrent::torrent_status st = pair.second.status();
            TorrentBridgeStatus *status = [self statusFromLibtorrentStatus:st infoHashString:[NSString stringWithUTF8String:pair.first.c_str()]];
            if (status) {
                [list addObject:status];
            }
        }
    }
    return [list copy];
}

- (void)dealloc {
    [self stopSession];
}

@end
