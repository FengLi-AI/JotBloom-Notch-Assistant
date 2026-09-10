using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using JotBloom.Windows.Core;
using JotBloom.Windows.Storage;

namespace JotBloom.Windows.Desktop;

internal sealed class ClipboardMonitor:IDisposable
{
    [DllImport("user32.dll")]private static extern bool AddClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")]private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")]private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")]private static extern IntPtr GetClipboardOwner();
    [DllImport("user32.dll")]private static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
    private readonly AppRuntime runtime;
    private readonly IntPtr handle;
    private readonly Dispatcher worker;
    private volatile bool disposed,paused;
    private uint ownSequence,seen;
    private long generation;
    internal event Action<string>? Failed;
    internal ClipboardMonitor(AppRuntime runtime,IntPtr handle)
    {
        this.runtime=runtime;this.handle=handle;
        var ready=new TaskCompletionSource<Dispatcher>();
        var thread=new Thread(()=>{var dispatcher=Dispatcher.CurrentDispatcher;SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(dispatcher));ready.SetResult(dispatcher);Dispatcher.Run();}){IsBackground=true,Name="JotBloom Clipboard"};
        thread.SetApartmentState(ApartmentState.STA);thread.Start();worker=ready.Task.GetAwaiter().GetResult();
        seen=GetClipboardSequenceNumber(); // Do not collect clipboard content predating startup/resume.
        if(!AddClipboardFormatListener(handle)){worker.BeginInvokeShutdown(DispatcherPriority.Send);throw new IOException("无法开启剪贴板监听，请重新启动后重试。");}
    }
    internal void Pause(bool value){paused=value;Interlocked.Increment(ref generation);seen=GetClipboardSequenceNumber();}
    internal void Changed()
    {
        uint sequence=GetClipboardSequenceNumber();if(sequence==seen||sequence==ownSequence)return;seen=sequence;
        if(disposed||paused||!runtime.Settings.Monitoring||runtime.Maintenance)return;
        long current=Interlocked.Increment(ref generation);var settings=runtime.Settings;
        _=worker.InvokeAsync(async()=>{
            for(int attempt=0;attempt<3;attempt++){
                if(disposed||paused||current!=Interlocked.Read(ref generation)||GetClipboardSequenceNumber()!=sequence)return;
                try{
                    var data=System.Windows.Clipboard.GetDataObject();if(data is null||data.GetDataPresent(DataFormats.FileDrop))return;
                    // Inspect privacy flags before reading text/image payloads.
                    if(data.GetDataPresent("ExcludeClipboardContentFromMonitorProcessing")||HistoryDenied(data))return;
                    _=GetWindowThreadProcessId(GetClipboardOwner(),out uint pid);if(pid==Environment.ProcessId)return;
                    string source="未知应用";try{source=Process.GetProcessById((int)pid).ProcessName;}catch{ }
                    if(settings.ExcludedApplications.Any(p=>p.Equals(source,StringComparison.OrdinalIgnoreCase)))return;
                    ClipboardInput? input=null;
                    if(data.GetDataPresent(DataFormats.UnicodeText)){string? text=data.GetData(DataFormats.UnicodeText)as string;if(!string.IsNullOrEmpty(text)&&TextRules.Count(text)<=1_000_000)input=new(text,SourceName:source,SourceId:"win32:"+source);}
                    else if(System.Windows.Clipboard.ContainsImage()){
                        var image=System.Windows.Clipboard.GetImage();if(image is null||(long)image.PixelWidth*image.PixelHeight>40_000_000)return;
                        var png=Encode(image);double scale=Math.Min(1,200.0/Math.Max(image.PixelWidth,image.PixelHeight));
                        BitmapSource small=scale<1?new TransformedBitmap(image,new ScaleTransform(scale,scale)):image;
                        input=new(null,png,Encode(small),image.PixelWidth,image.PixelHeight,source,"win32:"+source);
                    }
                    if(input is null||disposed||paused||current!=Interlocked.Read(ref generation)||GetClipboardSequenceNumber()!=sequence)return;
                    // Serialize final acceptance on the UI thread so pause/migration cannot race it.
                    await Application.Current.Dispatcher.InvokeAsync(async()=>{
                        if(disposed||paused||runtime.Maintenance||!runtime.Settings.Monitoring||current!=Interlocked.Read(ref generation))return;
                        await runtime.Store.CaptureAsync(input);await runtime.Store.PruneAsync(runtime.Settings);runtime.Notify(LibraryKind.Clipboard);
                    }).Task.Unwrap();return;
                }catch(COMException){if(attempt<2)await Task.Delay(40*(attempt+1));}
                catch{Application.Current.Dispatcher.Invoke(()=>Failed?.Invoke("剪贴板记录未能保存，请检查存储位置。"));return;}
            }
        });
    }
    private static bool HistoryDenied(IDataObject data)
    {
        if(!data.GetDataPresent("CanIncludeInClipboardHistory"))return false;
        var flag=data.GetData("CanIncludeInClipboardHistory");
        if(flag is MemoryStream stream){byte[] bytes=stream.ToArray();return bytes.Length>=4&&BitConverter.ToUInt32(bytes)==0;}
        if(flag is byte[] raw)return raw.Length>=4&&BitConverter.ToUInt32(raw)==0;
        return flag is int n&&n==0;
    }
    private static byte[] Encode(BitmapSource image){var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(image));using var stream=new MemoryStream();encoder.Save(stream);return stream.ToArray();}
    internal async Task CopyAsync(LibraryItem item,bool collapse)
    {
        for(int attempt=0;attempt<3;attempt++){
            try{if(item.ContentType=="image"){
                    byte[] bytes=await Task.Run(()=>File.ReadAllBytes(runtime.Store.AssetPath(item.Image!)));using var stream=new MemoryStream(bytes);
                    var bitmap=new BitmapImage();bitmap.BeginInit();bitmap.CacheOption=BitmapCacheOption.OnLoad;bitmap.StreamSource=stream;bitmap.EndInit();bitmap.Freeze();System.Windows.Clipboard.SetImage(bitmap);
                }else System.Windows.Clipboard.SetText(item.Content);
                ownSequence=GetClipboardSequenceNumber();seen=ownSequence;if(collapse)HideRequested?.Invoke();return;
            }catch(COMException){if(attempt==2)throw new IOException("剪贴板正被其他程序占用，请重试。");await Task.Delay(60);}}
    }
    internal event Action? HideRequested;
    public void Dispose(){if(disposed)return;disposed=true;Interlocked.Increment(ref generation);RemoveClipboardFormatListener(handle);worker.BeginInvokeShutdown(DispatcherPriority.Background);}
}
