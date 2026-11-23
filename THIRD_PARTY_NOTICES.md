# Third-Party Software Notices and Licenses

This application incorporates open-source software components under various permissive and copyleft licenses. This document provides notice, attribution, copyright information, and licensing requirements for all integrated third-party libraries.

---

## Component Summary

| Component | Version | License | Linkage / Packaging | Source Availability |
| :--- | :--- | :--- | :--- | :--- |
| **SwiftDownloadEngine (App)** | 1.0.0 | [MIT](#mit-license) | Application Core | Main Repository |
| **libtorrent-rasterbar** | 2.0.10 | [BSD-3-Clause](#bsd-3-clause-license) | Statically Linked (`LibTorrent.xcframework`) | [GitHub](https://github.com/arvidn/libtorrent) |
| **Boost C++ Libraries** | 1.84.0+ | [BSL-1.0](#boost-software-license-10) | Build-time Headers | [Boost.org](https://www.boost.org) |
| **VLCKit (libVLC)** | 4.0.0 | [LGPL-2.1](#gnu-lesser-general-public-license-v21) | Dynamically Linked (`VLCKit.framework`) | [VideoLAN Git](https://code.videolan.org/videolan/VLCKit) |
| **OpenSSL** | 3.x | [Apache-2.0](#apache-license-20-status) | *Not Linked (Disabled at build)* | [OpenSSL.org](https://www.openssl.org) |

---

## 1. libtorrent-rasterbar

- **Component:** `libtorrent-rasterbar`
- **Version:** `2.0.10`
- **License:** BSD 3-Clause ("Modified BSD License")
- **Copyright:** Copyright (c) 2003-2024, Arvid Norberg and contributors. All rights reserved.
- **Upstream:** [https://github.com/arvidn/libtorrent](https://github.com/arvidn/libtorrent)
- **License SPDX:** `BSD-3-Clause`

### Notice & Redistribution Terms
Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
3. Neither the name of the author nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

*DISCLAIMER: THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES.*

---

## 2. Boost C++ Libraries

- **Component:** Boost C++ Libraries
- **Version:** `1.84.0+`
- **License:** Boost Software License 1.0 (BSL-1.0)
- **Copyright:** Copyright (c) Boost contributors
- **Upstream:** [https://www.boost.org/](https://www.boost.org/)
- **License SPDX:** `BSL-1.0`

### Notice & Terms
Boost header libraries are used during the compilation of `libtorrent-rasterbar`. The software is provided "as is", without warranty of any kind, express or implied. Under the Boost Software License, binary-only distributions do not require notice reproduction, but attribution is provided here for completeness.

---

## 3. VLCKit and libVLC (LGPL Compliance)

- **Component:** VLCKit (and underlying libVLC engine)
- **Version:** `4.0.0` (Official VideoLAN release distribution)
- **License:** GNU Lesser General Public License, Version 2.1 (LGPL-2.1)
- **Copyright:**
  - Copyright (C) 1991, 1999 Free Software Foundation, Inc.
  - Copyright (C) VideoLAN, Jean-Baptiste Kempf, and VLC authors / contributors.
- **License SPDX:** `LGPL-2.1-only`
- **Upstream Repository:** [https://code.videolan.org/videolan/VLCKit](https://code.videolan.org/videolan/VLCKit)
- **libVLC Source Archive:** [https://www.videolan.org/vlc/download-sources.html](https://www.videolan.org/vlc/download-sources.html)

### LGPL-2.1 Compliance Obligations

1. **Attribution & Notice:**
   Attribution to VideoLAN and the Free Software Foundation is preserved in this document and accessible within the app via **Settings → About → Open Source Licenses**.

2. **Dynamic Linking & User Replaceability:**
   VLCKit is bundled and integrated strictly as a **dynamic framework** (`VLCKit.framework`) embedded inside the app bundle's `Frameworks/` directory. It is not statically linked into the main executable. This structure permits end-users on eligible iOS/macOS environments to relink or replace `VLCKit.framework` with a compatible custom build.

3. **Source Code Availability:**
   The exact upstream source code for VLCKit is publicly accessible from the official VideoLAN repositories:
   - VLCKit iOS SDK: [https://code.videolan.org/videolan/VLCKit](https://code.videolan.org/videolan/VLCKit)
   - libVLC core engine: [https://www.videolan.org/vlc/download-sources.html](https://www.videolan.org/vlc/download-sources.html)
   No modifications were made to the precompiled VLCKit dynamic binaries.

4. **Official LGPL Build Verification:**
   The VLCKit binary packaged with this application is the official VideoLAN LGPL release, compiled without GPL-only dependencies or plugins, ensuring full license separation and preventing copyleft propagation to the host application.

---

## 4. OpenSSL Status Clarification

- **Component:** OpenSSL
- **Version:** 3.x
- **License:** Apache License 2.0 (`Apache-2.0`)
- **Status:** **NOT LINKED (Disabled at build time)**
- **Verification:** In `scripts/build_libtorrent_ios.sh`, the build explicitly passes:
  ```bash
  -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=TRUE
  -DCMAKE_DISABLE_FIND_PACKAGE_GnuTLS=TRUE
  ```
  The application and its `libtorrent` binary rely exclusively on Apple native security frameworks (`Security.framework` and `CommonCrypto`). OpenSSL is neither distributed nor linked into the binary artifacts.

---

## 5. Application Code (MIT License)

```
MIT License

Copyright (c) 2026 r4m335

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
