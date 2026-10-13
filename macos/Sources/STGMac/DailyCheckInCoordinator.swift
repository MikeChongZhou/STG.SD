import Foundation
import STGCore

/// Uses the user's existing Chrome profile, so it never reads, exports, or stores browser cookies.
@MainActor
final class DailyCheckInCoordinator {
    private let diagnosticLog: DiagnosticLog
    private let checkInURL = "https://www.1point3acres.com/next/daily-checkin"

    init(diagnosticLog: DiagnosticLog) { self.diagnosticLog = diagnosticLog }

    func checkIn(mood: String, note: String, trigger: String) {
        diagnosticLog.record("chrome automation requested; trigger=\(trigger); mood=\(mood); note_length=\(note.count)", category: "daily-checkin")
        let script = appleScript(mood: mood, note: note)
        let log = diagnosticLog
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let output = Pipe(); process.standardOutput = output; process.standardError = output
            do {
                try process.run(); process.waitUntilExit()
                let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let status = process.terminationStatus
                log.record("chrome automation complete; trigger=\(trigger); exit=\(status); result=\(message.isEmpty ? "none" : message)", category: "daily-checkin")
            } catch {
                log.record("chrome automation failed; trigger=\(trigger); error=\(error.localizedDescription)", category: "daily-checkin")
            }
        }
    }

    private func appleScript(mood: String, note: String) -> String {
        let payload = try? JSONEncoder().encode(["mood": mood, "note": note])
        let base64 = payload?.base64EncodedString() ?? ""
        let javascript = """
        (() => {
          const payload = JSON.parse(atob('\(base64)'));
          const buttons = [...document.querySelectorAll('button')];
          const entry = document.querySelector('textarea');
          const mood = buttons.find(button => button.innerText.includes(payload.mood));
          const submit = buttons.find(button => button.innerText.includes('提交签到'));
          if (!entry || !mood || !submit) return 'form_not_ready_or_not_logged_in';
          mood.click(); entry.focus(); entry.value = payload.note;
          entry.dispatchEvent(new Event('input', {bubbles:true})); entry.dispatchEvent(new Event('change', {bubbles:true}));
          submit.click(); return 'submitted';
        })()
        """.replacingOccurrences(of: "\n", with: " ")
        let escaped = javascript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Google Chrome"
          activate
          if (count of windows) = 0 then make new window
          set targetTab to make new tab at end of tabs of front window with properties {URL:"\(checkInURL)"}
          set active tab of front window to targetTab
          repeat with attempt from 1 to 30
            delay 1
            tell active tab of front window
              set resultText to execute javascript "\(escaped)"
            end tell
            if resultText contains "submitted" then return resultText
          end repeat
          return "form_not_ready_or_not_logged_in_after_30_seconds"
        end tell
        """
    }
}
