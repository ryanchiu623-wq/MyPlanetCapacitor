import Capacitor

/// 對應 Android 版 MainActivity.java 的 registerPlugin() 呼叫。
/// DeviceNetworkPlugin 是這個 App 自己的原生程式碼（不是外部套件），
/// Capacitor 的自動掃描只認得透過 npm 安裝、有 Package.swift 的外部 plugin，
/// app target 內的本地 plugin 一定要在這裡手動註冊一次。
class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(DeviceNetworkPlugin())
    }
}
