using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using JotBloom.Windows.Storage;

namespace JotBloom.Windows.Desktop;

// Explicit diagnostic command. Uses only a new temporary store; never opens daily data or credentials.
internal static class WindowsUiSmoke
{
    internal static int Run(string output)
    {
        Directory.CreateDirectory(output);var results=new List<string>();int code=1;
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};BloomControls.Install();
        app.DispatcherUnhandledException+=(_,e)=>{File.WriteAllText(Path.Combine(output,"exception.txt"),e.Exception.ToString());e.Handled=true;app.Shutdown(1);};
        app.Startup+=async(_,_)=>{
            string temp=Path.Combine(Path.GetTempPath(),"JotBloom-UI-"+Guid.NewGuid());Directory.CreateDirectory(temp);
            BloomStore? store=null;AppRuntime? runtime=null;PanelWindow? window=null;
            try{
                var location=new DataLocation(Path.Combine(temp,"Control"));string data=location.Create(temp);store=await BloomStore.OpenAsync(data);
                runtime=new AppRuntime(store,location,Path.Combine(temp,"Settings"));
                await store.SaveAsync("把散落的灵感，接成一条线\n每周选三条值得继续的记录，看看它们之间有没有联系。");
                await store.CreatePromptAsync("请先提炼核心观点，再用三个要点概括。保留事实，不补充未经确认的信息。","内容提炼助手");
                window=new PanelWindow(runtime){Width=640,Height=300,Left=0,Top=0};
                window.ExpansionRequested+=()=>window.Height=window.Expanded?700:300;
                window.Show();await Task.Delay(600);
                foreach(string theme in new[]{"dark","light"}){
                    BloomTheme.Apply(theme);runtime.SaveSettings(runtime.Settings with{Appearance=theme});
                    foreach(string page in new[]{"input","clipboard","prompts","inspirations","chat","search","settings"}){
                        await window.NavigateAsync(page);window.UpdateLayout();await Task.Delay(650);Capture(window,Path.Combine(output,theme+"-"+page+".png"));results.Add(theme+"_"+page+"_rendered");
                        if(window.ActualWidth<630||window.ActualHeight<290)throw new Exception("Panel layout collapsed");
                    }
                }
                await window.NavigateAsync("input");window.SetExpanded(false);await window.NavigateAsync("chat");if(!window.Expanded)throw new Exception("Chat did not expand");await window.NavigateAsync("clipboard");if(window.Expanded)throw new Exception("Ordinary tab did not restore compact size");
                window.SetExpanded(true);await window.NavigateAsync("search");await window.NavigateAsync("prompts");if(!window.Expanded)throw new Exception("Ordinary expanded state lost");results.Add("navigation_size_memory");
                await window.NavigateAsync("settings");
                foreach(string section in new[]{"顶部标签","剪贴板","存储与隐私","AI 接口","系统提示词","关于","通用"}){
                    var button=Descendants<BloomButton>(window).First(b=>b.LabelText==section);button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));await Task.Delay(600);window.UpdateLayout();Capture(window,Path.Combine(output,"settings-"+section+".png"));results.Add("settings_"+section+"_rendered");
                }
                var dark=Descendants<BloomButton>(window).First(b=>b.LabelText=="深色");dark.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));await Task.Delay(500);Capture(window,Path.Combine(output,"theme-middle.png"));await Task.Delay(1200);if(runtime.Settings.Appearance!="dark"||BloomTheme.Light)throw new Exception("Theme did not persist");results.Add("theme_reveal_completed");
                var light=Descendants<BloomButton>(window).First(b=>b.LabelText=="浅色");light.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));await Task.Delay(1700);if(runtime.SettingsFile.Load().Appearance!="light")throw new Exception("Light theme not persisted");results.Add("reverse_theme_reveal_completed");
                var face=new Typeface(BloomTheme.LabelFont,FontStyles.Normal,FontWeights.Normal,FontStretches.Normal);if(!face.TryGetGlyphTypeface(out var glyph)||!glyph.FamilyNames.Values.Any(x=>x.Contains("MiSans")))throw new Exception("Embedded MiSans font unavailable");results.Add("embedded_misans_loaded");
                var combos=Descendants<ComboBox>(window).ToArray();foreach(var combo in combos){combo.IsDropDownOpen=true;await Task.Delay(150);combo.IsDropDownOpen=false;}results.Add("combobox_popup_templates");
                if(!await window.PrepareExitAsync())throw new Exception("Draft flush failed");results.Add("draft_flush");code=0;
            }catch(Exception e){File.WriteAllText(Path.Combine(output,"exception.txt"),e.ToString());}
            finally{File.WriteAllText(Path.Combine(output,"report.json"),JsonSerializer.Serialize(new{passed=code==0,checks=results},new JsonSerializerOptions{WriteIndented=true}));window?.Hide();runtime?.Dispose();if(store is not null)await store.DisposeAsync();app.Shutdown(code);}
        };
        app.Run();return code;
    }
    private static IEnumerable<T> Descendants<T>(DependencyObject root)where T:DependencyObject
    {for(int i=0;i<VisualTreeHelper.GetChildrenCount(root);i++){var child=VisualTreeHelper.GetChild(root,i);if(child is T value)yield return value;foreach(var other in Descendants<T>(child))yield return other;}}
    private static void Capture(Window window,string file)
    {var bitmap=new RenderTargetBitmap((int)window.ActualWidth*2,(int)window.ActualHeight*2,192,192,PixelFormats.Pbgra32);bitmap.Render(window);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(file);encoder.Save(stream);}
}
