import Foundation

/// Represents a software license notice and attribution record for a third-party library or component.
public struct OpenSourceLicense: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let licenseName: String
    public let spdxIdentifier: String
    public let copyright: String
    public let summary: String
    public let sourceURL: String?
    public let licenseURL: String
    public let isDynamicallyLinked: Bool
    public let isOfficialLGPLBuild: Bool
    public let isLinked: Bool
    public let complianceNotes: String?

    public init(
        id: String,
        name: String,
        version: String,
        licenseName: String,
        spdxIdentifier: String,
        copyright: String,
        summary: String,
        sourceURL: String? = nil,
        licenseURL: String,
        isDynamicallyLinked: Bool = false,
        isOfficialLGPLBuild: Bool = false,
        isLinked: Bool = true,
        complianceNotes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.licenseName = licenseName
        self.spdxIdentifier = spdxIdentifier
        self.copyright = copyright
        self.summary = summary
        self.sourceURL = sourceURL
        self.licenseURL = licenseURL
        self.isDynamicallyLinked = isDynamicallyLinked
        self.isOfficialLGPLBuild = isOfficialLGPLBuild
        self.isLinked = isLinked
        self.complianceNotes = complianceNotes
    }
}

/// Registry providing all third-party open-source components and licensing metadata.
public enum OpenSourceLicensesRegistry {
    public static let swiftDownloadEngine = OpenSourceLicense(
        id: "swift-download-engine",
        name: "SwiftDownloadEngine",
        version: "1.0.0",
        licenseName: "MIT License",
        spdxIdentifier: "MIT",
        copyright: "Copyright (c) 2026 r4m335",
        summary: "Permission is hereby granted, free of charge, to any person obtaining a copy of this software to deal in the Software without restriction, subject to preserving the copyright notice and permission conditions.",
        sourceURL: "https://github.com/r4m335/SwiftDownloadEngine",
        licenseURL: "https://opensource.org/licenses/MIT",
        isDynamicallyLinked: false,
        isOfficialLGPLBuild: false,
        isLinked: true,
        complianceNotes: "Application source code released under the MIT License."
    )

    public static let libtorrent = OpenSourceLicense(
        id: "libtorrent-rasterbar",
        name: "libtorrent-rasterbar",
        version: "2.0.10",
        licenseName: "BSD 3-Clause License",
        spdxIdentifier: "BSD-3-Clause",
        copyright: "Copyright (c) 2003-2024, Arvid Norberg and contributors. All rights reserved.",
        summary: "Redistribution and use in source and binary forms are permitted provided the copyright notice, condition list, and disclaimer are reproduced in the documentation and binary distribution.",
        sourceURL: "https://github.com/arvidn/libtorrent",
        licenseURL: "https://opensource.org/licenses/BSD-3-Clause",
        isDynamicallyLinked: false,
        isOfficialLGPLBuild: false,
        isLinked: true,
        complianceNotes: "Compiled as a static library slice inside LibTorrent.xcframework with Objective-C++ bridging."
    )

    public static let boost = OpenSourceLicense(
        id: "boost-cxx-libraries",
        name: "Boost C++ Libraries",
        version: "1.84.0+",
        licenseName: "Boost Software License 1.0",
        spdxIdentifier: "BSL-1.0",
        copyright: "Copyright (c) Boost contributors",
        summary: "Free of charge permission to use, reproduce, display, distribute, execute, and transmit the software, and to prepare derivative works.",
        sourceURL: "https://www.boost.org",
        licenseURL: "https://www.boost.org/LICENSE_1_0.txt",
        isDynamicallyLinked: false,
        isOfficialLGPLBuild: false,
        isLinked: true,
        complianceNotes: "Header-only template dependencies leveraged during the build phase of libtorrent-rasterbar."
    )

    public static let vlckit = OpenSourceLicense(
        id: "vlckit",
        name: "VLCKit & libVLC",
        version: "4.0.0 (VideoLAN release distribution)",
        licenseName: "GNU Lesser General Public License v2.1",
        spdxIdentifier: "LGPL-2.1-only",
        copyright: "Copyright (C) 1991, 1999 Free Software Foundation, Inc.\nCopyright (C) VideoLAN, Jean-Baptiste Kempf, and VLC contributors",
        summary: "Allows linking with proprietary or permissively licensed programs. Users have the right to modify or replace the dynamically linked library.",
        sourceURL: "https://code.videolan.org/videolan/VLCKit",
        licenseURL: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html",
        isDynamicallyLinked: true,
        isOfficialLGPLBuild: true,
        isLinked: true,
        complianceNotes: "Packaged strictly as an embedded dynamic framework (VLCKit.framework) in Frameworks/ to facilitate user library replacement. Built from the official VideoLAN LGPL distribution without GPL-incompatible modules."
    )

    public static let openssl = OpenSourceLicense(
        id: "openssl",
        name: "OpenSSL",
        version: "3.x",
        licenseName: "Apache License 2.0",
        spdxIdentifier: "Apache-2.0",
        copyright: "Copyright (c) 1998-2024 The OpenSSL Project Authors",
        summary: "Permissive license with patent grant and trademark protections.",
        sourceURL: "https://www.openssl.org",
        licenseURL: "https://www.apache.org/licenses/LICENSE-2.0",
        isDynamicallyLinked: false,
        isOfficialLGPLBuild: false,
        isLinked: false,
        complianceNotes: "Not linked in iOS build. Disabled explicitly during libtorrent configuration (-DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=TRUE) in favor of Apple native CommonCrypto and Security frameworks."
    )

    /// Returns the complete array of licenses ordered for display.
    public static var allLicenses: [OpenSourceLicense] {
        [swiftDownloadEngine, libtorrent, vlckit, boost, openssl]
    }

    /// Returns only components actively linked into the compiled binary.
    public static var linkedLicenses: [OpenSourceLicense] {
        allLicenses.filter { $0.isLinked }
    }
}
