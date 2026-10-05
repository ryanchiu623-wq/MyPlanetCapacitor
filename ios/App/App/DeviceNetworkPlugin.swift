import Foundation
import NetworkExtension
import CoreLocation
import UIKit
import Capacitor

/// 對應 Android 版 DeviceNetworkPlugin.java 的邏輯，讓 www/app.js 可以用同一套
/// JS API（getCurrentSsid / bindSetupNetwork / unbindNetwork / discoverDevice /
/// openWifiSettings）操作 iOS。判斷邏輯本身沿用 ios-kit/Sources/DeviceConnectionManager.swift。
///
/// 兩個已知的平台差異（跟 Android 版不同，不是漏做）：
/// - bindSetupNetwork/unbindNetwork：iOS 沒有「bindProcessToNetwork」這種把整個
///   App 網路流量鎖死在特定介面的 API，這裡直接 resolve() 當 no-op。
/// - openWifiSettings：iOS 沒有公開 API 能直接開啟系統 WiFi 設定頁，只能開本 App
///   的設定頁（跟 ios-kit ContentView.swift 的 wifiPromptView 做法一致）。
@objc(DeviceNetworkPlugin)
public class DeviceNetworkPlugin: CAPPlugin, CAPBridgedPlugin, CLLocationManagerDelegate, NetServiceBrowserDelegate, NetServiceDelegate {
    public let identifier = "DeviceNetworkPlugin"
    public let jsName = "DeviceNetwork"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getCurrentSsid", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "bindSetupNetwork", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unbindNetwork", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "discoverDevice", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "probeHost", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openWifiSettings", returnType: CAPPluginReturnPromise)
    ]

    private static let validateTimeoutSeconds: TimeInterval = 2
    private static let resolveTimeoutSeconds: TimeInterval = 5

    private var netServiceBrowser: NetServiceBrowser?
    private var resolvingServices: [NetService] = []
    private var discoveryTimeoutWorkItem: DispatchWorkItem?
    private var discoveryFinished = true
    private var activeDiscoverCall: CAPPluginCall?
    private var activeHostnameHint = ""

    private var locationManager: CLLocationManager?
    private var pendingSsidCall: CAPPluginCall?

    /// 讀取 SSID 需要兩個條件同時成立（缺一都只會拿到 nil）：
    /// 1. entitlement com.apple.developer.networking.wifi-info（App.entitlements）
    /// 2. 使用者授權「使用 App 期間」定位（對應 Android 版的 ACCESS_FINE_LOCATION 執行時權限）
    @objc func getCurrentSsid(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let manager = self.locationManager ?? CLLocationManager()
            self.locationManager = manager
            manager.delegate = self

            if manager.authorizationStatus == .notDetermined {
                self.pendingSsidCall = call
                manager.requestWhenInUseAuthorization()
            } else {
                self.fetchSsid(call)
            }
        }
    }

    private func fetchSsid(_ call: CAPPluginCall) {
        NEHotspotNetwork.fetchCurrent { network in
            call.resolve(["ssid": network?.ssid ?? ""])
        }
    }

    /// 授權對話框關閉後接續原本的 getCurrentSsid 呼叫。
    /// 被拒絕也照樣查一次：fetchCurrent 會回 nil，JS 端拿到空字串，行為跟 Android 版一致。
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined,
              let call = pendingSsidCall else { return }
        pendingSsidCall = nil
        fetchSsid(call)
    }

    /// iOS 沒有對應 API，維持跟 www/app.js 的呼叫合約相容（no-op 直接成功）。
    @objc func bindSetupNetwork(_ call: CAPPluginCall) {
        call.resolve()
    }

    @objc func unbindNetwork(_ call: CAPPluginCall) {
        call.resolve()
    }

    // 原本用 NWBrowser + NWConnection.currentPath?.remoteEndpoint 來拿解析後的 IP，
    // 但這個 trick 在 iOS 上不可靠：很多情況下 remoteEndpoint 永遠停留在
    // .service(...)，不會變成 .hostPort(...)，導致永遠解析不到、一路卡到逾時
    // （這就是實機測試「一直偵測不到裝置」的成因）。
    // 改用成熟穩定的 NetServiceBrowser + NetService.resolve(withTimeout:)，
    // 直接拿 resolved 的位址 bytes，不靠那個不可靠的狀態判斷。
    @objc func discoverDevice(_ call: CAPPluginCall) {
        activeHostnameHint = call.getString("hostnameHint", "myplanet").lowercased()
        let timeoutMs = call.getInt("timeoutMs", 8000)

        stopDiscoveryInternal()
        discoveryFinished = false
        activeDiscoverCall = call

        let browser = NetServiceBrowser()
        browser.delegate = self
        netServiceBrowser = browser
        // 注意：NetServiceBrowser 用的是「結尾有點」的格式："_http._tcp." + "local."
        // 跟 Network.framework 的 NWBrowser Bonjour descriptor 格式不同，別搞混
        browser.searchForServices(ofType: "_http._tcp.", inDomain: "local.")

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self, !self.discoveryFinished else { return }
            self.discoveryFinished = true
            self.stopDiscoveryInternal()
            self.activeDiscoverCall?.reject("device not found")
            self.activeDiscoverCall = nil
        }
        discoveryTimeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timeoutWorkItem)
    }

    /// 把 NetService.addresses 裡的 sockaddr bytes 轉成 IP 字串，優先取 IPv4
    /// （IPv6 常是 fe80:: link-local，組 URL 還要處理 zone id，不值得折騰）
    private static func ipv4Address(from data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard raw.count >= 8 else { return nil }
            let family = raw.load(fromByteOffset: 1, as: UInt8.self)
            guard family == UInt8(AF_INET) else { return nil }

            var addr = raw.load(fromByteOffset: 4, as: in_addr.self)
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return String(cString: buf)
        }
    }

    /// 打 /api/status 驗證這個 host 真的是 MyPlanet 裝置，避免撞到其他 _http._tcp. 裝置
    private static func checkDevice(at ip: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://\(ip)/api/status") else {
            completion(false)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.validateTimeoutSeconds

        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
                && data != nil
                && String(data: data!, encoding: .utf8)?.contains("sensor_normalized") == true
            completion(ok)
        }.resume()
    }

    private func validateAndResolve(ip: String) {
        Self.checkDevice(at: ip) { [weak self] ok in
            guard ok, let self else { return }
            DispatchQueue.main.async {
                guard !self.discoveryFinished else { return }
                self.discoveryFinished = true
                self.discoveryTimeoutWorkItem?.cancel()
                self.stopDiscoveryInternal()
                self.activeDiscoverCall?.resolve(["ip": ip])
                self.activeDiscoverCall = nil
            }
        }
    }

    /// 直接探測指定 IP 是否為 MyPlanet 裝置，不靠 SSID、不靠 mDNS。
    /// 用來在 SSID 讀不到（例如 iOS 免費帳號下 wifi-info entitlement 未生效）時，
    /// 仍能判斷「是不是連在設定熱點 192.168.4.1 上」。
    /// 必須放在原生端：www/app.js 用 fetch() 直接打 192.168.4.1 會被 CORS 擋掉
    /// （ESP32 的 /api/status 沒有送 Access-Control-Allow-Origin），
    /// 原生 URLSession 不受 CORS 限制。
    @objc func probeHost(_ call: CAPPluginCall) {
        let ip = call.getString("ip") ?? "192.168.4.1"
        Self.checkDevice(at: ip) { ok in
            DispatchQueue.main.async {
                call.resolve(["ok": ok])
            }
        }
    }

    private func stopDiscoveryInternal() {
        discoveryTimeoutWorkItem?.cancel()
        discoveryTimeoutWorkItem = nil
        netServiceBrowser?.stop()
        netServiceBrowser = nil
        resolvingServices.forEach { $0.stop() }
        resolvingServices.removeAll()
    }

    /// iOS 沒有公開 API 能直接開啟系統 WiFi 設定頁（不像 Android
    /// Settings.ACTION_WIFI_SETTINGS），只能開啟本 App 的設定頁。
    @objc func openWifiSettings(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
            call.resolve()
        }
    }

    // ── NetServiceBrowser / NetService delegate ───────────────────
    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard !discoveryFinished else { return }
        guard service.name.lowercased().contains(activeHostnameHint) else { return }
        service.delegate = self
        resolvingServices.append(service)
        service.resolve(withTimeout: Self.resolveTimeoutSeconds)
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard !discoveryFinished, let addresses = sender.addresses else { return }
        for data in addresses {
            if let ip = Self.ipv4Address(from: data) {
                validateAndResolve(ip: ip)
            }
        }
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // 這個候選解析失敗，忽略即可，繼續等其他候選或直到逾時
    }
}
