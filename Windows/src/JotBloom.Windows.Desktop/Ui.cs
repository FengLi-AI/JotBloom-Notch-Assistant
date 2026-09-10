using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using JotBloom.Windows.Core;

namespace JotBloom.Windows.Desktop;

internal static class Ui
{
    internal static TextBlock Text(string text,int size=13,Brush? color=null)=>new(){Text=text,FontSize=size,Foreground=color??BloomTheme.Text,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,3,0,3)};
    internal static TextBox Editor(string label,bool multiline=true)=>Named(new TextBox{AcceptsReturn=multiline,TextWrapping=multiline?TextWrapping.Wrap:TextWrapping.NoWrap,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,Background=BloomTheme.Well,Foreground=BloomTheme.Text,CaretBrush=BloomTheme.Blue,BorderBrush=BloomTheme.Raised,BorderThickness=new Thickness(1),Padding=new Thickness(10),FontSize=14,MinHeight=34},label);
    private static T Named<T>(T view,string label)where T:FrameworkElement{AutomationProperties.SetName(view,label);return view;}
    internal static Button Button(string title,Func<Task> action)=>Wire(PanelWindow.Button(title),action);
    private static Button Wire(Button b,Func<Task> action){b.Click+=async(_,_)=>await action();return b;}
    internal static StackPanel Row(params UIElement[] views){var row=new StackPanel{Orientation=Orientation.Horizontal};foreach(var v in views)row.Children.Add(v);return row;}
    internal static Border Card(UIElement content)=>new(){Child=content,Padding=new Thickness(14),Margin=new Thickness(0,0,0,12),CornerRadius=new CornerRadius(18),Background=BloomTheme.Well};
    internal static ScrollViewer Scroll(UIElement content)=>new(){Content=content,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};
    internal static string Error(Exception e)=>e switch{AiException or ArgumentException or InvalidOperationException or JotBloom.Windows.Storage.DuplicateInspirationException=>e.Message,OperationCanceledException=>"操作已停止或超时，当前输入已保留。",System.Net.Http.HttpRequestException=>"无法连接服务，请检查网络和接口地址。",System.Text.Json.JsonException=>"返回内容或配置格式无效，请检查后重试。",_=>"操作未完成，请检查存储磁盘、权限或网络后重试。当前输入已保留。"};
}
internal sealed class DebouncedSave
{
    private readonly DispatcherTimer timer;
    private readonly Func<Task> write;
    private Task active=Task.CompletedTask;
    private bool dirty;
    internal DebouncedSave(Func<Task> write,Action<Exception> failed)
    {
        this.write=write;timer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(500)};
        timer.Tick+=async(_,_)=>{timer.Stop();try{await FlushAsync();}catch(Exception e){failed(e);}};
    }
    internal void Changed(){dirty=true;timer.Stop();timer.Start();}
    internal async Task FlushAsync()
    {
        timer.Stop();try{await active;}catch{ /* A new flush retries the retained dirty input. */ }
        if(!dirty)return;dirty=false;
        Task operation;try{operation=write();}catch{dirty=true;throw;}active=operation;
        try{await operation;}catch{dirty=true;throw;}finally{if(active==operation)active=Task.CompletedTask;}
    }
    internal void Clear(){timer.Stop();dirty=false;}
}
internal abstract class BloomPage:Grid
{
    protected readonly AppRuntime Runtime;
    internal readonly TextBlock Feedback=Ui.Text("",12,BloomTheme.Muted);
    protected BloomPage(AppRuntime runtime){Runtime=runtime;Margin=new Thickness(14);}
    internal virtual Task ActivateAsync()=>Task.CompletedTask;
    internal virtual Task FlushAsync()=>Task.CompletedTask;
    internal virtual Task<bool> BackAsync()=>Task.FromResult(false);
    internal async Task Run(Func<Task> operation){try{await operation();}catch(Exception e){Feedback.Text=Ui.Error(e);}}
}
