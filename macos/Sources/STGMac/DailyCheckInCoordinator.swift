import Foundation
import STGCore

/// Uses the user's existing Chrome profile, so it never reads, exports, or stores browser cookies.
@MainActor
final class DailyCheckInCoordinator {
    private let diagnosticLog: DiagnosticLog
    private let checkInURL = "https://www.1point3acres.com/next/daily-checkin"

    init(diagnosticLog: DiagnosticLog) { self.diagnosticLog = diagnosticLog }

    func checkIn(mood: String, note: String, trigger: String, submit: Bool = true, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        diagnosticLog.record("chrome automation requested; trigger=\(trigger); submit=\(submit); mood=\(mood); note_length=\(note.count)", category: "daily-checkin")
        let script = appleScript(mood: mood, note: note, submit: submit)
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
                let confirmed = status == 0 && message == "already_checked_in"
                Task { @MainActor in completion(confirmed) }
            } catch {
                log.record("chrome automation failed; trigger=\(trigger); error=\(error.localizedDescription)", category: "daily-checkin")
                Task { @MainActor in completion(false) }
            }
        }
    }

    private func appleScript(mood: String, note: String, submit: Bool) -> String {
        let payload = try? JSONEncoder().encode(CheckInPayload(mood: mood, note: note, submit: submit))
        let base64 = payload?.base64EncodedString() ?? ""
        let javascript = """
        (() => {
          const bytes = Uint8Array.from(atob('\(base64)'), character => character.charCodeAt(0));
          const payload = JSON.parse(new TextDecoder('utf-8').decode(bytes));
          const buttons = [...document.querySelectorAll('button')];
          if (payload.submit && buttons.some(button => button.innerText.includes('今日已签到'))) return 'already_checked_in';
          if (window.__stgCheckInPending) return 'pending_confirmation';
          const entry = document.querySelector('textarea[name="todaysay"]');
          const mood = buttons.find(button => button.innerText.trim() === payload.mood);
          const submit = buttons.find(button => button.innerText.includes('提交签到') || button.innerText.includes('今日已签到'));
          if (!entry || !mood || !submit) return 'form_not_ready_or_not_logged_in';
          mood.click();
          if (!mood.classList.contains('bg-primary-soft')) return 'mood_not_selected';
          const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
          setter.call(entry, payload.note);
          entry.dispatchEvent(new Event('input', {bubbles:true}));
          entry.dispatchEvent(new Event('change', {bubbles:true}));
          if (entry.value !== payload.note) return 'form_not_ready';
          if (!payload.submit) return 'prepared_without_submitting';
          if (submit.disabled) return 'form_not_ready';
          window.__stgCheckInPending = true;
          submit.click(); return 'submission_clicked';
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
            if resultText contains "already_checked_in" then return resultText
            if resultText contains "prepared_without_submitting" then return resultText
            if resultText contains "mood_not_selected" then return resultText
          end repeat
          return "submission_not_confirmed_after_30_seconds"
        end tell
        """
    }

    private struct CheckInPayload: Encodable {
        let mood: String
        let note: String
        let submit: Bool
    }
}
