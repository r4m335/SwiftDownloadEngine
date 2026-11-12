import Foundation
import XCTest
@testable import DM_Reverse_engineering

/// Self-contained ISO-BMFF test generator and in-browser MediaSource test harness.
///
/// Produces compliant fragmented-MP4 initialization and media segments,
/// and exports a reproducible HTML/JS test page for validating normal capture,
/// late-start buffer retention, live appends, and quality-switch rejection.
public enum BrowserMSETestHarness {

    // MARK: - ISO-BMFF Box Builders

    public static func box(_ type: String, payload: Data = Data()) -> Data {
        let typeBytes = Array(type.utf8)
        precondition(typeBytes.count == 4, "Box type must be exactly 4 ASCII characters")
        let size = UInt32(8 + payload.count)
        var data = Data([
            UInt8((size >> 24) & 0xff),
            UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff),
            UInt8(size & 0xff)
        ])
        data.append(contentsOf: typeBytes)
        data.append(payload)
        return data
    }

    public static func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, payload: Data = Data()) -> Data {
        var fullPayload = Data([
            version,
            UInt8((flags >> 16) & 0xff),
            UInt8((flags >> 8) & 0xff),
            UInt8(flags & 0xff)
        ])
        fullPayload.append(payload)
        return box(type, payload: fullPayload)
    }

    // MARK: - Fragmented MP4 Segment Generation

    /// Generates a structurally valid ISO-BMFF initialization segment (`ftyp` + `moov`).
    public static func buildInitSegment(
        trackKind: BrowserMSECaptureTrackKind = .video,
        trackID: UInt32 = 1,
        timescale: UInt32 = 1000
    ) -> Data {
        // 1. ftyp box
        var ftypPayload = Data()
        ftypPayload.append(contentsOf: "isom".utf8) // major brand
        ftypPayload.append(contentsOf: [0x00, 0x00, 0x02, 0x00]) // minor version 512
        ftypPayload.append(contentsOf: "isom".utf8) // compatible brands
        ftypPayload.append(contentsOf: "iso2".utf8)
        ftypPayload.append(contentsOf: "mp41".utf8)
        ftypPayload.append(contentsOf: "mp42".utf8)
        let ftyp = box("ftyp", payload: ftypPayload)

        // 2. mvhd box (movie header)
        var mvhdPayload = Data(repeating: 0, count: 8) // creation & modification time (0)
        mvhdPayload.append(contentsOf: [
            UInt8((timescale >> 24) & 0xff),
            UInt8((timescale >> 16) & 0xff),
            UInt8((timescale >> 8) & 0xff),
            UInt8(timescale & 0xff)
        ])
        mvhdPayload.append(contentsOf: [0, 0, 0, 0]) // duration (0 for fMP4 init)
        mvhdPayload.append(contentsOf: [0x00, 0x01, 0x00, 0x00]) // rate 1.0
        mvhdPayload.append(contentsOf: [0x01, 0x00]) // volume 1.0
        mvhdPayload.append(Data(repeating: 0, count: 10)) // reserved
        // 36 bytes identity matrix
        let identityMatrix: [UInt8] = [
            0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00
        ]
        mvhdPayload.append(contentsOf: identityMatrix)
        mvhdPayload.append(Data(repeating: 0, count: 24)) // pre_defined
        mvhdPayload.append(contentsOf: [0, 0, 0, 2]) // next_track_ID (2)
        let mvhd = fullBox("mvhd", version: 0, flags: 0, payload: mvhdPayload)

        // 3. trak -> tkhd
        var tkhdPayload = Data(repeating: 0, count: 8) // creation & mod time
        tkhdPayload.append(contentsOf: [
            UInt8((trackID >> 24) & 0xff),
            UInt8((trackID >> 16) & 0xff),
            UInt8((trackID >> 8) & 0xff),
            UInt8(trackID & 0xff)
        ])
        tkhdPayload.append(Data(repeating: 0, count: 4)) // reserved
        tkhdPayload.append(Data(repeating: 0, count: 4)) // duration
        tkhdPayload.append(Data(repeating: 0, count: 8)) // reserved
        tkhdPayload.append(Data(repeating: 0, count: 2)) // layer
        tkhdPayload.append(Data(repeating: 0, count: 2)) // alternate_group
        tkhdPayload.append(contentsOf: trackKind == .audio ? [0x01, 0x00] : [0x00, 0x00]) // volume
        tkhdPayload.append(Data(repeating: 0, count: 2)) // reserved
        tkhdPayload.append(contentsOf: identityMatrix)
        // width and height (16.16 fixed point)
        if trackKind == .video {
            tkhdPayload.append(contentsOf: [0x02, 0x80, 0x00, 0x00]) // 640.0
            tkhdPayload.append(contentsOf: [0x01, 0xe0, 0x00, 0x00]) // 480.0
        } else {
            tkhdPayload.append(Data(repeating: 0, count: 8))
        }
        let tkhd = fullBox("tkhd", version: 0, flags: 3, payload: tkhdPayload) // enabled | inMovie

        // 4. trak -> mdia -> mdhd
        var mdhdPayload = Data(repeating: 0, count: 8) // creation & mod time
        mdhdPayload.append(contentsOf: [
            UInt8((timescale >> 24) & 0xff),
            UInt8((timescale >> 16) & 0xff),
            UInt8((timescale >> 8) & 0xff),
            UInt8(timescale & 0xff)
        ])
        mdhdPayload.append(Data(repeating: 0, count: 4)) // duration
        mdhdPayload.append(contentsOf: [0x55, 0xc4]) // language "und"
        mdhdPayload.append(Data(repeating: 0, count: 2)) // pre_defined
        let mdhd = fullBox("mdhd", version: 0, flags: 0, payload: mdhdPayload)

        // 5. trak -> mdia -> hdlr
        var hdlrPayload = Data(repeating: 0, count: 4) // pre_defined
        let handlerType = trackKind == .audio ? "soun" : "vide"
        hdlrPayload.append(contentsOf: handlerType.utf8)
        hdlrPayload.append(Data(repeating: 0, count: 12)) // reserved
        let handlerName = trackKind == .audio ? "SoundHandler\0" : "VideoHandler\0"
        hdlrPayload.append(contentsOf: handlerName.utf8)
        let hdlr = fullBox("hdlr", version: 0, flags: 0, payload: hdlrPayload)

        // 6. trak -> mdia -> minf -> vmhd/smhd
        let mediaHeaderBox: Data
        if trackKind == .audio {
            var smhdPayload = Data()
            smhdPayload.append(contentsOf: [0, 0]) // balance
            smhdPayload.append(contentsOf: [0, 0]) // reserved
            mediaHeaderBox = fullBox("smhd", version: 0, flags: 0, payload: smhdPayload)
        } else {
            var vmhdPayload = Data()
            vmhdPayload.append(contentsOf: [0, 0]) // graphicsmode
            vmhdPayload.append(contentsOf: [0, 0, 0, 0, 0, 0]) // opcolor
            mediaHeaderBox = fullBox("vmhd", version: 0, flags: 1, payload: vmhdPayload)
        }

        // 7. trak -> mdia -> minf -> dinf -> dref -> url
        let urlBox = fullBox("url ", version: 0, flags: 1) // self-contained
        var drefPayload = Data([0, 0, 0, 1]) // entry_count 1
        drefPayload.append(urlBox)
        let dref = fullBox("dref", version: 0, flags: 0, payload: drefPayload)
        let dinf = box("dinf", payload: dref)

        // 8. trak -> mdia -> minf -> stbl
        let sampleEntry: Data
        if trackKind == .audio {
            var mp4aPayload = Data(repeating: 0, count: 6) // reserved
            mp4aPayload.append(contentsOf: [0x00, 0x01]) // data_reference_index 1
            mp4aPayload.append(Data(repeating: 0, count: 8)) // reserved
            mp4aPayload.append(contentsOf: [0x00, 0x02]) // channelcount 2
            mp4aPayload.append(contentsOf: [0x00, 0x10]) // samplesize 16
            mp4aPayload.append(Data(repeating: 0, count: 4)) // pre_defined & reserved
            mp4aPayload.append(contentsOf: [0xac, 0x44, 0x00, 0x00]) // samplerate 44100.0 (16.16)
            sampleEntry = box("mp4a", payload: mp4aPayload)
        } else {
            var avc1Payload = Data(repeating: 0, count: 6) // reserved
            avc1Payload.append(contentsOf: [0x00, 0x01]) // data_reference_index 1
            avc1Payload.append(Data(repeating: 0, count: 16)) // pre_defined & reserved
            avc1Payload.append(contentsOf: [0x02, 0x80]) // width 640
            avc1Payload.append(contentsOf: [0x01, 0xe0]) // height 480
            avc1Payload.append(contentsOf: [0x00, 0x48, 0x00, 0x00]) // horiz resolution 72 dpi
            avc1Payload.append(contentsOf: [0x00, 0x48, 0x00, 0x00]) // vert resolution 72 dpi
            avc1Payload.append(Data(repeating: 0, count: 4)) // reserved
            avc1Payload.append(contentsOf: [0x00, 0x01]) // frame_count 1
            avc1Payload.append(Data(repeating: 0, count: 32)) // compressorname (32 bytes)
            avc1Payload.append(contentsOf: [0x00, 0x18]) // depth 24
            avc1Payload.append(contentsOf: [0xff, 0xff]) // pre_defined -1
            sampleEntry = box("avc1", payload: avc1Payload)
        }

        var stsdPayload = Data([0, 0, 0, 1]) // entry_count 1
        stsdPayload.append(sampleEntry)
        let stsd = fullBox("stsd", version: 0, flags: 0, payload: stsdPayload)
        let stts = fullBox("stts", version: 0, flags: 0, payload: Data([0, 0, 0, 0])) // entry_count 0
        let stsc = fullBox("stsc", version: 0, flags: 0, payload: Data([0, 0, 0, 0])) // entry_count 0
        let stsz = fullBox("stsz", version: 0, flags: 0, payload: Data(repeating: 0, count: 8)) // sample_size 0, sample_count 0
        let stco = fullBox("stco", version: 0, flags: 0, payload: Data([0, 0, 0, 0])) // entry_count 0

        var stblPayload = Data()
        stblPayload.append(stsd)
        stblPayload.append(stts)
        stblPayload.append(stsc)
        stblPayload.append(stsz)
        stblPayload.append(stco)
        let stbl = box("stbl", payload: stblPayload)

        // Assemble minf
        var minfPayload = Data()
        minfPayload.append(mediaHeaderBox)
        minfPayload.append(dinf)
        minfPayload.append(stbl)
        let minf = box("minf", payload: minfPayload)

        // Assemble mdia
        var mdiaPayload = Data()
        mdiaPayload.append(mdhd)
        mdiaPayload.append(hdlr)
        mdiaPayload.append(minf)
        let mdia = box("mdia", payload: mdiaPayload)

        // Assemble trak
        var trakPayload = Data()
        trakPayload.append(tkhd)
        trakPayload.append(mdia)
        let trak = box("trak", payload: trakPayload)

        // 9. mvex -> trex
        var trexPayload = Data([
            UInt8((trackID >> 24) & 0xff),
            UInt8((trackID >> 16) & 0xff),
            UInt8((trackID >> 8) & 0xff),
            UInt8(trackID & 0xff)
        ])
        trexPayload.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // default_sample_description_index 1
        trexPayload.append(contentsOf: [0x00, 0x00, 0x03, 0xe8]) // default_sample_duration 1000
        trexPayload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // default_sample_size 0
        trexPayload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // default_sample_flags 0
        let trex = fullBox("trex", version: 0, flags: 0, payload: trexPayload)
        let mvex = box("mvex", payload: trex)

        // Assemble moov
        var moovPayload = Data()
        moovPayload.append(mvhd)
        moovPayload.append(trak)
        moovPayload.append(mvex)
        let moov = box("moov", payload: moovPayload)

        var initSegment = Data()
        initSegment.append(ftyp)
        initSegment.append(moov)
        return initSegment
    }

    /// Generates a structurally valid ISO-BMFF media segment (`moof` + `mdat`).
    public static func buildMediaSegment(
        sequenceNumber: UInt32 = 1,
        trackID: UInt32 = 1,
        baseDecodeTime: UInt64 = 0,
        samplePayload: Data = Data([0xaa, 0xbb, 0xcc, 0xdd])
    ) -> Data {
        // 1. mfhd box (sequence number)
        let mfhdPayload = Data([
            UInt8((sequenceNumber >> 24) & 0xff),
            UInt8((sequenceNumber >> 16) & 0xff),
            UInt8((sequenceNumber >> 8) & 0xff),
            UInt8(sequenceNumber & 0xff)
        ])
        let mfhd = fullBox("mfhd", version: 0, flags: 0, payload: mfhdPayload)

        // 2. traf -> tfhd (track fragment header)
        // flags: 0x020000 = default-base-is-moof
        let tfhdPayload = Data([
            UInt8((trackID >> 24) & 0xff),
            UInt8((trackID >> 16) & 0xff),
            UInt8((trackID >> 8) & 0xff),
            UInt8(trackID & 0xff)
        ])
        let tfhd = fullBox("tfhd", version: 0, flags: 0x020000, payload: tfhdPayload)

        // 3. traf -> tfdt (track fragment decode time)
        let tfdtPayload = Data([
            UInt8((baseDecodeTime >> 56) & 0xff),
            UInt8((baseDecodeTime >> 48) & 0xff),
            UInt8((baseDecodeTime >> 40) & 0xff),
            UInt8((baseDecodeTime >> 32) & 0xff),
            UInt8((baseDecodeTime >> 24) & 0xff),
            UInt8((baseDecodeTime >> 16) & 0xff),
            UInt8((baseDecodeTime >> 8) & 0xff),
            UInt8(baseDecodeTime & 0xff)
        ])
        let tfdt = fullBox("tfdt", version: 1, flags: 0, payload: tfdtPayload)

        // 4. traf -> trun (track run)
        // flags: 0x000205 = data-offset-present | sample-duration-present | sample-size-present
        let sampleSize = UInt32(samplePayload.count)
        var trunPayload = Data([0, 0, 0, 1]) // sample_count 1
        // placeholder for data_offset (will compute actual moof size + 8 byte mdat header)
        trunPayload.append(contentsOf: [0, 0, 0, 0])
        trunPayload.append(contentsOf: [0x00, 0x00, 0x03, 0xe8]) // sample_duration 1000
        trunPayload.append(contentsOf: [
            UInt8((sampleSize >> 24) & 0xff),
            UInt8((sampleSize >> 16) & 0xff),
            UInt8((sampleSize >> 8) & 0xff),
            UInt8(sampleSize & 0xff)
        ])
        let trunBeforeOffset = fullBox("trun", version: 0, flags: 0x000205, payload: trunPayload)

        // Compute moof size to place data_offset pointing to first byte of mdat payload
        var trafPayload = Data()
        trafPayload.append(tfhd)
        trafPayload.append(tfdt)
        trafPayload.append(trunBeforeOffset)
        let traf = box("traf", payload: trafPayload)

        var moofPayload = Data()
        moofPayload.append(mfhd)
        moofPayload.append(traf)
        let moofSize = UInt32(8 + moofPayload.count)

        // data_offset relative to moof start = moofSize + 8 (mdat header)
        let dataOffset = moofSize + 8
        var updatedTrunPayload = Data([0, 0, 0, 1]) // sample_count 1
        updatedTrunPayload.append(contentsOf: [
            UInt8((dataOffset >> 24) & 0xff),
            UInt8((dataOffset >> 16) & 0xff),
            UInt8((dataOffset >> 8) & 0xff),
            UInt8(dataOffset & 0xff)
        ])
        updatedTrunPayload.append(contentsOf: [0x00, 0x00, 0x03, 0xe8]) // sample_duration 1000
        updatedTrunPayload.append(contentsOf: [
            UInt8((sampleSize >> 24) & 0xff),
            UInt8((sampleSize >> 16) & 0xff),
            UInt8((sampleSize >> 8) & 0xff),
            UInt8(sampleSize & 0xff)
        ])
        let trun = fullBox("trun", version: 0, flags: 0x000205, payload: updatedTrunPayload)

        var finalTrafPayload = Data()
        finalTrafPayload.append(tfhd)
        finalTrafPayload.append(tfdt)
        finalTrafPayload.append(trun)
        let finalTraf = box("traf", payload: finalTrafPayload)

        var finalMoofPayload = Data()
        finalMoofPayload.append(mfhd)
        finalMoofPayload.append(finalTraf)
        let moof = box("moof", payload: finalMoofPayload)

        // 5. mdat box
        let mdat = box("mdat", payload: samplePayload)

        var mediaSegment = Data()
        mediaSegment.append(moof)
        mediaSegment.append(mdat)
        return mediaSegment
    }

    // MARK: - HTML/JS In-Browser Test Page Generation

    public struct TestPageOptions: Sendable {
        public let title: String
        public let videoMIME: String
        public let audioMIME: String
        public let hasAudio: Bool

        public init(
            title: String = "MediaSource Capture Test",
            videoMIME: String = "video/mp4; codecs=\"avc1.4d401f\"",
            audioMIME: String = "audio/mp4; codecs=\"mp4a.40.2\"",
            hasAudio: Bool = true
        ) {
            self.title = title
            self.videoMIME = videoMIME
            self.audioMIME = audioMIME
            self.hasAudio = hasAudio
        }
    }

    /// Generates a complete standalone HTML document that mounts MediaSource on `<video>`,
    /// adds SourceBuffers, and exposes scenario runners for automated WKWebView and browser tests.
    public static func generateTestPageHTML(options: TestPageOptions = TestPageOptions()) -> String {
        let videoInitB64 = buildInitSegment(trackKind: .video, trackID: 1).base64EncodedString()
        let videoFrag1B64 = buildMediaSegment(sequenceNumber: 1, trackID: 1, baseDecodeTime: 0, samplePayload: Data([0x10, 0x11, 0x12])).base64EncodedString()
        let videoFrag2B64 = buildMediaSegment(sequenceNumber: 2, trackID: 1, baseDecodeTime: 1000, samplePayload: Data([0x13, 0x14, 0x15])).base64EncodedString()
        let videoAltInitB64 = buildInitSegment(trackKind: .video, trackID: 1, timescale: 90000).base64EncodedString()

        let audioInitB64 = options.hasAudio ? buildInitSegment(trackKind: .audio, trackID: 2).base64EncodedString() : ""
        let audioFrag1B64 = options.hasAudio ? buildMediaSegment(sequenceNumber: 1, trackID: 2, baseDecodeTime: 0, samplePayload: Data([0x20, 0x21, 0x22])).base64EncodedString() : ""
        let audioFrag2B64 = options.hasAudio ? buildMediaSegment(sequenceNumber: 2, trackID: 2, baseDecodeTime: 1000, samplePayload: Data([0x23, 0x24, 0x25])).base64EncodedString() : ""

        return #"""
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <title>\#(options.title)</title>
            <style>
                body { font-family: -apple-system, system-ui, sans-serif; padding: 20px; }
                video { width: 320px; height: 240px; background: #000; display: block; margin-bottom: 12px; }
                .status-box { padding: 10px; background: #f0f0f0; border-radius: 6px; font-family: monospace; }
                button { margin: 4px; padding: 8px 12px; }
            </style>
        </head>
        <body>
            <h2>\#(options.title)</h2>
            <video id="player" controls playsinline></video>
            <div id="status" class="status-box">Status: initializing</div>

            <script>
            (function() {
                "use strict";

                var videoMIME = "\#(options.videoMIME)";
                var audioMIME = "\#(options.audioMIME)";
                var hasAudio = \#(options.hasAudio ? "true" : "false");

                var videoInitBytes = base64ToUint8Array("\#(videoInitB64)");
                var videoFrag1Bytes = base64ToUint8Array("\#(videoFrag1B64)");
                var videoFrag2Bytes = base64ToUint8Array("\#(videoFrag2B64)");
                var videoAltInitBytes = base64ToUint8Array("\#(videoAltInitB64)");

                var audioInitBytes = hasAudio ? base64ToUint8Array("\#(audioInitB64)") : null;
                var audioFrag1Bytes = hasAudio ? base64ToUint8Array("\#(audioFrag1B64)") : null;
                var audioFrag2Bytes = hasAudio ? base64ToUint8Array("\#(audioFrag2B64)") : null;

                var mediaSource = null;
                var mediaSourceURL = null;
                var videoSourceBuffer = null;
                var audioSourceBuffer = null;
                var videoElement = document.getElementById("player");
                var statusBox = document.getElementById("status");

                function log(msg) {
                    statusBox.textContent = "Status: " + msg;
                }

                function base64ToUint8Array(base64) {
                    if (!base64) { return new Uint8Array(0); }
                    var raw = atob(base64);
                    var uint8Array = new Uint8Array(raw.length);
                    for (var i = 0; i < raw.length; i++) {
                        uint8Array[i] = raw.charCodeAt(i);
                    }
                    return uint8Array;
                }

                function setupMediaSource() {
                    return new Promise(function(resolve, reject) {
                        if (!window.MediaSource) {
                            reject(new Error("MediaSource not supported"));
                            return;
                        }
                        mediaSource = new MediaSource();
                        mediaSourceURL = URL.createObjectURL(mediaSource);
                        videoElement.src = mediaSourceURL;

                        mediaSource.addEventListener("sourceopen", function() {
                            try {
                                videoSourceBuffer = mediaSource.addSourceBuffer(videoMIME);
                                if (hasAudio) {
                                    audioSourceBuffer = mediaSource.addSourceBuffer(audioMIME);
                                }
                                log("MediaSource open with " + (hasAudio ? "2 buffers" : "1 buffer"));
                                resolve({
                                    mediaSource: mediaSource,
                                    mediaSourceURL: mediaSourceURL,
                                    videoBuffer: videoSourceBuffer,
                                    audioBuffer: audioSourceBuffer
                                });
                            } catch (err) {
                                reject(err);
                            }
                        }, { once: true });
                    });
                }

                function appendToBuffer(buffer, bytes) {
                    return new Promise(function(resolve, reject) {
                        if (!buffer) { return resolve(); }
                        if (buffer.updating) {
                            buffer.addEventListener("updateend", function onEnd() {
                                buffer.removeEventListener("updateend", onEnd);
                                buffer.appendBuffer(bytes);
                                buffer.addEventListener("updateend", function onDone() {
                                    buffer.removeEventListener("updateend", onDone);
                                    resolve();
                                }, { once: true });
                            }, { once: true });
                        } else {
                            buffer.appendBuffer(bytes);
                            buffer.addEventListener("updateend", function onDone() {
                                buffer.removeEventListener("updateend", onDone);
                                resolve();
                            }, { once: true });
                        }
                    });
                }

                // Public test harness interface
                window.__mseTestHarness = {
                    setupMediaSource: setupMediaSource,
                    getMediaSourceURL: function() { return mediaSourceURL; },
                    getVideoBuffer: function() { return videoSourceBuffer; },
                    getAudioBuffer: function() { return audioSourceBuffer; },

                    appendVideoInit: function() { return appendToBuffer(videoSourceBuffer, videoInitBytes); },
                    appendVideoFrag1: function() { return appendToBuffer(videoSourceBuffer, videoFrag1Bytes); },
                    appendVideoFrag2: function() { return appendToBuffer(videoSourceBuffer, videoFrag2Bytes); },
                    appendVideoAltInit: function() { return appendToBuffer(videoSourceBuffer, videoAltInitBytes); },

                    appendAudioInit: function() { return appendToBuffer(audioSourceBuffer, audioInitBytes); },
                    appendAudioFrag1: function() { return appendToBuffer(audioSourceBuffer, audioFrag1Bytes); },
                    appendAudioFrag2: function() { return appendToBuffer(audioSourceBuffer, audioFrag2Bytes); },

                    revokeMediaSourceURL: function() {
                        if (mediaSourceURL) {
                            URL.revokeObjectURL(mediaSourceURL);
                            log("Revoked MediaSource URL");
                        }
                    },
                    removeVideoBuffer: function() {
                        if (mediaSource && videoSourceBuffer) {
                            mediaSource.removeSourceBuffer(videoSourceBuffer);
                            log("Removed Video SourceBuffer");
                        }
                    },
                    endOfStream: function() {
                        if (mediaSource && mediaSource.readyState === "open") {
                            mediaSource.endOfStream();
                            log("endOfStream called");
                        }
                    }
                };

                // Auto-setup on document load
                setupMediaSource().catch(function(err) {
                    log("Setup error: " + err.message);
                });
            })();
            </script>
        </body>
        </html>
        """#
    }
}

