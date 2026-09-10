using System;
using System.Threading;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;
using JotBloom.Windows.Core;
using JotBloom.Windows.Storage;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace JotBloom.Windows.Desktop;

internal static class Program
{
    internal const string InstanceName=@"Local\JotBloom.Windows";
    [STAThread]
    public static void Main(string[] args)
    {
        if(!Environment.Is64BitProcess||!OperatingSystem.IsWindowsVersionAtLeast(10,0,19045)){MessageBox.Show("萌生需要 Windows 10 22H2 或 Windows 11 的 64 位系统。","萌生");return;}
        Native.SetProcessDpiAwarenessContext(new IntPtr(-4));
        using var activation=new EventWaitHandle(false,EventResetMode.AutoReset,InstanceName+".Activate");
        using var mutex=new Mutex(true,InstanceName,out bool first);
        if(!first){activation.Set();return;}
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};
        EntryHost? host=null;BloomStore? store=null;AppRuntime? runtime=null;
        app.Startup+=async(_,_)=>{
            try{
                string control=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"JotBloom","Windows");
                Directory.CreateDirectory(control);PrivateDirectory.Restrict(control);
                var location=new DataLocation(Path.Combine(control,"Location"));string? directory=null;
                try{directory=await Task.Run(location.Resolve);}
                catch(Exception e){
                    if(MessageBox.Show("原数据位置暂不可用。可以选择原目录或同一份数据的完整备份重新连接。\n"+e.Message,"萌生 · 恢复数据位置",MessageBoxButton.OKCancel,MessageBoxImage.Warning)!=MessageBoxResult.OK){app.Shutdown();return;}
                    var reconnect=new OpenFolderDialog{Title="选择原 JotBloom 数据目录或完整备份"};if(reconnect.ShowDialog()!=true){app.Shutdown();return;}directory=await Task.Run(()=>location.Reconnect(reconnect.FolderName));
                }
                bool firstSetup=directory is null;
                while(directory is null){
                    var picker=new OpenFolderDialog{Title="选择萌生数据的保存位置（将在其中新建 JotBloom 文件夹）"};if(picker.ShowDialog()!=true){app.Shutdown();return;}
                    try{directory=await Task.Run(()=>location.Create(picker.FolderName));}
                    catch(Exception e){MessageBox.Show("无法完成设置。"+e.Message,"萌生 · 存储位置",MessageBoxButton.OK,MessageBoxImage.Warning);directory=await Task.Run(location.Resolve);}
                }
                if(firstSetup&&new DriveInfo(Path.GetPathRoot(directory)!).DriveFormat=="NTFS")PrivateDirectory.Restrict(directory);
                store=await BloomStore.OpenAsync(directory);runtime=new AppRuntime(store,location,control);host=new EntryHost(app,runtime,activation);
                if(firstSetup||!args.Contains("--background"))host.OpenFromTray();
            }catch(Exception e){MessageBox.Show("萌生未能启动。原数据和设置已保留。\n"+e.Message,"萌生",MessageBoxButton.OK,MessageBoxImage.Warning);app.Shutdown();}
        };
        app.Run();host?.Dispose();runtime?.Dispose();if(store is not null)store.DisposeAsync().AsTask().GetAwaiter().GetResult();
        bool restart=runtime?.RestartRequested==true;mutex.ReleaseMutex();if(restart&&Environment.ProcessPath is string path)System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path){UseShellExecute=true});
    }
}

internal sealed class EntryHost : IDisposable
{
    private readonly Application app;
    private readonly TopEdgeController state = new();
    private readonly HintWindow hint = new();
    private readonly PanelWindow panel;
    private readonly Forms.NotifyIcon tray;
    private readonly DispatcherTimer timer;
    private readonly HwndSource messages;
    private bool hotKeyRegistered;
    private int hotkeyId=1;
    private Hotkey registeredShortcut=new();
    private readonly AppRuntime runtime;
    private bool exitPending,hidePending;
    private readonly RegisteredWaitHandle activationWait;
    private IntPtr previousForeground;
    private EntryState renderedState;
    private DisplayArea? renderedDisplay;
    private bool switching, sessionLocked, sleeping, disposed;
    private bool suspended => sessionLocked || sleeping;

    internal EntryHost(Application app, AppRuntime runtime, EventWaitHandle activation)
    {
        this.app = app;this.runtime=runtime;
        panel = new PanelWindow(runtime);
        messages = new HwndSource(new HwndSourceParameters("JotBloom.Windows.Messages") { ParentWindow = new IntPtr(-3) });
        messages.AddHook(MessageHook);
        // MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, Space.
        hotKeyRegistered = Native.RegisterHotKey(messages.Handle,hotkeyId,runtime.Settings.Shortcut.Modifiers|0x4000,runtime.Settings.Shortcut.Key);
        registeredShortcut=runtime.Settings.Shortcut;runtime.RegisterShortcut=RegisterShortcut;
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("打开萌生", null, (_, _) => app.Dispatcher.Invoke(OpenFromTray));
        menu.Items.Add("设置",null,(_,_)=>app.Dispatcher.InvokeAsync(async()=>{OpenFromTray();await panel.NavigateAsync("settings");}));
        menu.Items.Add("退出萌生",null,(_,_)=>app.Dispatcher.InvokeAsync(ExitAsync));
        tray=new Forms.NotifyIcon{Icon=System.Drawing.Icon.ExtractAssociatedIcon(Environment.ProcessPath!)??System.Drawing.SystemIcons.Application,Text="萌生 · JotBloom",Visible=runtime.Settings.ShowTrayIcon||!hotKeyRegistered,ContextMenuStrip=menu};
        runtime.SetTrayVisible=value=>{if(!value&&!hotKeyRegistered)throw new InvalidOperationException("请先设置可用的呼出快捷键，再隐藏托盘图标。");tray.Visible=value;};
        runtime.Clipboard=new ClipboardMonitor(runtime,messages.Handle);runtime.Clipboard.HideRequested+=()=>_ = panel.RequestHideAsync();runtime.Clipboard.Failed+=text=>{tray.BalloonTipTitle="萌生";tray.BalloonTipText=text;tray.ShowBalloonTip(4000);};
        runtime.SettingsChanged+=()=>{hint.ReduceMotion=runtime.Settings.ReduceMotion;};hint.ReduceMotion=runtime.Settings.ReduceMotion;
        panel.ExitRequested+=()=>_ = ExitAsync();
        tray.DoubleClick += (_, _) => app.Dispatcher.Invoke(OpenFromTray);
        hint.Clicked += () => { if (state.ClickHint()) Render(); };
        panel.HideRequested += () => HidePanel(true);
        panel.Closing += (_, e) => { if (!disposed) { e.Cancel = true;_ = panel.RequestHideAsync(); } };
        panel.ExpansionRequested += () => { if (state.Display is DisplayArea d) panel.Position(TopEdgeGeometry.Panel(d, panel.Expanded)); };
        panel.Deactivated += (_, _) => app.Dispatcher.InvokeAsync(async()=>{if(!switching&&!panel.IsActive&&runtime.FocusGuards==0&&!runtime.Maintenance&&state.State==EntryState.PanelVisible)await HideAfterFlush(false);},DispatcherPriority.Background);
        SystemEvents.SessionSwitch += SessionChanged;
        SystemEvents.PowerModeChanged += PowerChanged;
        SystemEvents.DisplaySettingsChanged += DisplaysChanged;
        timer = new DispatcherTimer(TimeSpan.FromMilliseconds(33), DispatcherPriority.Background, (_, _) => Tick(), app.Dispatcher);
        timer.Start();
        activationWait = ThreadPool.RegisterWaitForSingleObject(activation, (_, _) => {
            if (!app.Dispatcher.HasShutdownStarted) app.Dispatcher.InvokeAsync(() => {
                if (!disposed) OpenFromTray();
            });
        }, null, Timeout.Infinite, executeOnlyOnce: false);
        if (!hotKeyRegistered) {
            tray.BalloonTipTitle = "唤起快捷键未注册";
            tray.BalloonTipText = "设置的快捷键可能已被占用。可从系统托盘打开萌生后重新设置。";
            tray.ShowBalloonTip(5000);
        }
    }

    private bool RegisterShortcut(Hotkey shortcut)
    {
        if(!shortcut.IsValid)return false;
        if(hotKeyRegistered&&shortcut.Key==registeredShortcut.Key&&shortcut.Modifiers==registeredShortcut.Modifiers)return true;
        int next=hotkeyId==1?2:1;
        if(!Native.RegisterHotKey(messages.Handle,next,shortcut.Modifiers|0x4000,shortcut.Key))return false;
        if(hotKeyRegistered)Native.UnregisterHotKey(messages.Handle,hotkeyId);hotkeyId=next;hotKeyRegistered=true;registeredShortcut=shortcut;return true;
    }
    private async Task ExitAsync(){if(exitPending)return;exitPending=true;try{if(await panel.PrepareExitAsync())app.Shutdown();else OpenFromTray();}finally{exitPending=false;}}
    private async Task HideAfterFlush(bool restore){if(hidePending)return;hidePending=true;try{if(runtime.Flush is not null){await panel.FlushCurrentAsync();HidePanel(restore);}}catch{OpenFromTray();}finally{hidePending=false;}}
    private IntPtr MessageHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if(msg==0x031D)runtime.Clipboard?.Changed();
        if (msg == Native.HotKeyMessage && wParam.ToInt32() == hotkeyId && !suspended && runtime.FocusGuards==0 && !panel.RecordingShortcut) {
            handled = true;
            if (state.State == EntryState.PanelVisible)_ = panel.RequestHideAsync();
            else { state.ToggleShortcut(ShortcutDisplay()); Render(); }
        }
        return IntPtr.Zero;
    }
    private DisplayArea ShortcutDisplay()
    {
        var foreground = Native.GetForegroundWindow();
        if (foreground != IntPtr.Zero && foreground != panel.Handle && foreground != hint.Handle)
            return Native.Display(Forms.Screen.FromHandle(foreground));
        return Native.GetCursorPos(out var p) ? Native.DisplayAt(new(p.X, p.Y)) : Native.Display(Forms.Screen.PrimaryScreen!);
    }
    internal void OpenFromTray()
    {
        if (suspended) return;
        if (state.State != EntryState.PanelVisible) state.ToggleShortcut(ShortcutDisplay());
        Render(); panel.Activate();
    }
    private void Tick()
    {
        if (suspended || runtime.Maintenance || runtime.FocusGuards>0 || state.State == EntryState.PanelVisible) return;
        if (!Native.GetCursorPos(out var p)) { state.Suspend(); Render(immediate: true); return; }
        var display = Native.DisplayAt(new(p.X, p.Y));
        var screen = Forms.Screen.FromPoint(new System.Drawing.Point(p.X, p.Y));
        bool topAvailable = screen.WorkingArea.Top == screen.Bounds.Top;
        bool clickingHint = state.State == EntryState.HintVisible && state.Display == display && TopEdgeGeometry.Hint(display).Contains(new(p.X, p.Y));
        state.Observe(display, new(p.X, p.Y), Environment.TickCount64,
            topAvailable && (!Native.MouseHeld || clickingHint) && !Native.IsFullscreen(display, hint.Handle));
        Render();
    }
    private void Render(bool immediate = false)
    {
        if (!immediate && renderedState == state.State && renderedDisplay == state.Display) return;
        switching = true;
        try {
            if (renderedDisplay != state.Display) { hint.Conceal(immediate: true); panel.Conceal(immediate: true); }
            if (state.State != EntryState.HintVisible) hint.Conceal(immediate || state.State == EntryState.PanelVisible);
            if (state.State != EntryState.PanelVisible) panel.Conceal(immediate);
            if (state.Display is DisplayArea d) {
                if (state.State == EntryState.HintVisible) hint.Reveal(TopEdgeGeometry.Hint(d), 10);
                if (state.State == EntryState.PanelVisible) {
                    previousForeground = Native.GetForegroundWindow();
                    var rect = TopEdgeGeometry.Panel(d, panel.Expanded);
                    panel.Reveal(rect, rect.Height / d.Scale);
                    if (!panel.Activate()) {
                        tray.BalloonTipTitle = "萌生已展开";
                        tray.BalloonTipText = "请点击面板继续使用。"; tray.ShowBalloonTip(3000);
                    }
                }
            }
            renderedState = state.State; renderedDisplay = state.Display;
        } finally { switching = false; }
    }
    private void HidePanel(bool restoreFocus)
    {
        state.HidePanel(); Render();
        if (restoreFocus && previousForeground != IntPtr.Zero && Native.IsWindow(previousForeground) && !Native.IsIconic(previousForeground))
            _ = Native.SetForegroundWindow(previousForeground); // Best effort; never retry or inject input.
        previousForeground = IntPtr.Zero;
    }
    private void SessionChanged(object sender, SessionSwitchEventArgs e) => app.Dispatcher.Invoke(() => {
        sessionLocked = e.Reason != SessionSwitchReason.SessionUnlock && e.Reason != SessionSwitchReason.SessionLogon;
        runtime.Clipboard?.Pause(suspended);state.Suspend(); Render(immediate: true);
    });
    private void PowerChanged(object sender, PowerModeChangedEventArgs e) => app.Dispatcher.Invoke(() => {
        if (e.Mode == PowerModes.Suspend) sleeping = true;
        if (e.Mode == PowerModes.Resume) sleeping = false;
        runtime.Clipboard?.Pause(suspended);state.Suspend(); Render(immediate: true);
    });
    private void DisplaysChanged(object? sender, EventArgs e) => app.Dispatcher.Invoke(() => {
        state.Suspend(); Render(immediate: true); // Discard coordinates before allowing another presentation.
    });
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        activationWait.Unregister(null);
        timer.Stop();
        SystemEvents.SessionSwitch -= SessionChanged; SystemEvents.PowerModeChanged -= PowerChanged; SystemEvents.DisplaySettingsChanged -= DisplaysChanged;
        runtime.Clipboard?.Dispose();
        if (hotKeyRegistered) Native.UnregisterHotKey(messages.Handle, hotkeyId);
        tray.Visible = false; tray.ContextMenuStrip?.Dispose(); tray.Dispose();
        messages.Dispose(); hint.Close(); panel.Close();
    }
}
