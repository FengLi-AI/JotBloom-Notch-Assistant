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

internal abstract class EdgeWindow : Window
{
    protected readonly TranslateTransform Translation = new();
    private readonly EdgeMotion motion = new();
    private readonly DispatcherTimer animationTimer;
    private double heightInDips;
    private DispatcherTimer? resizeTimer;
    protected EdgeWindow()
    {
        WindowStyle = WindowStyle.None; ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = true; Background = Brushes.Transparent;
        ShowInTaskbar = false; Topmost = true;
        FontFamily = BloomTheme.LabelFont;
        Foreground = BloomTheme.Text;
        animationTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Render, (_, _) => ApplyMotion(), Dispatcher);
        animationTimer.Stop();
        Closed += (_, _) => animationTimer.Stop();
    }
    internal bool ReduceMotion {get;set;}
    internal IntPtr Handle => new WindowInteropHelper(this).EnsureHandle();
    internal void Position(PixelRect rect) => Native.Place(Handle, rect);
    internal void ResizeTo(PixelRect target)
    {
        resizeTimer?.Stop();
        if(!IsVisible||ReduceMotion||!SystemParameters.ClientAreaAnimation||!Native.GetWindowRect(Handle,out var current)){Position(target);return;}
        long start=Environment.TickCount64;int from=current.Bottom-current.Top;
        resizeTimer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(16)};
        resizeTimer.Tick+=(_,_)=>{double t=Math.Clamp((Environment.TickCount64-start)/360.0,0,1),e=1-Math.Pow(1-t,3);Position(target with{Height=(int)Math.Round(from+(target.Height-from)*e)});if(t>=1)resizeTimer.Stop();};resizeTimer.Start();
    }
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
        resizeTimer?.Stop();
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
    internal bool Expanded => sizing.Expanded;
    private readonly PanelNavigation sizing;
    private readonly AppRuntime runtime;
    private readonly System.Collections.Generic.Dictionary<string,BloomPage> pages=[];
    private readonly BloomNavigation nav=new(horizontal:true);
    private readonly TextBlock heading=Ui.Text("",18);
    private readonly Grid visualRoot=new();
    private readonly BloomButton expandButton=new(""){Icon="chevron-down",Margin=new Thickness(0)};
    private string navOrder="";
    private readonly Border well;
    private readonly SemaphoreSlim navigation=new(1);
    private string current="input",previous="input";
    private bool composing;
    internal PanelWindow(AppRuntime runtime)
    {
        this.runtime=runtime;Title="萌生 · JotBloom";
        BloomTheme.Apply(runtime.Settings.Appearance);BloomTheme.ReduceMotion=runtime.Settings.ReduceMotion;
        sizing=new(runtime.Settings.DefaultPage);
        var outer=new Border{Background=BloomTheme.Surface,CornerRadius=new CornerRadius(0,0,24,24),RenderTransform=Translation};
        var grid=new Grid();grid.RowDefinitions.Add(new(){Height=new GridLength(40)});grid.RowDefinitions.Add(new(){Height=GridLength.Auto});grid.RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});
        var top=new Border{Background=BloomTheme.Shell,Child=nav,Padding=new Thickness(8,2,8,2)};grid.Children.Add(top);
        heading.Margin=new Thickness(16,14,16,12);heading.FontWeight=FontWeights.Normal;heading.FontFamily=BloomTheme.LabelFont;Grid.SetRow(heading,1);grid.Children.Add(heading);
        pages["input"]=new InputPane(runtime);pages["clipboard"]=new LibraryPane(runtime,LibraryKind.Clipboard);pages["prompts"]=new LibraryPane(runtime,LibraryKind.Prompts);pages["inspirations"]=new LibraryPane(runtime,LibraryKind.Inspirations);pages["chat"]=new ChatPane(runtime);pages["search"]=new SearchPane(runtime);pages["settings"]=new SettingsPane(runtime);
        current=runtime.Settings.DefaultPage;
        well=new Border{Background=BloomTheme.Surface,Margin=new Thickness(16,0,16,16),Child=pages[current]};Grid.SetRow(well,2);grid.Children.Add(well);
        expandButton.HorizontalAlignment=HorizontalAlignment.Right;expandButton.VerticalAlignment=VerticalAlignment.Bottom;expandButton.Margin=new Thickness(0,0,16,16);expandButton.ToolTip="展开 / 收回 · Ctrl+↓ / Ctrl+↑";
        expandButton.Click+=(_,_)=>SetExpanded(!Expanded);Grid.SetRow(expandButton,2);grid.Children.Add(expandButton);
        outer.Child=grid;visualRoot.Children.Add(outer);Content=visualRoot;
        runtime.ChangeAppearance=ChangeAppearance;runtime.HidePanel=()=>RequestHideAsync();
        runtime.Navigate=(name,id)=>_ = NavigateSafe(name,id);runtime.Discuss=async text=>{var chat=(ChatPane)pages["chat"];bool started=await chat.FromInputAsync(text);if(started)await NavigateAsync("chat");return started;};
        runtime.Flush=PrepareMaintenanceAsync;
        runtime.SettingsChanged+=()=>{ReduceMotion=runtime.Settings.ReduceMotion;BloomTheme.ReduceMotion=ReduceMotion;BuildNav();};ReduceMotion=runtime.Settings.ReduceMotion;BloomTheme.ReduceMotion=ReduceMotion;BuildNav();
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
    private void BuildNav()
    {
        string order=string.Join(",",runtime.Settings.TabOrder);
        if(order!=navOrder){navOrder=order;nav.Clear();foreach(string key in runtime.Settings.TabOrder.Concat(new[]{"settings"})){string icon=key switch{"input"=>"bulb","clipboard"=>"clipboard","prompts"=>"bookmark","inspirations"=>"archive","chat"=>"message-circle","search"=>"search",_=>"settings-2"};nav.Add(key,key=="settings"?"":PageNames[key],icon,()=>NavigateSafe(key,null));}}
        nav.Select(current);heading.Text=current=="chat"?"AI 对话":PageNames.GetValueOrDefault(current,"设置");heading.Visibility=current=="input"?Visibility.Collapsed:Visibility.Visible;
        foreach(var page in pages.Values)page.SetExpanded(Expanded);
    }
    private async Task ChangeAppearance(string appearance,FrameworkElement origin)
    {
        if(runtime.Settings.Appearance==appearance)return;
        var point=origin.TranslatePoint(new Point(origin.ActualWidth/2,origin.ActualHeight/2),visualRoot);
        // Snapshot the old appearance; reveal live controls through a growing circular hole.
        Image? old=null;
        if(BloomTheme.Animate&&visualRoot.ActualWidth>0&&visualRoot.ActualHeight>0){
            var dpi=VisualTreeHelper.GetDpi(visualRoot);var bitmap=new System.Windows.Media.Imaging.RenderTargetBitmap((int)Math.Ceiling(visualRoot.ActualWidth*dpi.DpiScaleX),(int)Math.Ceiling(visualRoot.ActualHeight*dpi.DpiScaleY),dpi.PixelsPerInchX,dpi.PixelsPerInchY,PixelFormats.Pbgra32);bitmap.Render(visualRoot);
            old=new Image{Source=bitmap,Width=visualRoot.ActualWidth,Height=visualRoot.ActualHeight,IsHitTestVisible=false,HorizontalAlignment=HorizontalAlignment.Left,VerticalAlignment=VerticalAlignment.Top};
        }
        runtime.SaveSettings(runtime.Settings with{Appearance=appearance});BloomTheme.Apply(appearance);
        if(old is null)return;
        visualRoot.Children.Add(old);var circle=new EllipseGeometry(point,1,1);
        old.Clip=new CombinedGeometry(GeometryCombineMode.Exclude,new RectangleGeometry(new Rect(0,0,old.Width,old.Height)),circle);
        double radius=Math.Sqrt(Math.Pow(Math.Max(point.X,old.Width-point.X),2)+Math.Pow(Math.Max(point.Y,old.Height-point.Y),2))+2;
        var animation=new System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames();animation.KeyFrames.Add(new System.Windows.Media.Animation.SplineDoubleKeyFrame(radius,System.Windows.Media.Animation.KeyTime.FromTimeSpan(TimeSpan.FromSeconds(1.5)),new System.Windows.Media.Animation.KeySpline(.16,1,.30,1)));
        circle.BeginAnimation(EllipseGeometry.RadiusXProperty,animation);circle.BeginAnimation(EllipseGeometry.RadiusYProperty,animation);
        try{await Task.Delay(1530);}finally{visualRoot.Children.Remove(old);}
    }
    private async Task NavigateSafe(string name,long? id){await pages[current].Run(()=>NavigateAsync(name,id));}
    internal async Task NavigateAsync(string name,long? id=null)
    {
        await navigation.WaitAsync();try{
            if(!pages.TryGetValue(name,out var page))return;
            if(current!=name){await pages[current].FlushAsync();previous=current;current=name;sizing.Select(name);well.Child=page;ExpansionRequested?.Invoke();BuildNav();BloomTheme.Enter(page);}

            await page.ActivateAsync();if(id is long row&&page is LibraryPane library)await library.OpenId(row);
        }finally{navigation.Release();}
    }
    private async Task BackAsync(){if(current=="settings"){if(((SettingsPane)pages[current]).CancelRecording())return;await NavigateAsync(previous=="settings"?"input":previous);return;}if(await pages[current].BackAsync()){if(previous=="search"){previous=current;await NavigateAsync("search");}return;}await RequestHideAsync();}
    internal void SetExpanded(bool value){if(Expanded==value)return;sizing.Resize(value);ExpansionRequested?.Invoke();foreach(var page in pages.Values)page.SetExpanded(Expanded);}
    internal async Task RequestHideAsync(){try{await pages[current].FlushAsync();HideRequested?.Invoke();}catch(Exception e){pages[current].Feedback.Text=Ui.Error(e);Activate();}}
    private async Task<bool> PrepareMaintenanceAsync(){try{await ((ChatPane)pages["chat"]).StopAsync();foreach(var page in pages.Values)await page.FlushAsync();return true;}catch(Exception e){pages[current].Feedback.Text=Ui.Error(e);Activate();return false;}}
    internal async Task<bool> PrepareExitAsync(){if(!await PrepareMaintenanceAsync())return false;await runtime.DrainAIAsync();return true;}
    internal static Button Button(string text)=>new BloomButton(text);
}
