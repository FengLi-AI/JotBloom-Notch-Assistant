using System.Diagnostics;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Windows;
using JotBloom.Windows.Core;
using JotBloom.Windows.Storage;

namespace JotBloom.Windows.Desktop;

internal sealed class CredentialVault(string directory)
{
    private string PathFor(string slot)=>Path.Combine(directory,slot is "main" or "auxiliary"?slot+".bin":throw new ArgumentException());
    internal bool Exists(string slot)=>File.Exists(PathFor(slot));
    internal string Read(string slot)
    {
        if(!Exists(slot))throw new AiException("请先在 AI 接口设置中保存 API Key。");
        byte[] plain;
        try{plain=ProtectedData.Unprotect(File.ReadAllBytes(PathFor(slot)),null,DataProtectionScope.CurrentUser);}
        catch(CryptographicException){throw new AiException("无法解密原密钥，请在设置中重新输入并替换。原密钥文件仍保留。");}
        try{return Encoding.UTF8.GetString(plain);}finally{CryptographicOperations.ZeroMemory(plain);}
    }
    internal void Write(string slot,string value)
    {
        if(string.IsNullOrWhiteSpace(value)||value.Contains('\n')||value.Contains('\r'))throw new AiException("请输入有效的 API Key。");
        byte[] plain=Encoding.UTF8.GetBytes(value.Trim());try{AtomicFile.Write(PathFor(slot),ProtectedData.Protect(plain,null,DataProtectionScope.CurrentUser));PrivateDirectory.Restrict(directory);}finally{CryptographicOperations.ZeroMemory(plain);}
    }
    internal void Remove(string slot){File.Delete(PathFor(slot));}
}
internal static class PrivateDirectory
{
    internal static void Restrict(string path)
    {
        if(!OperatingSystem.IsWindows())return;
        var sid=WindowsIdentity.GetCurrent().User??throw new IOException("无法确认当前 Windows 用户。");
        var rules=new DirectorySecurity();rules.SetOwner(sid);rules.SetAccessRuleProtection(true,false);
        rules.AddAccessRule(new FileSystemAccessRule(sid,FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
        rules.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid,null),FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
        new DirectoryInfo(path).SetAccessControl(rules);
    }
}
internal sealed class AppRuntime:IDisposable
{
    internal const string Version="1.0.2 测试版";
    internal readonly BloomStore Store;
    internal readonly DataLocation Location;
    internal readonly CredentialVault Vault;
    internal readonly AiClient Ai=new();
    internal readonly SettingsFile SettingsFile;
    internal ProductSettings Settings {get;private set;}
    internal bool RestartRequested,Maintenance;
    internal int FocusGuards;
    internal Func<Hotkey,bool>? RegisterShortcut;
    internal Action<bool>? SetTrayVisible;
    internal Func<Task<bool>>? Flush;
    internal ClipboardMonitor? Clipboard;
    internal Action<string,long?>? Navigate;
    internal Func<string,Task<bool>>? Discuss;
    internal event Action<LibraryKind?>? Changed;
    internal event Action? SettingsChanged;
    private readonly SemaphoreSlim aiSlots=new(2);
    private CancellationTokenSource aiGeneration=new();
    private int pendingAI;
    private readonly HashSet<Task> aiTasks=[];
    internal async Task DrainAIAsync(){CancelAI();await Task.WhenAll(aiTasks.ToArray());}
    internal AppRuntime(BloomStore store,DataLocation location,string control)
    {
        Store=store;Location=location;SettingsFile=new(Path.Combine(control,"settings.json"));Settings=SettingsFile.Load();Vault=new(Path.Combine(control,"Credentials"));
    }
    internal void Notify(LibraryKind? kind=null)=>Application.Current.Dispatcher.Invoke(()=>Changed?.Invoke(kind));
    internal void SaveSettings(ProductSettings settings)
    {
        settings.Validate();SettingsFile.Save(settings);
        if(settings.Main!=Settings.Main||settings.Auxiliary!=Settings.Auxiliary||settings.AuxiliaryUsesMain!=Settings.AuxiliaryUsesMain||settings.InspirationAI!=Settings.InspirationAI)CancelAI();
        Settings=settings;SettingsChanged?.Invoke();
    }
    internal void CancelAI(){aiGeneration.Cancel();aiGeneration.Dispose();aiGeneration=new();}
    internal void ScheduleAI(LibraryItem item)
    {
        if(item.Kind==LibraryKind.Clipboard||item.Kind==LibraryKind.Inspirations&&!Settings.InspirationAI||pendingAI>=32)return;
        var resolved=Settings.Resolve(true);if(!Vault.Exists(resolved.KeySlot)||string.IsNullOrWhiteSpace(resolved.Configuration.Model))return;
        pendingAI++;var task=Run();aiTasks.Add(task);_ = RemoveWhenDone(task);
        async Task RemoveWhenDone(Task pending){try{await pending;}finally{aiTasks.Remove(pending);}}
        async Task Run(){var token=aiGeneration.Token;bool entered=false;
            try{await aiSlots.WaitAsync(token);entered=true;token.ThrowIfCancellationRequested();string key=Vault.Read(resolved.KeySlot);
                string instruction=item.Kind==LibraryKind.Inspirations?AiPrompts.Rules+"\n"+AiPrompts.Inspiration:AiPrompts.PromptTitle;
                string answer=await Ai.CompleteAsync(resolved.Configuration,key,[new("system",instruction),new("user",TextRules.Prefix(item.Content,2000))],token);
                token.ThrowIfCancellationRequested();string? title,category=null;
                if(item.Kind==LibraryKind.Inspirations){using var json=JsonDocument.Parse(answer);title=json.RootElement.TryGetProperty("title",out var t)?t.GetString()?.Trim():null;category=json.RootElement.TryGetProperty("category",out var c)?c.GetString():null;
                    if(title is not null&&(TextRules.Count(title)>20||title.Contains('\n')||string.IsNullOrWhiteSpace(title)))title=null;if(!BloomStore.Categories.Contains(category))category=null;if(title is null&&category is null)return;}
                else{title=answer.Trim().Trim('。','.','!','！','?','？','；',';', '，',',').Trim('"','“','”','\'','「','」').Trim();if(title.Contains('\n')||title.Contains('\r')||TextRules.Count(title)>20||title.Length==0)return;title=TextRules.Prefix(title,10);}
                if(await Store.ApplyAIAsync(item,title,category))Notify(item.Kind);
            }catch{ /* Local fallback remains; no automatic resubmission or raw-response logging. */ }
            finally{pendingAI--;if(entered)aiSlots.Release();}}
    }
    internal IDisposable ProtectFocus(){FocusGuards++;return new Scope(()=>FocusGuards--);}
    internal bool Confirm(string message)
    {
        using var guard=ProtectFocus();return MessageBox.Show(message,"萌生",MessageBoxButton.OKCancel,MessageBoxImage.Question)==MessageBoxResult.OK;
    }
    internal static void OpenLink(string url)
    {
        if(!Uri.TryCreate(url,UriKind.Absolute,out var uri)||uri.Scheme is not("https" or "mailto"))throw new InvalidOperationException("链接无效。");
        Process.Start(new ProcessStartInfo(url){UseShellExecute=true});
    }
    public void Dispose(){aiGeneration.Cancel();Ai.Dispose();}
    private sealed class Scope(Action dispose):IDisposable{public void Dispose()=>dispose();}
}
