// MyPlanet 瀏覽器殼層邏輯。
// 對應原生版 MainActivity(Android) / DeviceConnectionManager(iOS) 的判斷邏輯，
// 差別是這裡透過自訂 Capacitor plugin "DeviceNetwork" 呼叫原生的
// SSID 讀取 / 網路綁定 / mDNS 探索，網頁本身只負責畫面狀態切換與 iframe。
//
// 已知限制（跟使用者確認過，接受這個取捨）：
// iframe 裡的裝置網頁是不同來源（cross-origin），外層這支 JS 沒辦法讀取/控制
// iframe 內部的瀏覽歷史，所以無法實作「硬體返回鍵走 iframe 上一頁」或
// 「手勢下拉刷新」，改用固定的「重新整理」按鈕取代。

(function () {
  const DeviceNetwork = window.Capacitor?.Plugins?.DeviceNetwork;

  const SETUP_SSID = 'Plant-Setup';
  const SETUP_HOST = '192.168.4.1';
  // 韌體預設 mDNS hostname（buildMdnsHostname() 預設值）。
  // 若在「本地設定 / 裝置名稱」改過，這裡要跟著改
  const EXPECTED_MDNS_NAME = 'myplanet';
  const DISCOVERY_TIMEOUT_MS = 8000;

  const frame = document.getElementById('device-frame');
  const connectingView = document.getElementById('connecting-view');
  const connectingMessage = document.getElementById('connecting-message');
  const errorView = document.getElementById('error-view');
  const errorMessage = document.getElementById('error-message');
  const wifiPromptView = document.getElementById('wifi-prompt-view');
  const retryButton = document.getElementById('retry-button');
  const openSettingsButton = document.getElementById('open-settings-button');
  const reloadFab = document.getElementById('reload-fab');

  let mode = 'unknown'; // 'unknown' | 'setupAP' | 'homeWifi'
  let currentHost = null;

  function showOnly(view) {
    [connectingView, errorView, wifiPromptView].forEach(v => v.classList.add('hidden'));
    frame.classList.add('hidden');
    reloadFab.classList.add('hidden');
    if (view) view.classList.remove('hidden');
  }

  function showConnecting(message) {
    connectingMessage.textContent = message;
    showOnly(connectingView);
  }

  function showError(message) {
    errorMessage.textContent = message;
    showOnly(errorView);
  }

  function showWifiPrompt() {
    showOnly(wifiPromptView);
  }

  function showDevice(host) {
    currentHost = host;
    frame.src = `http://${host}/`;
    showOnly(null);
    frame.classList.remove('hidden');
    reloadFab.classList.remove('hidden');
  }

  function reloadDevice() {
    if (currentHost) {
      frame.src = `http://${currentHost}/?_=${Date.now()}`;
    }
  }

  reloadFab.addEventListener('click', reloadDevice);

  async function checkAndRoute() {
    if (!DeviceNetwork) {
      showError('原生外掛尚未載入（DeviceNetwork plugin 未註冊）');
      return;
    }

    let ssid = '';
    try {
      const result = await DeviceNetwork.getCurrentSsid();
      ssid = (result && result.ssid) || '';
    } catch (e) {
      // 讀取失敗（例如權限被拒絕）視同沒有 WiFi
      ssid = '';
    }

    if (!ssid) {
      mode = 'unknown';
      showWifiPrompt();
      return;
    }

    if (ssid.toLowerCase() === SETUP_SSID.toLowerCase()) {
      if (mode === 'setupAP') return;
      mode = 'setupAP';
      showConnecting('正在連線到裝置設定熱點…');
      try {
        await DeviceNetwork.bindSetupNetwork();
        showDevice(SETUP_HOST);
      } catch (e) {
        showError('無法綁定裝置設定熱點的連線，請確認手機仍連在 Plant-Setup');
      }
    } else {
      if (mode === 'homeWifi') return;
      mode = 'homeWifi';
      await DeviceNetwork.unbindNetwork().catch(() => {});
      showConnecting('正在家用網路上尋找裝置…');
      try {
        const result = await DeviceNetwork.discoverDevice({
          hostnameHint: EXPECTED_MDNS_NAME,
          timeoutMs: DISCOVERY_TIMEOUT_MS
        });
        if (result && result.ip) {
          showDevice(result.ip);
        } else {
          throw new Error('not found');
        }
      } catch (e) {
        showError(
          '在目前 WiFi 網路上找不到裝置。\n' +
          '請確認手機與裝置在同一個 WiFi，或裝置是否仍在初始設定中（改連 Plant-Setup 熱點）'
        );
      }
    }
  }

  retryButton.addEventListener('click', () => {
    mode = 'unknown';
    checkAndRoute();
  });

  openSettingsButton.addEventListener('click', () => {
    DeviceNetwork?.openWifiSettings?.().catch(() => {});
  });

  // App 回到前景時重新檢查一次目前連線狀態
  document.addEventListener('resume', checkAndRoute, false);

  // 沒有 Capacitor 的「resume」事件（例如純瀏覽器測試）時，用 visibilitychange 兜底
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') checkAndRoute();
  });

  document.addEventListener('deviceready', checkAndRoute, false);
  // 保險：若 deviceready 已經錯過（理論上不會），DOM ready 時也嘗試一次
  if (window.Capacitor) {
    checkAndRoute();
  }
})();
