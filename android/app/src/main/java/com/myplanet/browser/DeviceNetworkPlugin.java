package com.myplanet.browser;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;

/**
 * 對應原生版 MainActivity(Android) 的網路判斷邏輯，包成 Capacitor plugin
 * 讓 www/app.js 可以呼叫。
 *
 * - getCurrentSsid：讀取目前 WiFi SSID（需要 ACCESS_FINE_LOCATION 執行時權限）
 * - bindSetupNetwork / unbindNetwork：綁定/解除「設定熱點」這個無網際網路的 WiFi，
 *   避免系統把流量導去行動網路（跟原生版 MainActivity 的做法完全相同）
 * - discoverDevice：用 NsdManager 找家用網路上的裝置 IP，並打 /api/status 驗證
 * - openWifiSettings：開系統 WiFi 設定頁
 */
@CapacitorPlugin(
    name = "DeviceNetwork",
    permissions = {
        @Permission(strings = { Manifest.permission.ACCESS_FINE_LOCATION }, alias = "location")
    }
)
public class DeviceNetworkPlugin extends Plugin {

    private static final int NETWORK_REQUEST_TIMEOUT_MS = 8000;
    private static final int VALIDATE_TIMEOUT_MS = 2000;

    private Network setupNetwork;
    private ConnectivityManager.NetworkCallback networkCallback;

    private NsdManager.DiscoveryListener discoveryListener;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean discoveryFinished = true;

    @PluginMethod
    public void getCurrentSsid(PluginCall call) {
        if (getPermissionState("location") != com.getcapacitor.PermissionState.GRANTED) {
            requestPermissionForAlias("location", call, "ssidPermsCallback");
            return;
        }
        resolveSsid(call);
    }

    @PermissionCallback
    private void ssidPermsCallback(PluginCall call) {
        if (getPermissionState("location") == com.getcapacitor.PermissionState.GRANTED) {
            resolveSsid(call);
        } else {
            JSObject ret = new JSObject();
            ret.put("ssid", "");
            call.resolve(ret);
        }
    }

    private void resolveSsid(PluginCall call) {
        WifiManager wifiManager = (WifiManager) getContext()
            .getApplicationContext()
            .getSystemService(android.content.Context.WIFI_SERVICE);

        String ssid = "";
        if (wifiManager != null && wifiManager.getConnectionInfo() != null) {
            ssid = wifiManager.getConnectionInfo().getSSID();
            if (ssid != null) {
                ssid = ssid.replace("\"", "");
            }
        }
        if (ssid == null || ssid.equals("<unknown ssid>")) {
            ssid = "";
        }

        JSObject ret = new JSObject();
        ret.put("ssid", ssid);
        call.resolve(ret);
    }

    @PluginMethod
    public void bindSetupNetwork(PluginCall call) {
        ConnectivityManager cm = (ConnectivityManager) getContext()
            .getSystemService(android.content.Context.CONNECTIVITY_SERVICE);

        if (setupNetwork != null) {
            cm.bindProcessToNetwork(setupNetwork);
            call.resolve();
            return;
        }

        NetworkRequest request = new NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build();

        networkCallback = new ConnectivityManager.NetworkCallback() {
            @Override
            public void onAvailable(Network network) {
                setupNetwork = network;
                cm.bindProcessToNetwork(network);
                call.resolve();
            }

            @Override
            public void onLost(Network network) {
                if (network.equals(setupNetwork)) {
                    setupNetwork = null;
                    cm.bindProcessToNetwork(null);
                    notifyListeners("setupNetworkLost", new JSObject());
                }
            }

            @Override
            public void onUnavailable() {
                call.reject("setup network unavailable");
            }
        };

        cm.requestNetwork(request, networkCallback, NETWORK_REQUEST_TIMEOUT_MS);
    }

    @PluginMethod
    public void unbindNetwork(PluginCall call) {
        ConnectivityManager cm = (ConnectivityManager) getContext()
            .getSystemService(android.content.Context.CONNECTIVITY_SERVICE);

        if (networkCallback != null) {
            try {
                cm.unregisterNetworkCallback(networkCallback);
            } catch (Exception ignored) {
            }
            networkCallback = null;
        }
        if (setupNetwork != null) {
            cm.bindProcessToNetwork(null);
            setupNetwork = null;
        }
        call.resolve();
    }

    @PluginMethod
    public void discoverDevice(PluginCall call) {
        String hostnameHint = call.getString("hostnameHint", "myplanet");
        int timeoutMs = call.getInt("timeoutMs", 8000);

        stopDiscoveryInternal();
        discoveryFinished = false;

        NsdManager nsdManager = (NsdManager) getContext()
            .getSystemService(android.content.Context.NSD_SERVICE);

        Runnable timeoutRunnable = () -> {
            if (!discoveryFinished) {
                discoveryFinished = true;
                stopDiscoveryInternal();
                call.reject("device not found");
            }
        };
        handler.postDelayed(timeoutRunnable, timeoutMs);

        discoveryListener = new NsdManager.DiscoveryListener() {
            @Override
            public void onDiscoveryStarted(String serviceType) {}

            @Override
            public void onServiceFound(NsdServiceInfo serviceInfo) {
                if (discoveryFinished) return;
                if (serviceInfo.getServiceName() == null
                    || !serviceInfo.getServiceName().toLowerCase().contains(hostnameHint.toLowerCase())) {
                    return;
                }

                nsdManager.resolveService(serviceInfo, new NsdManager.ResolveListener() {
                    @Override
                    public void onResolveFailed(NsdServiceInfo info, int errorCode) {}

                    @Override
                    public void onServiceResolved(NsdServiceInfo info) {
                        if (discoveryFinished || info.getHost() == null) return;
                        String ip = info.getHost().getHostAddress();

                        new Thread(() -> {
                            if (!discoveryFinished && validateHost(ip)) {
                                discoveryFinished = true;
                                handler.post(() -> {
                                    handler.removeCallbacks(timeoutRunnable);
                                    stopDiscoveryInternal();
                                    JSObject ret = new JSObject();
                                    ret.put("ip", ip);
                                    call.resolve(ret);
                                });
                            }
                        }).start();
                    }
                });
            }

            @Override
            public void onServiceLost(NsdServiceInfo serviceInfo) {}

            @Override
            public void onDiscoveryStopped(String serviceType) {}

            @Override
            public void onStartDiscoveryFailed(String serviceType, int errorCode) {
                if (!discoveryFinished) {
                    discoveryFinished = true;
                    handler.removeCallbacks(timeoutRunnable);
                    call.reject("start discovery failed: " + errorCode);
                }
            }

            @Override
            public void onStopDiscoveryFailed(String serviceType, int errorCode) {}
        };

        nsdManager.discoverServices("_http._tcp.", NsdManager.PROTOCOL_DNS_SD, discoveryListener);
    }

    /** 打 /api/status 驗證這個 host 真的是 MyPlanet 裝置，避免撞到其他 _http._tcp. 裝置 */
    private boolean validateHost(String ip) {
        try {
            URL url = new URL("http://" + ip + "/api/status");
            HttpURLConnection conn = (HttpURLConnection) url.openConnection();
            conn.setConnectTimeout(VALIDATE_TIMEOUT_MS);
            conn.setReadTimeout(VALIDATE_TIMEOUT_MS);
            conn.setRequestMethod("GET");

            boolean ok = conn.getResponseCode() == 200;
            String body = "";
            if (ok) {
                StringBuilder sb = new StringBuilder();
                BufferedReader reader = new BufferedReader(new InputStreamReader(conn.getInputStream()));
                String line;
                while ((line = reader.readLine()) != null) sb.append(line);
                reader.close();
                body = sb.toString();
            }
            conn.disconnect();
            return ok && body.contains("sensor_normalized");
        } catch (Exception e) {
            return false;
        }
    }

    private void stopDiscoveryInternal() {
        if (discoveryListener != null) {
            NsdManager nsdManager = (NsdManager) getContext()
                .getSystemService(android.content.Context.NSD_SERVICE);
            try {
                nsdManager.stopServiceDiscovery(discoveryListener);
            } catch (Exception ignored) {
            }
            discoveryListener = null;
        }
    }

    @PluginMethod
    public void openWifiSettings(PluginCall call) {
        Intent intent = new Intent(Settings.ACTION_WIFI_SETTINGS);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        getContext().startActivity(intent);
        call.resolve();
    }
}
