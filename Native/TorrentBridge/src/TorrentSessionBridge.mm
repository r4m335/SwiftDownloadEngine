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
#include <libtorrent/write_resume_data.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <boost/asio/ip/tcp.hpp>

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

static std::string v1InfoHashToHex(const libtorrent::info_hash_t &ih) {
    if (ih.has_v1()) {
        return hexEncode(reinterpret_cast<const uint8_t *>(ih.v1.data()), 20);
    }
    return "";
}

static std::string v2InfoHashToHex(const libtorrent::info_hash_t &ih) {
    if (ih.has_v2()) {
        return hexEncode(reinterpret_cast<const uint8_t *>(ih.v2.data()), 32);
    }
    return "";
}

static std::string infoHashToHex(const libtorrent::info_hash_t &ih) {
    if (ih.has_v1()) {
        return v1InfoHashToHex(ih);
    } else if (ih.has_v2()) {
        return v2InfoHashToHex(ih);
    }
    return "";
}

@implementation TorrentBridgeStatus

- (instancetype)initWithInfoHash:(NSString *)infoHash
                      infoHashV1:(nullable NSString *)infoHashV1
                      infoHashV2:(nullable NSString *)infoHashV2
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
        _infoHashV1 = [infoHashV1 copy];
        _infoHashV2 = [infoHashV2 copy];
        _isHybrid = (infoHashV1 != nil && infoHashV2 != nil);
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
    return [self initWithInfoHash:infoHash
                       infoHashV1:(infoHash.length == 40 ? infoHash : nil)
                       infoHashV2:(infoHash.length == 64 ? infoHash : nil)
                             name:name
                         savePath:savePath
                            state:state
                        totalDone:totalDone
                      totalWanted:totalWanted
              downloadPayloadRate:downloadPayloadRate
                uploadPayloadRate:uploadPayloadRate
                         numPeers:numPeers
                         numSeeds:numSeeds
                         progress:progress
                     errorMessage:errorMessage];
}

@end

@implementation TorrentBridgeFileInfo

- (instancetype)initWithIndex:(NSInteger)index
                         path:(NSString *)path
                         size:(int64_t)size
                     priority:(uint8_t)priority
                     progress:(float)progress {
    self = [super init];
    if (self) {
        _index = index;
        _path = [path copy];
        _size = size;
        _priority = priority;
        _progress = progress;
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
    std::map<std::string, std::vector<char>> _cachedResumeData;
    std::map<std::string, NSString *> _resumeDataErrors;
    std::set<std::string> _explicitlyPausedHashes;
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

        // Configure network interfaces and ports with full range support
        std::string listenInterfaces;
        if (_portEnd > _portStart) {
            listenInterfaces = "0.0.0.0:" + std::to_string(_portStart) + "-" + std::to_string(_portEnd)
                             + ",[::]:" + std::to_string(_portStart) + "-" + std::to_string(_portEnd);
        } else {
            listenInterfaces = "0.0.0.0:" + std::to_string(_portStart)
                             + ",[::]:" + std::to_string(_portStart);
        }
        sp.set_str(libtorrent::settings_pack::listen_interfaces, listenInterfaces);

        // Bounded resources for mobile (iPhone / iOS memory efficiency)
        sp.set_int(libtorrent::settings_pack::alert_queue_size, 2000);
        sp.set_int(libtorrent::settings_pack::connections_limit, 100);
        sp.set_int(libtorrent::settings_pack::connection_speed, 20);
        sp.set_bool(libtorrent::settings_pack::enable_dht, true);
        sp.set_bool(libtorrent::settings_pack::enable_lsd, true);
        sp.set_bool(libtorrent::settings_pack::enable_upnp, true);
        sp.set_bool(libtorrent::settings_pack::enable_natpmp, true);
        sp.set_bool(libtorrent::settings_pack::allow_multiple_connections_per_ip, true);

        // Queueing is exclusively managed by Swift's TorrentQueueScheduler.
        // Disable libtorrent's internal auto-manage queue evaluation so libtorrent
        // never auto-resumes or auto-pauses torrents behind the back of the Swift scheduler.
        sp.set_int(libtorrent::settings_pack::active_downloads, -1);
        sp.set_int(libtorrent::settings_pack::active_seeds, -1);
        sp.set_int(libtorrent::settings_pack::active_limit, -1);
        sp.set_int(libtorrent::settings_pack::auto_manage_interval, 0);

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
    _cachedResumeData.clear();
    _resumeDataErrors.clear();
    _explicitlyPausedHashes.clear();
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

- (NSUInteger)portStart {
    return _portStart;
}

- (NSUInteger)portEnd {
    return _portEnd;
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
            auto const &ih = te->handle.info_hashes();
            std::string v1 = v1InfoHashToHex(ih);
            std::string v2 = v2InfoHashToHex(ih);
            NSString *msg = [NSString stringWithUTF8String:te->error.message().c_str()];
            if (!v1.empty()) _torrentErrors[v1] = msg;
            if (!v2.empty()) _torrentErrors[v2] = msg;
        } else if (auto const *rda = libtorrent::alert_cast<libtorrent::save_resume_data_alert>(a)) {
            auto const &ih = rda->handle.info_hashes();
            std::string v1 = v1InfoHashToHex(ih);
            std::string v2 = v2InfoHashToHex(ih);
            try {
                auto buf = libtorrent::write_resume_data_buf(rda->params);
                if (!v1.empty()) {
                    _cachedResumeData[v1] = buf;
                    _resumeDataErrors.erase(v1);
                }
                if (!v2.empty()) {
                    _cachedResumeData[v2] = buf;
                    _resumeDataErrors.erase(v2);
                }
            } catch (const std::exception &ex) {
                NSString *msg = [NSString stringWithUTF8String:ex.what()];
                if (!v1.empty()) _resumeDataErrors[v1] = msg;
                if (!v2.empty()) _resumeDataErrors[v2] = msg;
            }
        } else if (auto const *fa = libtorrent::alert_cast<libtorrent::save_resume_data_failed_alert>(a)) {
            auto const &ih = fa->handle.info_hashes();
            std::string v1 = v1InfoHashToHex(ih);
            std::string v2 = v2InfoHashToHex(ih);
            NSString *msg = [NSString stringWithUTF8String:fa->error.message().c_str()];
            if (!v1.empty()) _resumeDataErrors[v1] = msg;
            if (!v2.empty()) _resumeDataErrors[v2] = msg;
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
    auto const &ih = st.handle.info_hashes();
    std::string v1 = v1InfoHashToHex(ih);
    std::string v2 = v2InfoHashToHex(ih);
    NSString *v1Str = !v1.empty() ? [NSString stringWithUTF8String:v1.c_str()] : nil;
    NSString *v2Str = !v2.empty() ? [NSString stringWithUTF8String:v2.c_str()] : nil;

    std::string key = [hashStr UTF8String];
    NSString *err = _torrentErrors.count(key) ? _torrentErrors[key] : nil;
    if (!err && !v1.empty() && _torrentErrors.count(v1)) err = _torrentErrors[v1];
    if (!err && !v2.empty() && _torrentErrors.count(v2)) err = _torrentErrors[v2];

    TorrentBridgeState bridgeState = TorrentBridgeStateQueued;
    bool isPaused = (_explicitlyPausedHashes.count(key) > 0) ||
                    (!v1.empty() && _explicitlyPausedHashes.count(v1) > 0) ||
                    (!v2.empty() && _explicitlyPausedHashes.count(v2) > 0);
    if (isPaused) {
        bridgeState = TorrentBridgeStatePaused;
        // Invariant self-healing: ensure native handle remains paused if libtorrent shifted
        auto it = _torrents.find(key);
        if (it != _torrents.end() && it->second.is_valid()) {
            if (!static_cast<bool>(st.flags & libtorrent::torrent_flags::paused)) {
                it->second.unset_flags(libtorrent::torrent_flags::auto_managed);
                it->second.pause();
            }
        }
    } else if (st.errc) {
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
                                              infoHashV1:v1Str
                                              infoHashV2:v2Str
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
        atp.flags &= ~libtorrent::torrent_flags::auto_managed;

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

        std::string v1 = v1InfoHashToHex(handle.info_hashes());
        std::string v2 = v2InfoHashToHex(handle.info_hashes());
        if (!v1.empty()) _torrents[v1] = handle;
        if (!v2.empty()) _torrents[v2] = handle;
        std::string hexHash = !v1.empty() ? v1 : v2;
        if (hexHash.empty()) {
            if (error) {
                *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                             code:2004
                                         userInfo:@{NSLocalizedDescriptionKey: @"Torrent has invalid info-hash"}];
            }
            return nil;
        }

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
        atp.flags &= ~libtorrent::torrent_flags::auto_managed;

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

        std::string v1 = v1InfoHashToHex(handle.info_hashes());
        std::string v2 = v2InfoHashToHex(handle.info_hashes());
        if (!v1.empty()) _torrents[v1] = handle;
        if (!v2.empty()) _torrents[v2] = handle;
        std::string hexHash = !v1.empty() ? v1 : v2;
        if (hexHash.empty()) {
            if (error) {
                *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                             code:2004
                                         userInfo:@{NSLocalizedDescriptionKey: @"Torrent has invalid info-hash"}];
            }
            return nil;
        }

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
        atp.flags &= ~libtorrent::torrent_flags::auto_managed;

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

        std::string v1 = v1InfoHashToHex(handle.info_hashes());
        std::string v2 = v2InfoHashToHex(handle.info_hashes());
        if (!v1.empty()) _torrents[v1] = handle;
        if (!v2.empty()) _torrents[v2] = handle;
        std::string hexHash = !v1.empty() ? v1 : v2;
        if (hexHash.empty()) {
            if (error) {
                *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                             code:2004
                                         userInfo:@{NSLocalizedDescriptionKey: @"Torrent has invalid info-hash"}];
            }
            return nil;
        }

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
    _explicitlyPausedHashes.insert(key);
    auto it = _torrents.find(key);
    if (it == _torrents.end() || !it->second.is_valid()) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2007
                                     userInfo:@{NSLocalizedDescriptionKey: @"Torrent not found"}];
        }
        return NO;
    }
    it->second.unset_flags(libtorrent::torrent_flags::auto_managed);
    it->second.pause();
    return YES;
}

- (BOOL)resumeTorrentWithHash:(NSString *)infoHash
                        error:(NSError * _Nullable * _Nullable)error {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    std::string key = [[infoHash lowercaseString] UTF8String];
    _explicitlyPausedHashes.erase(key);
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
    it->second.unset_flags(libtorrent::torrent_flags::auto_managed);
    it->second.resume();
    return YES;
}

- (BOOL)isTorrentExplicitlyPausedWithHash:(NSString *)infoHash {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    std::string key = [[infoHash lowercaseString] UTF8String];
    return _explicitlyPausedHashes.count(key) > 0;
}

- (void)setExplicitlyPaused:(BOOL)paused forTorrentWithHash:(NSString *)infoHash {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    std::string key = [[infoHash lowercaseString] UTF8String];
    if (paused) {
        _explicitlyPausedHashes.insert(key);
        auto it = _torrents.find(key);
        if (it != _torrents.end() && it->second.is_valid()) {
            it->second.unset_flags(libtorrent::torrent_flags::auto_managed);
            it->second.pause();
        }
    } else {
        _explicitlyPausedHashes.erase(key);
    }
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

    libtorrent::torrent_handle handle = it->second;
    if (handle.is_valid()) {
        auto const &ih = handle.info_hashes();
        std::string v1 = v1InfoHashToHex(ih);
        std::string v2 = v2InfoHashToHex(ih);
        if (deleteFiles) {
            _session->remove_torrent(handle, libtorrent::session_handle::delete_files);
        } else {
            _session->remove_torrent(handle);
        }
        if (!v1.empty()) {
            _torrents.erase(v1);
            _torrentErrors.erase(v1);
            _cachedResumeData.erase(v1);
            _resumeDataErrors.erase(v1);
            _explicitlyPausedHashes.erase(v1);
        }
        if (!v2.empty()) {
            _torrents.erase(v2);
            _torrentErrors.erase(v2);
            _cachedResumeData.erase(v2);
            _resumeDataErrors.erase(v2);
            _explicitlyPausedHashes.erase(v2);
        }
    }
    _torrents.erase(key);
    _torrentErrors.erase(key);
    _cachedResumeData.erase(key);
    _resumeDataErrors.erase(key);
    _explicitlyPausedHashes.erase(key);
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

    NSMutableSet<NSString *> *seenHashes = [NSMutableSet set];
    NSMutableArray<TorrentBridgeStatus *> *list = [NSMutableArray arrayWithCapacity:_torrents.size()];
    for (auto const &pair : _torrents) {
        if (pair.second.is_valid()) {
            std::string canonical = infoHashToHex(pair.second.info_hashes());
            NSString *canonKey = [NSString stringWithUTF8String:canonical.c_str()];
            if ([seenHashes containsObject:canonKey]) {
                continue;
            }
            [seenHashes addObject:canonKey];
            libtorrent::torrent_status st = pair.second.status();
            TorrentBridgeStatus *status = [self statusFromLibtorrentStatus:st infoHashString:canonKey];
            if (status) {
                [list addObject:status];
            }
        }
    }
    return [list copy];
}

// MARK: - Milestone 6: Per-File Priority & Management

- (nullable NSArray<TorrentBridgeFileInfo *> *)filesForTorrentWithHash:(NSString *)infoHash {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    std::string hex = [infoHash.lowercaseString UTF8String];
    auto it = _torrents.find(hex);
    if (it == _torrents.end() || !it->second.is_valid()) {
        return nil;
    }

    libtorrent::torrent_handle &handle = it->second;
    std::shared_ptr<const libtorrent::torrent_info> ti = handle.torrent_file();
    if (!ti) {
        // Metadata not yet resolved (e.g. magnet link in early discovery)
        return nil;
    }

    libtorrent::file_storage const &files = ti->files();
    int const numFiles = files.num_files();
    std::vector<libtorrent::download_priority_t> prios = handle.get_file_priorities();

    // Query file download progress
    std::vector<std::int64_t> fileProgress;
    handle.file_progress(fileProgress, libtorrent::torrent_handle::piece_granularity);

    NSMutableArray<TorrentBridgeFileInfo *> *result = [NSMutableArray arrayWithCapacity:numFiles];
    for (int i = 0; i < numFiles; ++i) {
        libtorrent::file_index_t const idx(i);
        NSString *filePath = [NSString stringWithUTF8String:files.file_path(idx).c_str()];
        int64_t fileSize = files.file_size(idx);
        uint8_t priority = i < prios.size() ? static_cast<uint8_t>(prios[i]) : 4;

        float prog = 0.0f;
        if (i < fileProgress.size() && fileSize > 0) {
            prog = static_cast<float>(static_cast<double>(fileProgress[i]) / static_cast<double>(fileSize));
            if (prog > 1.0f) prog = 1.0f;
            if (prog < 0.0f) prog = 0.0f;
        }

        TorrentBridgeFileInfo *info = [[TorrentBridgeFileInfo alloc] initWithIndex:i
                                                                              path:filePath
                                                                              size:fileSize
                                                                          priority:priority
                                                                          progress:prog];
        [result addObject:info];
    }
    return [result copy];
}

- (BOOL)setPriority:(uint8_t)priority
      forFileAtIndex:(NSInteger)fileIndex
   inTorrentWithHash:(NSString *)infoHash
               error:(NSError * _Nullable * _Nullable)error {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    std::string hex = [infoHash.lowercaseString UTF8String];
    auto it = _torrents.find(hex);
    if (it == _torrents.end() || !it->second.is_valid()) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2007
                                     userInfo:@{NSLocalizedDescriptionKey: @"Torrent not found"}];
        }
        return NO;
    }

    libtorrent::torrent_handle &handle = it->second;
    handle.file_priority(libtorrent::file_index_t(static_cast<int>(fileIndex)),
                         libtorrent::download_priority_t(priority));
    return YES;
}

- (BOOL)setFilePriorities:(NSArray<NSNumber *> *)priorities
        inTorrentWithHash:(NSString *)infoHash
                    error:(NSError * _Nullable * _Nullable)error {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    std::string hex = [infoHash.lowercaseString UTF8String];
    auto it = _torrents.find(hex);
    if (it == _torrents.end() || !it->second.is_valid()) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2007
                                     userInfo:@{NSLocalizedDescriptionKey: @"Torrent not found"}];
        }
        return NO;
    }

    std::vector<libtorrent::download_priority_t> prioVec;
    prioVec.reserve(priorities.count);
    for (NSNumber *num in priorities) {
        prioVec.push_back(libtorrent::download_priority_t(num.unsignedCharValue));
    }

    libtorrent::torrent_handle &handle = it->second;
    handle.prioritize_files(prioVec);
    return YES;
}

// MARK: - Milestone 4: Fast-Resume & State Persistence

- (BOOL)requestResumeDataForTorrentWithHash:(NSString *)infoHash
                                      error:(NSError * _Nullable * _Nullable)error {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    if (!_session) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Session not running"}];
        }
        return NO;
    }

    std::string key = [infoHash.lowercaseString UTF8String];
    auto it = _torrents.find(key);
    if (it == _torrents.end() || !it->second.is_valid()) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2002
                                     userInfo:@{NSLocalizedDescriptionKey: @"Torrent not found"}];
        }
        return NO;
    }

    _cachedResumeData.erase(key);
    _resumeDataErrors.erase(key);

    try {
        it->second.save_resume_data(libtorrent::torrent_handle::save_info_dict);
        return YES;
    } catch (const std::exception &ex) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2007
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ex.what()]}];
        }
        return NO;
    }
}

- (BOOL)isResumeDataReadyForTorrentWithHash:(NSString *)infoHash {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    [self processAlertsLocked];
    std::string key = [infoHash.lowercaseString UTF8String];
    return _cachedResumeData.find(key) != _cachedResumeData.end();
}

- (nullable NSData *)resumeDataForTorrentWithHash:(NSString *)infoHash {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    [self processAlertsLocked];
    std::string key = [infoHash.lowercaseString UTF8String];
    auto it = _cachedResumeData.find(key);
    if (it != _cachedResumeData.end() && !it->second.empty()) {
        return [NSData dataWithBytes:it->second.data() length:it->second.size()];
    }
    return nil;
}

- (nullable NSString *)resumeDataErrorForTorrentWithHash:(NSString *)infoHash {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    [self processAlertsLocked];
    std::string key = [infoHash.lowercaseString UTF8String];
    auto it = _resumeDataErrors.find(key);
    if (it != _resumeDataErrors.end()) {
        return it->second;
    }
    return nil;
}

- (nullable NSString *)addTorrentWithResumeData:(NSData *)resumeData
                                      savePath:(nullable NSString *)savePath
                                         error:(NSError * _Nullable * _Nullable)error {
    std::lock_guard<std::mutex> lock(_sessionMutex);
    if (!_session) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2001
                                     userInfo:@{NSLocalizedDescriptionKey: @"Session not running"}];
        }
        return nil;
    }

    if (!resumeData || resumeData.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2006
                                     userInfo:@{NSLocalizedDescriptionKey: @"Empty or missing fast-resume data"}];
        }
        return nil;
    }

    try {
        libtorrent::error_code ec;
        libtorrent::span<char const> buffer(reinterpret_cast<const char *>(resumeData.bytes), resumeData.length);
        libtorrent::add_torrent_params params = libtorrent::read_resume_data(buffer, ec);
        if (ec) {
            if (error) {
                NSString *msg = [NSString stringWithUTF8String:ec.message().c_str()];
                *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                             code:2006
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Corrupt fast-resume data: %@", msg]}];
            }
            return nil;
        }

        NSString *targetSavePath = (savePath != nil && savePath.length > 0) ? savePath : _storagePath;
        if (targetSavePath.length > 0) {
            params.save_path = [targetSavePath UTF8String];
        }
        params.flags &= ~libtorrent::torrent_flags::auto_managed;

        libtorrent::torrent_handle handle = _session->add_torrent(params, ec);
        if (ec) {
            if (error) {
                NSString *msg = [NSString stringWithUTF8String:ec.message().c_str()];
                *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                             code:2003
                                         userInfo:@{NSLocalizedDescriptionKey: msg}];
            }
            return nil;
        }

        std::string v1 = v1InfoHashToHex(handle.info_hashes());
        std::string v2 = v2InfoHashToHex(handle.info_hashes());
        if (!v1.empty()) _torrents[v1] = handle;
        if (!v2.empty()) _torrents[v2] = handle;
        std::string hexHash = !v1.empty() ? v1 : v2;
        return [NSString stringWithUTF8String:hexHash.c_str()];
    } catch (const std::exception &ex) {
        if (error) {
            NSString *msg = [NSString stringWithUTF8String:ex.what()];
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2005
                                     userInfo:@{NSLocalizedDescriptionKey: msg}];
        }
        return nil;
    }
}

// MARK: - Milestone 6.1: Direct Peer Connection & Local Swarm

- (BOOL)connectPeerWithAddress:(NSString *)address
                          port:(NSUInteger)port
             toTorrentWithHash:(NSString *)infoHash
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

    std::string key = [infoHash.lowercaseString UTF8String];
    auto it = _torrents.find(key);
    if (it == _torrents.end() || !it->second.is_valid()) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2006
                                     userInfo:@{NSLocalizedDescriptionKey: @"Torrent not found"}];
        }
        return NO;
    }

    try {
        boost::system::error_code ec;
        auto ip = boost::asio::ip::make_address([address UTF8String], ec);
        if (ec) {
            if (error) {
                *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                             code:2007
                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ec.message().c_str()]}];
            }
            return NO;
        }
        boost::asio::ip::tcp::endpoint ep(ip, static_cast<unsigned short>(port));
        it->second.connect_peer(ep);
        return YES;
    } catch (const std::exception &ex) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.r4m335.TorrentSessionBridge"
                                         code:2008
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ex.what()]}];
        }
        return NO;
    }
}

- (void)dealloc {
    [self stopSession];
}

@end
