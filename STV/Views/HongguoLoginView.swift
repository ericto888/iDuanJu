import SwiftUI
import UIKit
import WebKit

/// Native QR login sheet for 红果短剧 (mirrors Android's `HongguoLoginScreen.kt`).
/// Drives a hidden desktop-mode `WKWebView` on `https://hongguoduanju.com`, extracts the QR image via JS bridge,
/// and polls `HongguoWebAccount.shared.refreshProfile()` until login succeeds.
struct HongguoLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var account = HongguoWebAccount.shared
    @State private var qrImage: UIImage?
    @State private var qrStatus: String = "loading"
    @State private var refreshNonce = 0
    @State private var checkNonce = 0
    @State private var saveNotice: String?
    @State private var loggedInName: String?

    var body: some View {
        NavigationStack {
            ZStack {
                // Keep WKWebView at full opacity (covered by opaque STVTheme.bg) so iOS WebKit does not
                // freeze or throttle its QR-polling timers when returning from the Hongguo app.
                HongguoQRWebView(
                    refreshNonce: refreshNonce,
                    checkNonce: checkNonce,
                    onQrUpdate: { dataURL, status in
                        qrStatus = status
                        if let img = Self.decodeDataURL(dataURL) {
                            qrImage = img
                        }
                    },
                    onLoggedIn: { nickname, avatarUrl in
                        guard loggedInName == nil else { return }
                        loggedInName = nickname
                        Task {
                            await account.acceptWebViewLogin(nickname: nickname, avatarUrl: avatarUrl)
                            try? await Task.sleep(for: .milliseconds(600))
                            dismiss()
                        }
                    }
                )
                .frame(width: 1280, height: 900)
                .allowsHitTesting(false)

                STVTheme.bg.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        VStack(spacing: 6) {
                            Text("红果短剧扫码登录")
                                .font(.title2.weight(.heavy))
                                .foregroundStyle(STVTheme.text)
                            Text("使用红果短剧 App 扫描下方二维码，同步本机观看进度")
                                .font(.subheadline)
                                .foregroundStyle(STVTheme.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 12)

                        // QR card
                        VStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white)
                                    .frame(width: 224, height: 224)

                                if let loggedInName {
                                    VStack(spacing: 10) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 48))
                                            .foregroundStyle(.green)
                                        Text("已登录：\(loggedInName)")
                                            .font(.headline)
                                            .foregroundStyle(.black)
                                    }
                                } else if let qrImage {
                                    Image(uiImage: qrImage)
                                        .interpolation(.none)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 200, height: 200)
                                        .opacity(qrStatus == "expired" ? 0.25 : 1)

                                    if qrStatus == "expired" {
                                        Button {
                                            qrStatus = "loading"
                                            refreshNonce += 1
                                        } label: {
                                            VStack(spacing: 6) {
                                                Image(systemName: "arrow.clockwise.circle.fill")
                                                    .font(.system(size: 36))
                                                Text("二维码已过期\n点击刷新")
                                                    .font(.caption.weight(.semibold))
                                                    .multilineTextAlignment(.center)
                                            }
                                            .foregroundStyle(.black)
                                            .padding(14)
                                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                                        }
                                    }
                                } else {
                                    VStack(spacing: 10) {
                                        ProgressView().tint(.gray)
                                        Text("正在获取二维码…")
                                            .font(.caption)
                                            .foregroundStyle(.gray)
                                    }
                                }
                            }

                            Text(statusLabel)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(qrStatus == "scanned" ? STVTheme.accent : STVTheme.secondary)
                        }
                        .padding(22)
                        .frame(maxWidth: 320)
                        .background(STVTheme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(STVTheme.hairline, lineWidth: 1))

                        HStack(spacing: 12) {
                            Button {
                                qrStatus = "loading"
                                refreshNonce += 1
                            } label: {
                                Label("刷新二维码", systemImage: "arrow.clockwise")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(STVTheme.surface, in: Capsule())
                            }
                            .foregroundStyle(STVTheme.text)

                            if let qrImage {
                                Button {
                                    UIImageWriteToSavedPhotosAlbum(qrImage, nil, nil, nil)
                                    saveNotice = "已保存二维码到相册，可在红果短剧 App 内相册扫码"
                                } label: {
                                    Label("保存到相册", systemImage: "square.and.arrow.down")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(STVTheme.accent, in: Capsule())
                                }
                                .foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: 320)

                        if let saveNotice {
                            Text(saveNotice)
                                .font(.caption)
                                .foregroundStyle(STVTheme.accent)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }

                        if loggedInName == nil && qrImage != nil {
                            Button {
                                checkNonce += 1
                                Task {
                                    if let p = await account.refreshProfile() {
                                        loggedInName = p.nickname
                                        try? await Task.sleep(for: .milliseconds(600))
                                        dismiss()
                                    } else {
                                        saveNotice = "正在同步登录状态，若刚在红果确认请稍等 1-2 秒再点一次"
                                    }
                                }
                            } label: {
                                Text("我已扫码确认，立即检查登录状态")
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(STVTheme.accent)
                                    .padding(.vertical, 6)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active, loggedInName == nil {
                    checkNonce += 1
                    Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled, loggedInName == nil else { return }
                        if let p = await account.refreshProfile() {
                            loggedInName = p.nickname
                            try? await Task.sleep(for: .milliseconds(600))
                            dismiss()
                        }
                    }
                }
            }
            .task {
                while !Task.isCancelled && loggedInName == nil {
                    try? await Task.sleep(for: .milliseconds(2500))
                    guard !Task.isCancelled else { break }
                    checkNonce += 1
                    if let p = await account.refreshProfile() {
                        loggedInName = p.nickname
                        try? await Task.sleep(for: .milliseconds(700))
                        dismiss()
                        break
                    }
                }
            }
        }
    }

    private var statusLabel: String {
        if loggedInName != nil { return "登录成功，正在返回…" }
        switch qrStatus {
        case "scanned": return "已扫描，请在红果短剧 App 上确认登录"
        case "expired": return "二维码已过期，请点击刷新"
        case "ready": return "打开红果短剧 App 扫一扫"
        default: return "正在连接红果短剧网页登录…"
        }
    }

    private static func decodeDataURL(_ s: String) -> UIImage? {
        guard let comma = s.firstIndex(of: ",") else { return nil }
        let b64 = String(s[s.index(after: comma)...])
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)
    }
}

private struct HongguoQRWebView: UIViewRepresentable {
    let refreshNonce: Int
    let checkNonce: Int
    let onQrUpdate: (String, String) -> Void
    let onLoggedIn: (String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onQrUpdate: onQrUpdate, onLoggedIn: onLoggedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "idjLogin")
        ucc.addUserScript(WKUserScript(source: Self.bridgeJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let cfg = WKWebViewConfiguration()
        cfg.userContentController = ucc
        cfg.websiteDataStore = .default()
        cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: cfg)
        wv.customUserAgent = HongguoWebAccount.pcUserAgent
        wv.navigationDelegate = context.coordinator
        context.coordinator.webView = wv
        if let url = URL(string: HongguoWebAccount.webOrigin) {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if context.coordinator.lastNonce != refreshNonce {
            context.coordinator.lastNonce = refreshNonce
            uiView.evaluateJavaScript("window.__idjActions && window.__idjActions.refreshQr();", completionHandler: nil)
        }
        if context.coordinator.lastCheckNonce != checkNonce {
            context.coordinator.lastCheckNonce = checkNonce
            uiView.evaluateJavaScript("window.__idjActions && window.__idjActions.checkLogin();", completionHandler: nil)
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "idjLogin")
        uiView.stopLoading()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onQrUpdate: (String, String) -> Void
        let onLoggedIn: (String, String) -> Void
        weak var webView: WKWebView?
        var lastNonce = 0
        var lastCheckNonce = 0

        init(onQrUpdate: @escaping (String, String) -> Void, onLoggedIn: @escaping (String, String) -> Void) {
            self.onQrUpdate = onQrUpdate
            self.onLoggedIn = onLoggedIn
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "idjLogin",
                  let dict = message.body as? [String: Any] else { return }
            if (dict["loggedIn"] as? Bool) == true {
                let nickname = dict["nickname"] as? String ?? ""
                let avatarUrl = dict["avatarUrl"] as? String ?? ""
                if !nickname.isEmpty {
                    DispatchQueue.main.async { [onLoggedIn] in
                        onLoggedIn(nickname, avatarUrl)
                    }
                }
                return
            }
            let src = dict["qrSrc"] as? String ?? ""
            let status = dict["qrStatus"] as? String ?? "loading"
            DispatchQueue.main.async { [onQrUpdate] in
                onQrUpdate(src, status)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(HongguoQRWebView.bridgeJS, completionHandler: nil)
        }
    }

    private static let bridgeJS: String = """
    (function() {
      try {
        function isElVisible(el) {
          if (!el) return false;
          if (el.offsetWidth <= 0 || el.offsetHeight <= 0) return false;
          var cs = getComputedStyle(el);
          return cs.display !== 'none' && cs.visibility !== 'hidden' && cs.opacity !== '0';
        }
        function findDialog() {
          return document.querySelector('[role="dialog"], [class*="pc-login-dialog"]');
        }
        function checkProfileInWebView() {
          if (window.__idjLoggedInNotified) return;
          fetch('/api/pc/profile', { credentials: 'include', headers: { 'Accept': 'application/json' } })
            .then(function(r) { return r.ok ? r.json() : null; })
            .then(function(j) {
              var p = j && j.profile;
              var nick = p && (p.nickname || p.name || '').trim();
              if (nick) {
                window.__idjLoggedInNotified = true;
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.idjLogin) {
                  window.webkit.messageHandlers.idjLogin.postMessage({
                    loggedIn: true,
                    nickname: nick,
                    avatarUrl: (p.avatarUrl || p.avatar_url || '').trim()
                  });
                }
              }
            })
            .catch(function() {});
        }
        window.__idjActions = {
          refreshQr: function() {
            var dlg = findDialog();
            if (dlg) {
              var mask = dlg.querySelector('.web-login-scan-code__content__qrcode-wrapper__mask, [class*="qrcode-wrapper__mask"]');
              if (mask && isElVisible(mask)) {
                mask.click();
                var innerBtn = mask.querySelector('button, [role="button"], svg, span');
                if (innerBtn) innerBtn.click();
                return 'clicked';
              }
            }
            location.reload();
            return 'reloaded';
          },
          checkLogin: function() {
            checkProfileInWebView();
          }
        };
        if (window.__idjLoginOpenTimer) clearInterval(window.__idjLoginOpenTimer);
        var openTries = 0;
        window.__idjLoginOpenTimer = setInterval(function() {
          openTries++;
          try {
            var dlg = findDialog();
            var rect = dlg ? dlg.getBoundingClientRect() : null;
            if (dlg && rect.width > 0 && rect.height > 0) {
              clearInterval(window.__idjLoginOpenTimer);
              window.__idjLoginOpenTimer = null;
              return;
            }
            if (openTries % 2 === 1) {
              var selectors = ['button', 'a, [role="button"]', 'span, div'];
              var clicked = false;
              for (var s = 0; s < selectors.length && !clicked; s++) {
                var btns = document.querySelectorAll(selectors[s]);
                for (var i = 0; i < btns.length; i++) {
                  if ((btns[i].textContent || '').trim() === '登录') {
                    btns[i].click();
                    clicked = true;
                    break;
                  }
                }
              }
            }
          } catch (e) {}
          if (openTries >= 40) {
            clearInterval(window.__idjLoginOpenTimer);
            window.__idjLoginOpenTimer = null;
          }
        }, 500);
        window.__idjLastQrKey = null;
        if (window.__idjStateObserver) clearInterval(window.__idjStateObserver);
        window.__idjStateObserver = setInterval(function() {
          try {
            var dlg = findDialog();
            var qrSrc = '';
            var qrStatus = 'loading';
            if (dlg) {
              var imgs = dlg.querySelectorAll('img');
              for (var i = 0; i < imgs.length; i++) {
                var im = imgs[i];
                var src = im.getAttribute('src') || im.src || '';
                if (src.indexOf('data:image/') === 0 && (im.naturalWidth >= 100 || !!im.closest('.web-login-scan-code') || (im.alt || '').indexOf('二维码') >= 0)) {
                  qrSrc = src;
                  break;
                }
              }
              if (!qrSrc) {
                var canvas = dlg.querySelector('.web-login-scan-code canvas');
                if (canvas && canvas.width >= 100) {
                  try { qrSrc = canvas.toDataURL('image/png'); } catch (ce) {}
                }
              }
              var dlgText = dlg.textContent || '';
              var mask = dlg.querySelector('.web-login-scan-code__content__qrcode-wrapper__mask, [class*="qrcode-wrapper__mask"]');
              if (dlgText.indexOf('已扫描') >= 0 || dlgText.indexOf('请在手机') >= 0) {
                qrStatus = 'scanned';
              } else if (isElVisible(mask) || dlgText.indexOf('点击刷新') >= 0 || dlgText.indexOf('已过期') >= 0 || dlgText.indexOf('二维码失效') >= 0) {
                qrStatus = 'expired';
              } else if (qrSrc) {
                qrStatus = 'ready';
              }
            }
            var qrKey = qrStatus + '|' + qrSrc;
            if (qrKey !== window.__idjLastQrKey) {
              window.__idjLastQrKey = qrKey;
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.idjLogin) {
                window.webkit.messageHandlers.idjLogin.postMessage({ qrSrc: qrSrc, qrStatus: qrStatus });
              }
            }
            checkProfileInWebView();
          } catch (e) {}
        }, 1200);
        if (!window.__idjVisBound) {
          window.__idjVisBound = true;
          document.addEventListener('visibilitychange', function() {
            if (!document.hidden) checkProfileInWebView();
          });
        }
      } catch (e) {}
    })();
    """
}
