using System.Diagnostics;
using System.Net.Http;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;
using JotBloom.Windows.Core;

namespace JotBloom.Windows.Desktop;

internal sealed class SettingsPane:BloomPage
{
    private readonly StackPanel content=new();
    private readonly TextBox system=Ui.Editor("系统提示词");
    private string section="通用";
    private bool systemDirty,recording;
    private Button? recordButton;
    private Hotkey? candidate;
    internal SettingsPane(AppRuntime runtime):base(runtime)
    {
        ColumnDefinitions.Add(new(){Width=new GridLength(120)});ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});
        RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});RowDefinitions.Add(new(){Height=GridLength.Auto});
        var nav=new StackPanel();foreach(string name in new[]{"通用","顶部标签","剪贴板","存储与隐私","AI 接口","系统提示词","关于"})nav.Children.Add(Ui.Button(name,()=>Run(async()=>{await FlushAsync();section=name;ShowSection();})));
        Children.Add(nav);var scroll=Ui.Scroll(content);Grid.SetColumn(scroll,1);Children.Add(scroll);Grid.SetRow(Feedback,1);Grid.SetColumnSpan(Feedback,2);Children.Add(Feedback);
        system.TextChanged+=(_,_)=>systemDirty=section=="系统提示词"&&system.Text!=Runtime.Settings.SystemPrompt;
        PreviewKeyDown+=RecordKey;
        ShowSection();
    }
    private void Card(string heading,params UIElement[] elements){var box=new StackPanel();box.Children.Add(Ui.Text(heading,16));foreach(var element in elements)box.Children.Add(element);content.Children.Add(Ui.Card(box));}
    private CheckBox Toggle(string label,bool value,Action<bool> save)
    {
        var check=new CheckBox{Content=label,IsChecked=value,Foreground=BloomTheme.Text,Margin=new Thickness(0,9,0,9)};bool changing=false;
        check.Click+=(_,_)=>{if(changing)return;try{save(check.IsChecked==true);Feedback.Text="已保存";}catch(Exception e){changing=true;check.IsChecked=!check.IsChecked;changing=false;Feedback.Text=Ui.Error(e);}};return check;
    }
    private ComboBox Choices<T>(IEnumerable<T> items,T selected,Action<T> save)where T:notnull
    {
        var combo=new ComboBox{ItemsSource=items,SelectedItem=selected,Margin=new Thickness(0,6,0,8),MinWidth=120};
        combo.SelectionChanged+=(_,_)=>{if(combo.SelectedItem is T value)try{save(value);Feedback.Text="已保存";}catch(Exception e){Feedback.Text=Ui.Error(e);}};return combo;
    }
    private void ShowSection()
    {
        StopRecording();content.Children.Clear();Feedback.Text="";
        switch(section){case "通用":General();break;case "顶部标签":Tabs();break;case "剪贴板":ClipboardSettings();break;case "存储与隐私":Storage();break;case "AI 接口":AI();break;case "系统提示词":SystemPrompt();break;default:About();break;}
    }
    private void General()
    {
        var shortcut=Ui.Text(Runtime.Settings.Shortcut.Label,15,BloomTheme.Blue);
        recordButton=Ui.Button("录制快捷键",()=>{recording=true;candidate=null;recordButton!.Content="请按 Ctrl / Alt 加另一个键…";recordButton.Focus();return Task.CompletedTask;});
        var apply=Ui.Button("应用快捷键",()=>Run(()=>{if(candidate is null)throw new InvalidOperationException("先录制一组快捷键。");var old=Runtime.Settings.Shortcut;if(Runtime.RegisterShortcut?.Invoke(candidate)!=true)throw new InvalidOperationException("这组快捷键被系统或其他应用占用，请换一组。原快捷键仍有效。");try{Runtime.SaveSettings(Runtime.Settings with{Shortcut=candidate});}catch{Runtime.RegisterShortcut?.Invoke(old);throw;}shortcut.Text=candidate.Label;Feedback.Text="快捷键已更新";return Task.CompletedTask;}));
        Card("快捷操作",shortcut,Ui.Row(recordButton,apply),Ui.Text("Ctrl+↓ / Ctrl+↑ 展开 / 收回\nCtrl+F 搜索 · Ctrl+, 设置 · Ctrl+Q 退出\nEsc 先返回列表或退出设置，再收起面板\nCtrl+1…6 切换顶部标签",12,BloomTheme.Muted));
        Card("通用",Toggle("显示系统托盘图标",Runtime.Settings.ShowTrayIcon,v=>{Runtime.SetTrayVisible?.Invoke(v);try{Runtime.SaveSettings(Runtime.Settings with{ShowTrayIcon=v});}catch{Runtime.SetTrayVisible?.Invoke(!v);throw;}}),
            Toggle("开机自动启动",Runtime.Settings.StartWithWindows,v=>{AutoStart.Set(v);try{Runtime.SaveSettings(Runtime.Settings with{StartWithWindows=v});}catch{AutoStart.Set(!v);throw;}}),
            Toggle("减少动效",Runtime.Settings.ReduceMotion,v=>Runtime.SaveSettings(Runtime.Settings with{ReduceMotion=v})),Ui.Text("默认打开",12,BloomTheme.Muted),
            DefaultChoice(),
            Ui.Button("查看使用说明",()=>{using var guard=Runtime.ProtectFocus();MessageBox.Show("将鼠标紧贴屏幕顶部正中央，小条出现后点击打开萌生。\n快捷键会直接打开面板。\n输入会自动保留为草稿；按 Ctrl+Enter 保存灵感。\n复制文字或图片后，可在剪贴板页找回。\n关闭面板后萌生仍在托盘运行。","萌生 · 使用说明");return Task.CompletedTask;}));
    }
    private ComboBox DefaultChoice(){var combo=new ComboBox{ItemsSource=PanelWindow.PageNames,DisplayMemberPath="Value",SelectedValuePath="Key",SelectedValue=Runtime.Settings.DefaultPage,Margin=new Thickness(0,6,0,8)};combo.SelectionChanged+=(_,_)=>{if(combo.SelectedValue is string key)try{Runtime.SaveSettings(Runtime.Settings with{DefaultPage=key});}catch(Exception e){Feedback.Text=Ui.Error(e);}};return combo;}
    internal bool IsRecording=>recording;
    private void RecordKey(object sender,KeyEventArgs e)
    {
        if(!recording)return;e.Handled=true;var key=e.Key==Key.System?e.SystemKey:e.Key;
        if(key==Key.Escape){StopRecording();return;}if(key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin)return;
        var mods=Keyboard.Modifiers;uint native=((mods&ModifierKeys.Alt)!=0?1u:0)|((mods&ModifierKeys.Control)!=0?2u:0)|((mods&ModifierKeys.Shift)!=0?4u:0);
        string label=((native&2)!=0?"Ctrl+":"")+((native&1)!=0?"Alt+":"")+((native&4)!=0?"Shift+":"")+key;
        var value=new Hotkey((uint)KeyInterop.VirtualKeyFromKey(key),native,label);
        if((mods&ModifierKeys.Windows)!=0||!value.IsValid){Feedback.Text="请使用 Ctrl 或 Alt 加一个普通键；系统与编辑快捷键不能使用。";return;}
        candidate=value;recording=false;recordButton!.Content=label;Feedback.Text="已录制，点击应用快捷键后生效。";
    }
    private void StopRecording(){recording=false;if(recordButton is not null)recordButton.Content="录制快捷键";}
    internal bool CancelRecording(){if(!recording)return false;StopRecording();return true;}
    private void Tabs()
    {
        Card("顶部标签顺序",Ui.Text("用上移、下移调整；所有页面始终保留。",12,BloomTheme.Muted));
        var order=Runtime.Settings.TabOrder;for(int index=0;index<order.Length;index++){int position=index;var label=Ui.Text(PanelWindow.PageNames[order[index]]);label.Width=100;
            content.Children.Add(Ui.Card(Ui.Row(label,Ui.Button("上移",()=>Move(-1)),Ui.Button("下移",()=>Move(1)))));
            Task Move(int direction){int next=position+direction;if(next<0||next>=order.Length)return Task.CompletedTask;var changed=order.ToArray();(changed[next],changed[position])=(changed[position],changed[next]);return Run(()=>{Runtime.SaveSettings(Runtime.Settings with{TabOrder=changed});ShowSection();return Task.CompletedTask;});}}
    }
    private void ClipboardSettings()
    {
        Card("剪贴板记录",Toggle("记录新复制的文字、链接和图片",Runtime.Settings.Monitoring,v=>{Runtime.SaveSettings(Runtime.Settings with{Monitoring=v});Runtime.Clipboard?.Pause(!v);}),
            Ui.Text("最多记录条数（0 为不限）",12,BloomTheme.Muted),Choices(new[]{0,100,200,500,1000,5000},Runtime.Settings.MaximumCount,v=>Runtime.SaveSettings(Runtime.Settings with{MaximumCount=v})),
            Ui.Text("保留天数（0 为不限）",12,BloomTheme.Muted),Choices(new[]{0,7,30,90,365},Runtime.Settings.MaximumDays,v=>Runtime.SaveSettings(Runtime.Settings with{MaximumDays=v})),
            Ui.Text("内容容量上限，单位 MB（0 为不限）",12,BloomTheme.Muted),Choices(new long[]{0,500,1000,2000,5000,10000},Runtime.Settings.MaximumBytes/1_000_000,v=>Runtime.SaveSettings(Runtime.Settings with{MaximumBytes=v*1_000_000})));
        var excluded=Ui.Editor("不记录的应用进程名，每行一个");excluded.Text=string.Join("\n",Runtime.Settings.ExcludedApplications);excluded.Height=90;
        Card("不记录这些应用",Ui.Text("每行填写一个进程名，不带 .exe，例如 KeePass。应用标记为私密的剪贴板内容也不会记录。",12,BloomTheme.Muted),excluded,
            Ui.Button("保存排除名单",()=>Run(()=>{Runtime.SaveSettings(Runtime.Settings with{ExcludedApplications=excluded.Text.Split(['\r','\n'],StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries).Select(x=>x.EndsWith(".exe",StringComparison.OrdinalIgnoreCase)?x[..^4]:x).Distinct(StringComparer.OrdinalIgnoreCase).ToArray()});Feedback.Text="已保存";return Task.CompletedTask;})));
        Card("清理记录",Ui.Button("按当前规则清理",()=>Run(async()=>{await Runtime.Store.PruneAsync(Runtime.Settings);Runtime.Notify();Feedback.Text="清理完成";})),Ui.Button("清空剪贴板历史",()=>Run(async()=>{if(!Runtime.Confirm("清空所有剪贴板历史？已存入灵感库、提示词库的内容会保留。"))return;await Runtime.Store.ClearClipboardAsync();Runtime.Notify();Feedback.Text="剪贴板历史已清空";})));
    }
    private string? Pick(string title){using var guard=Runtime.ProtectFocus();var picker=new OpenFolderDialog{Title=title};return picker.ShowDialog()==true?picker.FolderName:null;}
    private void Storage()
    {
        Card("数据位置",Ui.Text(Runtime.Store.DirectoryPath),Ui.Button("打开数据文件夹",()=>Run(()=>{Process.Start(new ProcessStartInfo("explorer.exe"){ArgumentList={Runtime.Store.DirectoryPath}});return Task.CompletedTask;})),
            Ui.Button("创建备份",()=>Run(async()=>{var parent=Pick("选择备份保存位置");if(parent is null)return;if(Runtime.Flush is not null&&!await Runtime.Flush())return;string result=await Runtime.Store.CopyDirectoryAsync(parent,true);Feedback.Text="备份已保存："+result;})),
            Ui.Button("更换存储位置",()=>Run(()=>ChangeLocation(false))),Ui.Button("从备份恢复",()=>Run(()=>ChangeLocation(true))));
        var usage=Ui.Text("正在读取…",12,BloomTheme.Muted);Card("存储与隐私",usage,Ui.Text("内容保存在你选择的本地文件夹。API Key 使用当前 Windows 用户的系统保护加密保存，不包含在内容备份中。只有使用 AI 功能时才向配置的服务发送相关内容。",12,BloomTheme.Muted));
        _=Run(async()=>{var value=await Runtime.Store.UsageAsync();usage.Text=$"剪贴板 {value.Records} 条 · 图片 {value.Images} 张 · 内容约 {value.Bytes/1_000_000.0:F1} MB";});
    }
    private async Task ChangeLocation(bool restore)
    {
        string? chosen=Pick(restore?"选择同一份萌生数据的完整备份文件夹":"选择新位置（在其中新建 JotBloom 文件夹）");if(chosen is null)return;
        if(!Runtime.Confirm(restore?"将切换到所选备份并重启萌生。当前数据会原样保留。":"将复制数据到新位置并重启萌生。原数据会原样保留。"))return;
        if(Runtime.Flush is not null&&!await Runtime.Flush())return;
        Runtime.Maintenance=true;Runtime.Clipboard?.Pause(true);IsEnabled=false;
        try{await Runtime.DrainAIAsync();string destination=restore?chosen:await Runtime.Store.CopyDirectoryAsync(chosen,false);await Task.Run(()=>Runtime.Location.Relocate(destination));Runtime.RestartRequested=true;Application.Current.Shutdown();}
        finally{if(!Runtime.RestartRequested){IsEnabled=true;Runtime.Maintenance=false;Runtime.Clipboard?.Pause(false);}}
    }
    private void AI()
    {
        Card("AI 功能",Toggle("保存灵感时自动生成标题和分类",Runtime.Settings.InspirationAI,v=>Runtime.SaveSettings(Runtime.Settings with{InspirationAI=v})),Toggle("辅助模型共用主模型接口和密钥",Runtime.Settings.AuxiliaryUsesMain,v=>{Runtime.SaveSettings(Runtime.Settings with{AuxiliaryUsesMain=v});ShowSection();}),Ui.Text("不配置 AI 也可以记录和管理内容。辅助模型名称留空时使用主模型。",12,BloomTheme.Muted));
        ModelCard(false);ModelCard(true);
    }
    private void ModelCard(bool auxiliary)
    {
        string slot=auxiliary?"auxiliary":"main";var config=auxiliary?Runtime.Settings.Auxiliary:Runtime.Settings.Main;
        var address=Ui.Editor("接口地址",false);address.Text=config.BaseUrl;var model=Ui.Editor("模型名称",false);model.Text=config.Model;
        var key=new PasswordBox{Background=BloomTheme.Well,Foreground=BloomTheme.Text,Padding=new Thickness(8),Margin=new Thickness(0,6,0,6)};
        var state=Ui.Text(Runtime.Vault.Exists(slot)?"密钥已保存；留空保持原密钥。":"尚未保存密钥。",12,BloomTheme.Muted);
        bool shared=auxiliary&&Runtime.Settings.AuxiliaryUsesMain;address.IsEnabled=!shared;key.IsEnabled=!shared;
        var save=Ui.Button("保存配置",()=>Run(()=>{var next=new ModelConfiguration(address.Text.Trim(),model.Text.Trim());if(!shared&&!string.IsNullOrWhiteSpace(next.BaseUrl))_ = ModelEndpoint.Normalize(next.BaseUrl);
            if(key.Password.Length>0&&!shared){Runtime.CancelAI();Runtime.Vault.Write(slot,key.Password);key.Clear();state.Text="密钥已保存";}
            Runtime.SaveSettings(auxiliary?Runtime.Settings with{Auxiliary=next}:Runtime.Settings with{Main=next});Feedback.Text="AI 配置已保存";return Task.CompletedTask;}));
        var test=Ui.Button("测试已保存的配置",()=>Run(async()=>{var resolved=Runtime.Settings.Resolve(auxiliary);string secret=Runtime.Vault.Read(resolved.KeySlot);Feedback.Text="正在测试…";IsEnabled=false;
            try{for(int attempt=0;;attempt++){try{await Runtime.Ai.CompleteAsync(resolved.Configuration,secret,[new("user","只回复 OK")]);break;}catch(Exception e)when(attempt==0&&e is HttpRequestException or OperationCanceledException){await Task.Delay(400);}}Feedback.Text="连接成功，模型已返回文本回复。";}finally{IsEnabled=true;}}));
        Card(auxiliary?"辅助模型":"主模型",Ui.Text(shared?"共用主模型地址与密钥":"Base URL",12,BloomTheme.Muted),address,Ui.Text("模型名称",12,BloomTheme.Muted),model,Ui.Text("API Key",12,BloomTheme.Muted),key,state,Ui.Row(save,test),Ui.Button("删除此密钥",()=>Run(()=>{if(shared)throw new InvalidOperationException("此模型正在共用主模型密钥。");if(Runtime.Confirm("删除保存的密钥？使用 AI 前需要重新填写。")){Runtime.CancelAI();Runtime.Vault.Remove(slot);state.Text="密钥已删除";}return Task.CompletedTask;})));
    }
    private void SystemPrompt()
    {
        if(system.Parent is Panel parent)parent.Children.Remove(system);system.Text=Runtime.Settings.SystemPrompt;systemDirty=false;system.Height=270;
        Card("系统提示词",Ui.Text("不超过 2000 字，保存后用于新对话。已有会话保留创建时的设置。",12,BloomTheme.Muted),system,Ui.Row(Ui.Button("保存",()=>Run(()=>{SaveSystem();return Task.CompletedTask;})),Ui.Button("恢复默认内容",()=>{system.Text=AiPrompts.Chat;return Task.CompletedTask;}),Ui.Button("放弃修改",()=>{system.Text=Runtime.Settings.SystemPrompt;systemDirty=false;return Task.CompletedTask;})));
    }
    private void SaveSystem(){if(string.IsNullOrWhiteSpace(system.Text)||TextRules.Count(system.Text)>2000)throw new InvalidOperationException("系统提示词不能为空，且不能超过 2000 字。");Runtime.SaveSettings(Runtime.Settings with{SystemPrompt=system.Text});systemDirty=false;Feedback.Text="已保存，将用于新对话";}
    internal override Task FlushAsync()
    {
        StopRecording();if(systemDirty){using var guard=Runtime.ProtectFocus();var choice=MessageBox.Show("保存对系统提示词的修改？","萌生",MessageBoxButton.YesNoCancel,MessageBoxImage.Question);if(choice==MessageBoxResult.Cancel)throw new InvalidOperationException("已保留修改，请继续编辑。");if(choice==MessageBoxResult.Yes)SaveSystem();else{system.Text=Runtime.Settings.SystemPrompt;systemDirty=false;}}return Task.CompletedTask;
    }
    private void About()
    {
        const string releases="https://github.com/FengLi-AI/JotBloom-Notch-Assistant/releases";
        Card("萌生 · JotBloom",Ui.Text("给闪过的想法，一点空间。",18,BloomTheme.Blue),Ui.Text("记下来，然后继续手头的事。",12,BloomTheme.Muted),Ui.Button("产品官网 ↗",()=>Visit("https://fengli-ai.github.io/JotBloom-Notch-Assistant/")));
        Card("版本 "+AppRuntime.Version,Ui.Button("检查最新 Windows 版本",()=>Run(async()=>{Feedback.Text="正在检查…";using var http=new HttpClient{Timeout=TimeSpan.FromSeconds(15)};http.DefaultRequestHeaders.UserAgent.ParseAdd("JotBloom-Windows/1.0.2");using var response=await http.GetAsync("https://api.github.com/repos/FengLi-AI/JotBloom-Notch-Assistant/releases?per_page=20",HttpCompletionOption.ResponseHeadersRead);response.EnsureSuccessStatusCode();await using var stream=await response.Content.ReadAsStreamAsync();using var json=await JsonDocument.ParseAsync(stream);var matches=json.RootElement.EnumerateArray().Where(r=>!r.GetProperty("draft").GetBoolean()&&r.GetProperty("assets").EnumerateArray().Any(a=>{string n=a.GetProperty("name").GetString()??"";return n.Contains("Windows",StringComparison.OrdinalIgnoreCase)&&n.EndsWith(".exe",StringComparison.OrdinalIgnoreCase);})).ToArray();Feedback.Text=matches.Length==0?"暂未发布 Windows 更新，可在版本页面查看后续版本。":"找到 Windows 发布版本："+matches[0].GetProperty("tag_name").GetString()+"。请打开版本页面核对并下载。";})),Ui.Button("打开版本页面 ↗",()=>Visit(releases)),Ui.Text("检查时连接 GitHub；下载后由你安装。",12,BloomTheme.Muted));
        Card("作者",Ui.Text("李烽立｜Li Fengli"),Ui.Button("邮箱：qq204407676@gmail.com",()=>Visit("mailto:qq204407676@gmail.com")),Ui.Text("微信：feNgL1999_"),Ui.Button("小红书：FengLiAi · 个人主页 ↗",()=>Visit("https://www.xiaohongshu.com/user/profile/69b6dd97000000003303a64d")),Ui.Text("抖音号：N24642464（在抖音内搜索）"),Ui.Text("遇到 Bug 或有功能建议，欢迎通过以上方式联系作者。谢谢你帮助萌生变得更好。",12,BloomTheme.Muted));
    }
    private Task Visit(string url)=>Run(()=>{AppRuntime.OpenLink(url);return Task.CompletedTask;});
}
internal static class AutoStart
{
    internal static void Set(bool enabled)
    {
        string path=Environment.ProcessPath??throw new IOException("无法确认程序位置。");
        if(enabled&&(!path.EndsWith("JotBloom.exe",StringComparison.OrdinalIgnoreCase)||!File.Exists(Path.Combine(Path.GetDirectoryName(path)!,"Uninstall.exe"))))throw new InvalidOperationException("请安装萌生后再开启自动启动。");
        using var key=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");if(enabled)key.SetValue("JotBloom","\""+path+"\" --background");else key.DeleteValue("JotBloom",false);
    }
}
