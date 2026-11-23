# App Store Connect App Privacy Questionnaire Answers

This guide contains the precise answers required when completing the **App Privacy** section in Apple App Store Connect for **LID Download Manager** (`com.r4m335.SwiftDownloadEngine`).

---

## High-Level Summary (App Nutrition Label)

| Question | Answer | Details |
| :--- | :--- | :--- |
| **Data Used to Track You** | **None** | No data collected or used for cross-app tracking. |
| **Data Linked to You** | **None** | No user accounts or personal identifiers linked to identity. |
| **Data Not Linked to You** | **None** | No telemetry, analytics, or behavioral data collected. |

---

## Section 1: Data Collection

**Question:** *"Do you or your third-party partners collect data from this app?"*  
**Answer:** **No, we do not collect data from this app.**

### Rationale
- The application does not collect, harvest, or transmit any user data to the developer or any third party.
- All downloads, media playback, browsing history, cookies, credentials, and settings remain strictly on the user's physical device in the sandboxed container.
- No analytics SDKs (such as Firebase, Mixpanel, AppsFlyer) or advertising networks are integrated.

---

## Section 2: Data Tracking

**Question:** *"Do you or your third-party partners use data from this app to track the user across apps and websites owned by other companies?"*  
**Answer:** **No.**

### Details
- `NSPrivacyTracking` in `PrivacyInfo.xcprivacy` is set to `<false/>`.
- The Advertising Identifier (IDFA / App Tracking Transparency framework) is not requested or utilized.
- No tracking domains are contacted (`NSPrivacyTrackingDomains` is empty).

---

## Section 3: Data Types Questionnaire Breakdown

If asked about specific categories of data:

| Category | Collected? | Explanation |
| :--- | :--- | :--- |
| **Contact Info** (Name, Email, Phone, Physical Address) | **No** | No user account creation or contact collection exists. |
| **Health & Fitness** | **No** | Not applicable. |
| **Financial Info** (Payment Info, Credit Info) | **No** | No in-app purchases, payments, or billing info collected. |
| **Location** (Precise or Coarse) | **No** | In-app browser only prompts for location if a user navigates to a webpage requesting geolocation, handled directly by WebKit on-device; never collected by the app developer. |
| **Sensitive Info** | **No** | No sensitive data collected. |
| **Contacts** | **No** | Address book is never accessed. |
| **User Content** (Photos, Videos, Audio, Files) | **No (Not Collected)** | User downloads and imports files locally. The developer cannot access, collect, or view this data. |
| **Browsing History** | **No (Not Collected)** | Browser history is stored in local SQLite/UserDefaults database on-device; never transmitted off-device. |
| **Search History** | **No (Not Collected)** | Search queries are dispatched directly to the search provider selected by the user (e.g. DuckDuckGo); never collected by the app. |
| **Identifiers** (User ID, Device ID) | **No** | No persistent vendor/device identifiers or user accounts created. |
| **Purchases** | **No** | No commercial transaction data collected. |
| **Usage Data** (Product Interaction, Advertising Data) | **No** | Zero telemetry or event tracking frameworks. |
| **Diagnostics** (Crash logs, Performance data) | **No** | Error logs are written only to the local file system for user-initiated inspection; no remote crash reporting service. |

---

## Section 4: Required Reason APIs (Declared in `PrivacyInfo.xcprivacy`)

Apple requires apps that call certain system APIs to declare them along with approved reason codes in `PrivacyInfo.xcprivacy`:

1. **User Defaults (`NSPrivacyAccessedAPICategoryUserDefaults`):**
   - **Reason Code:** `CA92.1`
   - **Purpose:** Access user defaults to read and write application configuration, user preferences (e.g. download limits, browser search engine), and persistent local state.

2. **File Timestamps (`NSPrivacyAccessedAPICategoryFileTimestamp`):**
   - **Reason Codes:** `C617.1`, `3B52.1`
   - **Purpose:** Access modification timestamps of files inside the application's local Documents and Cache containers to display file dates to the user and manage download file resumption.

3. **Disk Space (`NSPrivacyAccessedAPICategoryDiskSpace`):**
   - **Reason Code:** `E174.1`
   - **Purpose:** Query available storage capacity (`volumeAvailableCapacityKey`) to check if sufficient disk space exists before initiating segmented downloads or allocating large files.

4. **System Boot Time (`NSPrivacyAccessedAPICategorySystemBootTime`):**
   - **Reason Code:** `35F9.1`
   - **Purpose:** Measure elapsed time between network transfer events to calculate download speed (KB/s), ETA calculations, and request timeouts.
