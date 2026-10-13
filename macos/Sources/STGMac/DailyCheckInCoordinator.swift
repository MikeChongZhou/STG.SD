import AppKit
import WebKit
import STGCore

@MainActor
final class DailyCheckInCoordinator: NSObject, WKNavigationDelegate {
    private let diagnosticLog: DiagnosticLog
    private var window: NSWindow?
    private var webView: WKWebView?
    private var text = ""
    private var submit = false
    private var injected = false

    init(diagnosticLog: DiagnosticLog) { self.diagnosticLog = diagnosticLog }

    func show(text: String, submit: Bool) {
        self.text = text; self.submit = submit; injected = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "1Point3Acres daily check-in"; window.contentView = web; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        self.window = window; webView = web
        web.load(URLRequest(url: URL(string: "https://www.1point3acres.com/next/daily-checkin")!))
        diagnosticLog.record("browser_opened; submit=\(submit)", category: "daily-checkin")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard submit, !injected else { diagnosticLog.record("page_loaded; automatic_submit=\(submit); url=\(webView.url?.absoluteString ?? "unknown")", category: "daily-checkin"); return }
        injected = true
        let data = try? JSONEncoder().encode(text)
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let script = """
        (() => {
          const note = \(json);
          const buttons = [...document.querySelectorAll('button')];
          const mood = buttons.find(button => button.innerText.includes('开心'));
          const entry = document.querySelector('textarea');
          const submit = buttons.find(button => button.innerText.includes('提交签到'));
          if (!entry || !submit) return 'form_not_found_or_not_logged_in';
          if (mood) mood.click();
          entry.focus(); entry.value = note;
          entry.dispatchEvent(new Event('input', { bubbles: true }));
          entry.dispatchEvent(new Event('change', { bubbles: true }));
          submit.click(); return 'submitted';
        })()
        """
        webView.evaluateJavaScript(script) { [diagnosticLog, text] result, error in
            if let error { diagnosticLog.record("automatic_action_failed; error=\(error.localizedDescription)", category: "daily-checkin") }
            else { diagnosticLog.record("automatic_action; result=\(String(describing: result)); text_length=\(text.count)", category: "daily-checkin") }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        diagnosticLog.record("navigation_failed; error=\(error.localizedDescription)", category: "daily-checkin")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        diagnosticLog.record("navigation_failed; stage=provisional; error=\(error.localizedDescription)", category: "daily-checkin")
    }
}
