using System.Globalization;
using System.Resources;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;

namespace ScreenTimeGuardian;

internal static class L
{
    private static readonly ResourceManager Resources = new("ScreenTimeGuardian.Resources.Strings", typeof(L).Assembly);
    private static readonly Dictionary<string, string> Keys = new(StringComparer.Ordinal)
    {
        ["Screen Time Guardian"] = "AppTitle", ["Screen Time Guardian Settings"] = "SettingsTitle", ["STG Report"] = "ReportTitle",
        ["Report"] = "Report", ["Tracking"] = "Tracking", ["Settings"] = "Settings", ["About"] = "About", ["Close"] = "Close", ["Close Window"] = "Close",
        ["Save"] = "Save", ["Back"] = "Back", ["Finish"] = "Finish", ["Not Now"] = "NotNow", ["Sync Now"] = "SyncNow",
        ["Daily"] = "Daily", ["Daily report"] = "Daily", ["Multiple Days"] = "MultipleDays", ["Year by Week"] = "YearByWeek", ["Years by Month"] = "YearsByMonth",
        ["Daily Limit"] = "DailyLimit", ["All Devices: "] = "AllDevices", ["This PC: "] = "ThisPC", ["Latest week · Top models"] = "LatestTopModels",
        ["PRIVATE CLOUD"] = "PrivateCloud", ["Current cloud"] = "CurrentCloud", ["Configure…"] = "Configure", ["GENERAL"] = "General", ["REMINDERS"] = "Reminders",
        ["Launch at Windows sign-in"] = "LaunchAtLogin", ["Eye close delay"] = "EyeDelay", ["Posture delay"] = "PostureDelay", ["Daily-limit delay"] = "DailyDelay",
        ["Manual meeting mode — silent and immediately closeable"] = "MeetingMode", ["DIAGNOSTICS"] = "Diagnostics", ["Export Data…"] = "ExportData", ["Export Test Log…"] = "ExportLog",
        ["OpenRouter Tracking"] = "OpenRouterTracking", ["Weekly Trends"] = "WeeklyTrends", ["Top 20 Since Date"] = "Top20", ["Estimated Revenue"] = "EstimatedRevenue",
        ["Export CSV"] = "ExportCSV", ["Refresh"] = "Refresh", ["Set Up Screen Time Guardian"] = "SetupTitle", ["Set Up Private Cloud"] = "SetupCloud",
        ["Connect your private cloud?"] = "ConnectCloudQuestion", ["Start automatically when you sign in?"] = "StartupQuestion",
        ["Screen Time Report"] = "ScreenTimeReport", ["Report date"] = "ReportDate", ["Start"] = "Start", ["End"] = "End", ["From"] = "From", ["Value"] = "Value",
        ["ALL DEVICES  "] = "AllDevicesCaps", ["THIS PC  "] = "ThisPCCaps", ["DAILY LIMIT  "] = "DailyLimitCaps", ["Daily Limit: "] = "DailyLimitWithColon", ["Meeting Mode: "] = "MeetingModeWithColon", ["Meeting auto-detect: "] = "MeetingAutoDetectWithColon",
        ["Export the app database, global settings, or diagnostic events."] = "DiagnosticsDetail", ["Configure private cloud"] = "ConfigureCloud", ["Which devices will share this data?"] = "ShareDevices", ["RECOMMENDATION"] = "Recommendation", ["Provider"] = "Provider", ["Connect account…"] = "ConnectAccount", ["Sign out"] = "SignOut",
        ["through latest completed UTC day"] = "ThroughLatest", ["Updated by the weekly action in incremental sync"] = "WeeklyUpdateDetail",
        ["SCREEN TIME GUARDIAN"] = "AppTitleCaps", ["Copyright © 2026 Fairy Phoenix Foundation."] = "Copyright", ["Third-Party Software Acknowledgments"] = "ThirdParty",
        ["This app records minute-level estimates of screen use, either on this PC alone or across your devices, and reminds you to take breaks."] = "AboutDescription",
        ["Your screen-use data remains on this PC and, if enabled, in your chosen private-cloud account. STG does not send it to the developer or anyone else."] = "AboutPrivacy",
        ["STG estimates screen use from Windows activity signals, so its totals may differ from other system usage statistics."] = "AboutAccuracy",
        ["This app includes SQLite and open-source components from Microsoft .NET. Their original copyright notices and license terms are preserved. All rights remain with their respective owners. STG claims no ownership of these components."] = "AboutThirdPartyBody",
        ["Privacy: "] = "Privacy", ["Accuracy: "] = "Accuracy", ["Version 1.1.8"] = "Version", ["Local + private cloud"] = "LocalPrivateCloud",
        ["Step {0} of {1}"] = "StepOf", ["Private-cloud sync combines screen-use records from your own devices. You can skip this and configure it later."] = "CloudOnboardingDetail", ["Automatic startup keeps minute recording and reminders available after you sign in."] = "StartupOnboardingDetail",
        ["Eye Break"] = "EyeBreak", ["Posture Break"] = "PostureBreak", ["Daily Limit Reached"] = "DailyLimitReached", ["Look 20 feet away for 20 seconds."] = "EyeBreakBody", ["Stand or walk for 4 minutes and rest your eyes."] = "PostureBreakBody", ["You've used your screen for {0}. Take a 5-minute walk."] = "DailyLimitBody", ["Meeting mode: this reminder can be closed immediately."] = "MeetingClose", ["Close available in {0}s"] = "CloseAvailable", ["You can close this reminder now."] = "CanCloseNow"
        ,["On"] = "On", ["Off"] = "Off", ["Single-device mode"] = "SingleDeviceMode", ["Off — single device"] = "OffSingleDevice", ["Not signed in"] = "NotSignedIn", ["Connected through {0}"] = "ConnectedThrough", ["No account — this PC only"] = "NoAccountThisPC", ["Open iCloud for Windows, sign in, and turn on iCloud Drive"] = "OpenICloud", ["Check iCloud Drive…"] = "CheckICloud", ["Reconnect account…"] = "ReconnectAccount"
    };

    public static string T(string english)
    {
        if (!Keys.TryGetValue(english, out var key)) return english;
        return Resources.GetString(key, CultureInfo.CurrentUICulture) ?? english;
    }

    public static string F(string english, params object[] arguments) => string.Format(CultureInfo.CurrentUICulture, T(english), arguments);

    public static void Apply(Window window)
    {
        window.Title = T(window.Title);
        if (window.Content is DependencyObject content) Walk(content);
    }

    private static void Walk(DependencyObject node)
    {
        switch (node)
        {
            case TextBlock text when !string.IsNullOrEmpty(text.Text): text.Text = T(text.Text); break;
            case ContentControl control when control.Content is string value: control.Content = T(value); break;
            case Run run when !string.IsNullOrEmpty(run.Text): run.Text = T(run.Text); break;
        }
        foreach (var child in LogicalTreeHelper.GetChildren(node).OfType<DependencyObject>()) Walk(child);
    }
}
