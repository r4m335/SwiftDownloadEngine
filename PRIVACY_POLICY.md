# Privacy Policy for LID Download Manager (SwiftDownloadEngine)

**Last Updated:** November 24, 2026  
**Effective Date:** November 24, 2026  
**Official Repository & Source:** [https://github.com/r4m335/SwiftDownloadEngine](https://github.com/r4m335/SwiftDownloadEngine)

---

## 1. Introduction

LID Download Manager (powered by SwiftDownloadEngine) is designed from the ground up with **privacy-by-design** principles. We believe that your downloads, browsing activity, media playback, and personal files are strictly your private business.

This Privacy Policy explains how our application functions and confirms that **we do not collect, transmit, sell, or monetize any of your personal data**.

---

## 2. No Data Collection or Telemetry

- **Zero Remote Tracking:** The application does not contain advertising SDKs, behavioral trackers, or external analytics frameworks (e.g. Firebase Analytics, Google Analytics, Facebook SDK, Adjust, AppsFlyer).
- **No User Accounts:** You do not need to register an account, log in, or provide personal details (name, email, phone number) to use any feature of the application.
- **No Server Infrastructure:** The developers do not operate proprietary servers to monitor or log your activity. The app is an entirely client-side utility executing directly on your device.

---

## 3. On-Device Data Storage & Security

All application data is retained exclusively on your local device within the secure iOS application sandbox:

- **Downloaded Files & Media:** Saved directly into your device's sandbox `Documents` directory (or user-selected files/folders via Document Picker). You retain full control to view, export, or delete these files at any time.
- **Application Preferences & Settings:** User preferences (e.g., download concurrency limits, browser search engine choice, player aspect ratio) are stored locally in `UserDefaults` and local JSON storage.
- **Credentials & HTTP Authentication:** Any download credentials, basic authentication tokens, or link-refresh headers are stored strictly in the secure system **iOS Keychain** and are never transmitted to the developer.
- **Browsing History & Bookmarks:** Browsing history and bookmarks are maintained locally on-device. When using Incognito Mode, browsing data, cookies, and cache are discarded upon closing the incognito tab.

---

## 4. Network Connections & Permissions

The application establishes network connections solely at your explicit direction:

- **Direct Download Connections:** When you start a download, the app connects directly to the server host hosting the file or stream. No intermediary proxy server is operated by the developer.
- **BitTorrent Swarm Connections:** When downloading via BitTorrent, the integrated `libtorrent-rasterbar` engine connects directly to peer addresses within the decentralized swarm and configured trackers. Local Network permission (`NSLocalNetworkUsageDescription`) is requested to discover peers on your local Wi-Fi network.
- **In-App Web Browser:** When browsing websites, requests are routed directly to the requested domains via WebKit (`WKWebView`). Ad-blocking and tracking-shield rules execute entirely locally on your device to block known tracking domains.

---

## 5. Apple Privacy Manifest (iOS 17+)

In compliance with Apple's requirements for App Store applications, the app includes an official Privacy Manifest (`PrivacyInfo.xcprivacy`):

- **Tracking (`NSPrivacyTracking`):** `false`. The app does not track users across other companies' apps or websites.
- **Tracking Domains (`NSPrivacyTrackingDomains`):** None (`[]`).
- **Collected Data Types (`NSPrivacyCollectedDataTypes`):** None (`[]`). No personal or usage data is collected.
- **Required Reason APIs (`NSPrivacyAccessedAPITypes`):**
  - **UserDefaults (`CA92.1`):** To store and read local app configuration and user preferences.
  - **File Timestamps (`C617.1`, `3B52.1`):** To inspect and display downloaded file modification dates and handle partial resumption.
  - **Disk Space (`E174.1`):** To verify sufficient free storage capacity before writing download segments.
  - **System Boot Time (`35F9.1`):** To calculate real-time download speeds and duration timers.

---

## 6. Children's Privacy

The application does not collect any personal information from anyone, including children under the age of 13.

---

## 7. Contact & Open Source Verification

Because the project is open source under the MIT License, our implementation and security practices can be independently inspected and audited:

- **GitHub Repository:** [https://github.com/r4m335/SwiftDownloadEngine](https://github.com/r4m335/SwiftDownloadEngine)
- **Issue Tracker & Inquiries:** [https://github.com/r4m335/SwiftDownloadEngine/issues](https://github.com/r4m335/SwiftDownloadEngine/issues)
