import Foundation
import Network
import NetworkExtension
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
public class DeviceNetworkPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "DeviceNetworkPlugin"
    public let jsName = "DeviceNetwork"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getCurrentSsid", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "bindSetupNetwork", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unbindNetwork", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "discoverDevice", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openWifiSettings", returnType: CAPPluginReturnPromise)
    ]

    private static let validateTimeoutSeconds: TimeInterval = 2

    private var browser: NWBrowser?
    private var discoveryTimeoutWorkItem: DispatchWorkItem?
    private var discoveryFinished = true
    private var activeDiscoverCall: CAPPluginCall?

    /// 需要 Xcode target 的 Signing & Capabilities 加上「Access WiFi Information」
    /// （對應 entitlement com.apple.developer.networking.wifi-info），否則會一直拿到 nil。
    @objc func getCurrentSsid(_ call: CAPPluginCall) {
        NEHotspotNetwork.fetchCurrent { network in
            call.resolve(["ssid": network?.ssid ?? ""])
        }
    }

    /// iOS 沒有對應 API，維持跟 www/app.js 的呼叫合約相容（no-op 直接成功）。
    @objc func bindSetupNetwork(_ call: CAPPluginCall) {
        call.resolve()
    }

    @objc func unbindNetwork(_ call: CAPPluginCall) {
        call.resolve()
    }

    @objc func discoverDevice(_ call: CAPPluginCall) {
        let hostnameHint = call.getString("hostnameHint", "myplanet").lowercased()
        let timeoutMs = call.getInt("timeoutMs", 8000)

        stopDiscoveryInternal()
        discoveryFinished = false
        activeDiscoverCall = call

        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: params)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !self.discoveryFinished else { return }
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint,
                   name.lowercased().contains(hostnameHint) {
                    self.resolve(result.endpoint)
                }
            }
        }

        browser.start(queue: .main)

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

    private func resolve(_ endpoint: Network.NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            if case .ready = newState {
                if let remote = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, _) = remote {
                    let ip = "\(host)".components(separatedBy: "%").first ?? "\(host)"
                    connection.cancel()
                    self.validateAndResolve(ip: ip)
                }
            } else if case .failed = newState {
                connection.cancel()
            }
        }
        connection.start(queue: .main)
    }

    /// 打 /api/status 驗證這個 host 真的是 MyPlanet 裝置，避免撞到其他 _http._tcp. 裝置
    private func validateAndResolve(ip: String) {
        guard let url = URL(string: "http://\(ip)/api/status") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.validateTimeoutSeconds

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, let body = String(data: data, encoding: .utf8),
                  body.contains("sensor_normalized") else { return }

            DispatchQueue.main.async {
                guard !self.discoveryFinished else { return }
                self.discoveryFinished = true
                self.discoveryTimeoutWorkItem?.cancel()
                self.stopDiscoveryInternal()
                self.activeDiscoverCall?.resolve(["ip": ip])
                self.activeDiscoverCall = nil
            }
        }.resume()
    }

    private func stopDiscoveryInternal() {
        discoveryTimeoutWorkItem?.cancel()
        discoveryTimeoutWorkItem = nil
        browser?.cancel()
        browser = nil
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
}
