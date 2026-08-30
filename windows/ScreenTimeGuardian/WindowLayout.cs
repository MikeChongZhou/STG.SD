using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using WinForms = System.Windows.Forms;
using WpfPoint = System.Windows.Point;

namespace ScreenTimeGuardian;

/// <summary>
/// Keeps WPF windows comfortably inside the current monitor's usable area.
/// WPF dimensions are device-independent pixels while Screen.WorkingArea is
/// physical pixels, so the conversion must use the window's per-monitor DPI.
/// </summary>
internal static class WindowLayout
{
    public static void FitToWorkingArea(Window window, double widthFraction = 0.9, double heightFraction = 0.9)
    {
        var desiredWidth = window.Width;
        var desiredHeight = window.Height;

        window.SourceInitialized += (_, _) => Fit(window, desiredWidth, desiredHeight, widthFraction, heightFraction);
        window.DpiChanged += (_, _) => window.Dispatcher.BeginInvoke(() => Fit(window, desiredWidth, desiredHeight, widthFraction, heightFraction));
    }

    private static void Fit(Window window, double desiredWidth, double desiredHeight, double widthFraction, double heightFraction)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero) return;

        var physical = WinForms.Screen.FromHandle(handle).WorkingArea;
        var source = PresentationSource.FromVisual(window);
        var fromDevice = source?.CompositionTarget?.TransformFromDevice ?? Matrix.Identity;
        var topLeft = fromDevice.Transform(new WpfPoint(physical.Left, physical.Top));
        var bottomRight = fromDevice.Transform(new WpfPoint(physical.Right, physical.Bottom));
        var workWidth = Math.Max(1, bottomRight.X - topLeft.X);
        var workHeight = Math.Max(1, bottomRight.Y - topLeft.Y);
        var maximumWidth = Math.Max(360, workWidth * widthFraction);
        var maximumHeight = Math.Max(320, workHeight * heightFraction);

        // A minimum larger than the monitor would override Width/Height and
        // recreate the clipped-footer problem on high-DPI laptop displays.
        window.MinWidth = Math.Min(window.MinWidth, maximumWidth);
        window.MinHeight = Math.Min(window.MinHeight, maximumHeight);
        window.Width = Math.Min(desiredWidth, maximumWidth);
        window.Height = Math.Min(desiredHeight, maximumHeight);
        window.Left = topLeft.X + (workWidth - window.Width) / 2;
        window.Top = topLeft.Y + (workHeight - window.Height) / 2;
    }
}
