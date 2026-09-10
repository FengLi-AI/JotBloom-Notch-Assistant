using System;
using System.Runtime.InteropServices;
using System.Text;
using JotBloom.Windows.Core;
using Forms = System.Windows.Forms;

namespace JotBloom.Windows.Desktop;

internal static class Native
{
    internal const int HotKeyMessage = 0x0312;
    internal const int MouseActivate = 0x0021;
    internal const int ExtendedStyle = -20;
    internal const int WindowStyle = -16;
    internal const long NoActivate = 0x08000000;
    internal const long ToolWindow = 0x00000080;
    [StructLayout(LayoutKind.Sequential)] internal struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll")] internal static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] internal static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] internal static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int length);
    [DllImport("user32.dll")] internal static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] internal static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] internal static extern bool UnregisterHotKey(IntPtr window, int id);
    [DllImport("user32.dll")] internal static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] internal static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] internal static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(Point point, uint flags);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll")] internal static extern bool SetProcessDpiAwarenessContext(IntPtr context);

    internal static DisplayArea DisplayAt(PixelPoint p)
    {
        var screen = Forms.Screen.FromPoint(new System.Drawing.Point(p.X, p.Y));
        return Display(screen);
    }
    internal static DisplayArea Display(Forms.Screen screen)
    {
        var b = screen.Bounds;
        var monitor = MonitorFromPoint(new Point { X = b.Left + b.Width / 2, Y = b.Top + b.Height / 2 }, 2);
        double scale = GetDpiForMonitor(monitor, 0, out uint x, out _) == 0 ? x / 96.0 : 1;
        return new(new(b.Left, b.Top, b.Width, b.Height), scale);
    }
    internal static bool MouseHeld => (GetAsyncKeyState(1) & 0x8000) != 0 || (GetAsyncKeyState(2) & 0x8000) != 0;
    internal static bool IsFullscreen(DisplayArea display, IntPtr ownedWindow)
    {
        var foreground = GetForegroundWindow();
        if (foreground == IntPtr.Zero) return true;
        if (foreground == ownedWindow) return false;
        var className = new StringBuilder(256);
        GetClassName(foreground, className, className.Capacity);
        if (className.ToString() is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd") return false;
        if (!GetWindowRect(foreground, out var r)) return true;
        bool hasCaption = (GetWindowLongPtr(foreground, WindowStyle).ToInt64() & 0x00C00000) != 0;
        // Conservative initial heuristic; games and shell overlays require Windows validation.
        return !hasCaption && r.Left <= display.Bounds.Left && r.Top <= display.Bounds.Top &&
            r.Right >= display.Bounds.Right && r.Bottom >= display.Bounds.Bottom;
    }
    internal static void Place(IntPtr handle, PixelRect rect) =>
        SetWindowPos(handle, new IntPtr(-1), rect.Left, rect.Top, rect.Width, rect.Height, 0x0010);
}
