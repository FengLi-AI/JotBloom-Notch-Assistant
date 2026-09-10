using System;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using JotBloom.Windows.Core;
using JotBloom.Windows.Storage;
using System.Threading.Tasks;

namespace JotBloom.Windows.Desktop;

internal static class BloomTheme
{
    internal static SolidColorBrush Brush(string hex)
    {
        var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex)); brush.Freeze(); return brush;
    }
    internal static readonly Brush Shell = Brush("#050608"), Surface = Brush("#141820"), Well = Brush("#1B222C"),
        Raised = Brush("#242E3C"), Text = Brush("#E8EDF5"), Muted = Brush("#AAB6C6"), Blue = Brush("#79AFF5");
}

internal abstract class EdgeWindow : Window
{
    protected readonly TranslateTransform Translation = new();
    private readonly EdgeMotion motion = new();
    private readonly DispatcherTimer animationTimer;
    private double heightInDips;
    protected EdgeWindow()
    {
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent;
        ShowInTaskbar = false; Topmost = true;
        FontFamily = new FontFamily("Segoe UI, Microsoft YaHei UI");
        Foreground = BloomTheme.Text;
        animationTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Render, (_, _) => ApplyMotion(), Dispatcher);
        animationTimer.Stop();
        Closed += (_, _) => animationTimer.Stop();
    }
    internal bool ReduceMotion {get;set;}
    internal IntPtr Handle => new WindowInteropHelper(this).EnsureHandle();
    internal void Position(PixelRect rect) => Native.Place(Handle, rect);
    internal void Reveal(PixelRect rect, double dipHeight)
    {
        heightInDips = dipHeight;
        motion.SetVisible(true, Environment.TickCount64, SystemParameters.ClientAreaAnimation && !ReduceMotion);
        Translation.Y = -(1 - motion.Progress) * heightInDips;
        SetPointerEnabled(true);
        // Position before Show to avoid appearing on the primary monitor for one frame.
        Position(rect);
        Show();
        Position(rect);
        ApplyMotion();
    }
    internal void Conceal(bool immediate = false)
    {
        if (ActualHeight > 0) heightInDips = ActualHeight;
        motion.SetVisible(false, Environment.TickCount64, !immediate && SystemParameters.ClientAreaAnimation && !ReduceMotion);
        if (IsVisible) SetPointerEnabled(false);
        ApplyMotion();
    }
    private void SetPointerEnabled(bool enabled)
    {
        IsHitTestVisible = enabled;
        // Layered window: allow clicks to pass through the outgoing animation.
        const long transparent = 0x20; // WS_EX_TRANSPARENT
        long style = Native.GetWindowLongPtr(Handle, Native.ExtendedStyle).ToInt64();
        Native.SetWindowLongPtr(Handle, Native.ExtendedStyle, new IntPtr(enabled ? style & ~transparent : style | transparent));
    }
    private void ApplyMotion()
    {
        long now = Environment.TickCount64;
        if (!SystemParameters.ClientAreaAnimation || ReduceMotion) motion.SetVisible(motion.VisibleRequested, now, animate: false);
        Translation.Y = -(1 - motion.Sample(now)) * heightInDips;
        if (motion.IsComplete) {
            animationTimer.Stop();
            if (!motion.VisibleRequested) Hide();
        } else animationTimer.Start();
    }
}

internal sealed class HintWindow : EdgeWindow
{
    internal event Action? Clicked;
    internal HintWindow()
    {
        ShowActivated = false;
        var border = new Border {
            Background = BloomTheme.Brush("#383838"), CornerRadius = new CornerRadius(0, 0, 10, 10),
            RenderTransform = Translation, Cursor = Cursors.Hand
        };
        AutomationProperties.SetName(border, "打开萌生");
        border.MouseLeftButtonUp += (_, _) => Clicked?.Invoke();
        Content = border;
        SourceInitialized += (_, _) => {
            var style = Native.GetWindowLongPtr(Handle, Native.ExtendedStyle).ToInt64();
            Native.SetWindowLongPtr(Handle, Native.ExtendedStyle, new IntPtr(style | Native.NoActivate | Native.ToolWindow));
            HwndSource.FromHwnd(Handle)?.AddHook((IntPtr hwnd, int msg, IntPtr w, IntPtr l, ref bool handled) => {
                if (msg == Native.MouseActivate) { handled = true; return new IntPtr(3); } // MA_NOACTIVATE, retain click.
                return IntPtr.Zero;
            });
        };
    }
}

internal sealed class PanelWindow : EdgeWindow
{
    internal static readonly System.Collections.Generic.Dictionary<string,string> PageNames=new(){["input"]="灵感",["clipboard"]="剪贴板",["prompts"]="提示词",["inspirations"]="灵感库",["chat"]="对话",["search"]="搜索"};
    internal event Action? HideRequested;
    internal event Action? ExitRequested;
    internal event Action? ExpansionRequested;
    internal bool Expanded { get; private set; }
    private readonly AppRuntime runtime;
    private readonly System.Collections.Generic.Dictionary<string,BloomPage> pages=[];
    private readonly System.Windows.Controls.Primitives.UniformGrid nav=new(){Rows=1,Columns=7};
    private readonly Border well;
    private readonly SemaphoreSlim navigation=new(1);
    private string current="input",previous="input";
    private bool composing;
    internal PanelWindow(AppRuntime runtime)
    {
        this.runtime=runtime;Title="萌生 · JotBloom";
        var outer=new Border{Background=BloomTheme.Shell,CornerRadius=new CornerRadius(0,0,24,24),RenderTransform=Translation};
        var grid=new Grid{Margin=new Thickness(12)};grid.RowDefinitions.Add(new(){Height=GridLength.Auto});grid.RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});grid.RowDefinitions.Add(new(){Height=GridLength.Auto});grid.Children.Add(nav);
        pages["input"]=new InputPane(runtime);pages["clipboard"]=new LibraryPane(runtime,LibraryKind.Clipboard);pages["prompts"]=new LibraryPane(runtime,LibraryKind.Prompts);pages["inspirations"]=new LibraryPane(runtime,LibraryKind.Inspirations);pages["chat"]=new ChatPane(runtime);pages["search"]=new SearchPane(runtime);pages["settings"]=new SettingsPane(runtime);
        current=runtime.Settings.DefaultPage;Expanded=current!="input";well=new Border{Background=BloomTheme.Surface,CornerRadius=new CornerRadius(18),Margin=new Thickness(0,10,0,6),Child=pages[current]};Grid.SetRow(well,1);grid.Children.Add(well);
        var actions=Ui.Row(Ui.Button("展开 / 收回",()=>{SetExpanded(!Expanded);return Task.CompletedTask;}),Ui.Button("收起（Esc）",()=>RequestHideAsync()));actions.HorizontalAlignment=HorizontalAlignment.Right;Grid.SetRow(actions,2);grid.Children.Add(actions);outer.Child=grid;Content=outer;
        runtime.Navigate=(name,id)=>_ = NavigateSafe(name,id);runtime.Discuss=async text=>{var chat=(ChatPane)pages["chat"];bool started=await chat.FromInputAsync(text);if(started)await NavigateAsync("chat");return started;};
        runtime.Flush=PrepareMaintenanceAsync;
        runtime.SettingsChanged+=()=>{ReduceMotion=runtime.Settings.ReduceMotion;BuildNav();};ReduceMotion=runtime.Settings.ReduceMotion;BuildNav();
        runtime.Changed+=kind=>{if((current=="input"||current=="search"||kind is null||current==(kind==LibraryKind.Clipboard?"clipboard":kind==LibraryKind.Prompts?"prompts":"inspirations")))_ = pages[current].Run(pages[current].ActivateAsync);};
        Loaded+=async(_,_)=>await pages[current].Run(pages[current].ActivateAsync);
        TextCompositionManager.AddPreviewTextInputStartHandler(this,(_,_)=>composing=true);TextCompositionManager.AddPreviewTextInputHandler(this,(_,_)=>composing=false);
        PreviewKeyDown+=async(_,e)=>{
            if(current=="settings"&&((SettingsPane)pages["settings"]).IsRecording)return;
            if(composing||e.Key==Key.ImeProcessed)return;
            if(e.Key==Key.Escape){e.Handled=true;await pages[current].Run(BackAsync);return;}
            if(Keyboard.Modifiers!=ModifierKeys.Control)return;
            if(e.Key==Key.Q){e.Handled=true;ExitRequested?.Invoke();}
            else if(e.Key==Key.F){e.Handled=true;await NavigateSafe("search",null);}
            else if(e.Key==Key.OemComma){e.Handled=true;await NavigateSafe("settings",null);}
            else if(e.Key==Key.Up||e.Key==Key.Down){e.Handled=true;SetExpanded(e.Key==Key.Down);}
            else if(e.Key>=Key.D1&&e.Key<=Key.D6){e.Handled=true;await NavigateSafe(runtime.Settings.TabOrder[e.Key-Key.D1],null);}
        };
    }
    internal bool RecordingShortcut=>current=="settings"&&((SettingsPane)pages["settings"]).IsRecording;
    internal Task FlushCurrentAsync()=>pages[current].FlushAsync();
    private void BuildNav(){nav.Children.Clear();foreach(string key in runtime.Settings.TabOrder.Concat(new[]{"settings"})){var button=Ui.Button(PageNames.GetValueOrDefault(key,"设置"),()=>NavigateSafe(key,null));button.Padding=new Thickness(3,7,3,7);button.Foreground=key==current?BloomTheme.Blue:BloomTheme.Muted;nav.Children.Add(button);}}
    private async Task NavigateSafe(string name,long? id){await pages[current].Run(()=>NavigateAsync(name,id));}
    internal async Task NavigateAsync(string name,long? id=null)
    {
        await navigation.WaitAsync();try{
            if(!pages.TryGetValue(name,out var page))return;
            if(current!=name){await pages[current].FlushAsync();previous=current;current=name;well.Child=page;BuildNav();}
            if(name!="input")SetExpanded(true);
            await page.ActivateAsync();if(id is long row&&page is LibraryPane library)await library.OpenId(row);
        }finally{navigation.Release();}
    }
    private async Task BackAsync(){if(current=="settings"){if(((SettingsPane)pages[current]).CancelRecording())return;await NavigateAsync(previous=="settings"?"input":previous);return;}if(await pages[current].BackAsync()){if(previous=="search"){previous=current;await NavigateAsync("search");}return;}await RequestHideAsync();}
    internal void SetExpanded(bool value){if(Expanded==value)return;Expanded=value;ExpansionRequested?.Invoke();}
    internal async Task RequestHideAsync(){try{await pages[current].FlushAsync();HideRequested?.Invoke();}catch(Exception e){pages[current].Feedback.Text=Ui.Error(e);Activate();}}
    private async Task<bool> PrepareMaintenanceAsync(){try{await ((ChatPane)pages["chat"]).StopAsync();foreach(var page in pages.Values)await page.FlushAsync();return true;}catch(Exception e){pages[current].Feedback.Text=Ui.Error(e);Activate();return false;}}
    internal async Task<bool> PrepareExitAsync(){if(!await PrepareMaintenanceAsync())return false;await runtime.DrainAIAsync();return true;}
    internal static Button Button(string text)=>new(){Content=text,Background=BloomTheme.Raised,Foreground=BloomTheme.Text,BorderThickness=new Thickness(0),Padding=new Thickness(10,7,10,7),Margin=new Thickness(2),FontSize=12};
}
