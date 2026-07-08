# MyPlanet 瀏覽器（Capacitor 殼層）

用 [Capacitor](https://capacitorjs.com/) 把 MyPlanet 盆栽裝置的網頁控制面板包成
Android / iOS App。App 本身不含面板 UI——面板網頁存在裝置（ESP32）上，
這個 App 只負責**找到裝置、連上它、把它的網頁顯示在 iframe 裡**。

## 運作原理（雙模式連線）

對應韌體 `wifi_fsm.cpp` 的兩種狀態，啟動時自動判斷該連哪個 host：

| 模式 | 判斷條件 | 連線目標 |
|---|---|---|
| 設定熱點模式 | 手機連的 SSID 是 `Plant-Setup` | 固定 IP `192.168.4.1` |
| 家用網路模式 | 手機連其他 WiFi | 用 mDNS/Bonjour 探索 hostname 含 `myplanet` 的裝置，再打 `http://IP/api/status` 驗證回應含 `sensor_normalized` 才採用（避免撞到印表機等其他 `_http._tcp` 裝置） |

沒連 WiFi 時顯示提示畫面，引導使用者去系統設定。

## 資料夾結構

```
MyPlanetCapacitor/
├── capacitor.config.json     # App ID（com.myplanet.browser）、App 名稱、webDir 設定
├── package.json              # Capacitor 8.x 依賴（core / cli / android / ios）
│
├── www/                      # ★ 殼層 UI 原始碼（唯一該手改 UI 的地方）
│   ├── index.html            # 狀態畫面（連線中/錯誤/WiFi 提示）+ 裝置頁 iframe
│   ├── app.js                # 連線判斷邏輯：呼叫 DeviceNetwork plugin、切換畫面
│   └── style.css             # 樣式。注意：font-family 不可用 -apple-system 開頭（見下方「已知問題」）
│
├── android/                  # Android 原生專案（Gradle）
│   └── app/src/main/
│       ├── AndroidManifest.xml                    # 權限：INTERNET、WIFI/NETWORK_STATE、
│       │                                          #   FINE_LOCATION（讀 SSID）、MULTICAST（mDNS）
│       ├── java/com/myplanet/browser/
│       │   ├── MainActivity.java                  # registerPlugin(DeviceNetworkPlugin)
│       │   └── DeviceNetworkPlugin.java           # ★ Android 版原生邏輯
│       ├── res/xml/network_security_config.xml    # 放行明文 HTTP（裝置只有 http）
│       └── assets/public/                         # ⚠ cap sync 從 www/ 複製來的，勿手改
│
├── ios/                      # iOS 原生專案（Xcode，用 SPM 而非 CocoaPods）
│   └── App/
│       ├── App.xcodeproj                          # 開發時開這個檔案（不要只開 ios 資料夾）
│       ├── CapApp-SPM/                            # Capacitor 的 Swift Package 依賴橋接
│       └── App/
│           ├── AppDelegate.swift                  # Capacitor 樣板，未改動
│           ├── MainViewController.swift           # registerPluginInstance(DeviceNetworkPlugin())
│           │                                      #   （iOS 不會自動掃描 app 內的本地 plugin，必須手動註冊）
│           ├── DeviceNetworkPlugin.swift          # ★ iOS 版原生邏輯
│           ├── Info.plist                         # 本機網路/Bonjour/定位用途說明、ATS 本機網路例外
│           ├── App.entitlements                   # Access WiFi Information（讀 SSID 必需）
│           ├── Base.lproj/Main.storyboard         # 進入點改指向 MainViewController
│           └── public/                            # ⚠ cap sync 從 www/ 複製來的，勿手改
│
└── node_modules/             # npm 依賴（不進 git）
```

## DeviceNetworkPlugin：JS ↔ 原生的橋

`www/app.js` 透過 `window.Capacitor.Plugins.DeviceNetwork` 呼叫原生功能，
兩個平台各自實作同一套 API：

| 方法 | 用途 | Android | iOS |
|---|---|---|---|
| `getCurrentSsid()` | 讀目前 WiFi 名稱 | WifiManager + 執行時定位權限 | NEHotspotNetwork + 定位權限 + wifi-info entitlement |
| `bindSetupNetwork()` | 把 App 流量鎖在無網際網路的熱點上，防止系統改走行動網路 | bindProcessToNetwork | **no-op**（iOS 沒有對應 API） |
| `unbindNetwork()` | 解除上面的綁定 | 同上 | no-op |
| `discoverDevice()` | mDNS 探索裝置 IP 並驗證 | NsdManager | NWBrowser |
| `openWifiSettings()` | 開 WiFi 設定頁 | 直接開系統 WiFi 頁 | 只能開本 App 的設定頁（iOS 無公開 API） |

## 開發流程

改了 `www/` 之後，**必須先同步再建置**（各平台的 `public/` 是複製品）：

```bash
npx cap sync          # www/ → android/…/assets/public 與 ios/…/App/public
```

**Android**：用 Android Studio 開 `android/`，或
`cd android && ./gradlew assembleDebug`

**iOS**：用 Xcode 開 `ios/App/App.xcodeproj` 按 Run，或
```bash
cd ios/App
xcodebuild -project App.xcodeproj -scheme App -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## 已知問題與注意事項

- **iOS 26 WebKit 字型 bug**：`font-family` 只要以 `-apple-system` 或
  `system-ui` 開頭，中文全部變缺字方框（後面補 PingFang TC 也沒用）。
  `style.css` 已改用 `'Segoe UI', 'Noto Sans TC', sans-serif`，
  按鈕另加 `font-family: inherit`（button 預設不繼承、會踩同一個坑）。
- **模擬器讀不到 SSID**：`NEHotspotNetwork` 在 iOS 模擬器永遠回 nil，
  所以模擬器只能走到「請先連線 WiFi」畫面；完整流程要用實機測。
- **iOS 實機簽署**：目前用免費 Personal Team 自動簽署。
  wifi-info entitlement 能否在免費帳號下佈署到實機，第一次跑實機時需驗證。
- **裝置 hostname 寫死**：`app.js` 與 iOS/Android 探索邏輯都假設 mDNS
  hostname 含 `myplanet`。若在裝置「本地設定/裝置名稱」改過，要同步改
  `www/app.js` 的 `EXPECTED_MDNS_NAME`。
- **`._*` 檔案**：專案放在外接硬碟，macOS 會產生 AppleDouble 垃圾檔，
  已在 `.gitignore` 排除，不要 commit。

## 相關資料夾（上層 `code/`）

- `MyPlanetBrowser/` + `MyPlanetBrowser.apk`：早期的純原生 Android WebView 版，
  本專案的 Android plugin 邏輯即移植自它。
- `android-kit/`、`ios-kit/`：原生程式碼片段來源。iOS 的
  `DeviceNetworkPlugin.swift` 移植自 `ios-kit/Sources/DeviceConnectionManager.swift`。
- `MyPlant-main/`：裝置韌體原始碼（Pico backend/frontend），
  面板網頁與 `/api/status` 皆由韌體提供。
