using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using JotBloom.Windows.Storage;

namespace JotBloom.Windows.Desktop;

internal sealed class SearchPane:BloomPage
{
    private readonly TextBox query=Ui.Editor("搜索灵感、剪贴板和提示词",false);
    private readonly StackPanel filters=new(){Orientation=Orientation.Horizontal},results=new();
    private readonly DispatcherTimer debounce=new(){Interval=TimeSpan.FromMilliseconds(150)};
    private readonly Button more;
    private LibraryKind? kind;
    private int offset,revision;
    private bool searched;
    internal SearchPane(AppRuntime runtime):base(runtime)
    {
        RowDefinitions.Add(new(){Height=GridLength.Auto});RowDefinitions.Add(new(){Height=GridLength.Auto});RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});RowDefinitions.Add(new(){Height=GridLength.Auto});
        Children.Add(query);Grid.SetRow(filters,1);Children.Add(filters);var scroll=Ui.Scroll(results);Grid.SetRow(scroll,2);Children.Add(scroll);
        more=Ui.Button("加载更多",()=>Run(()=>Search(true)));var bottom=new StackPanel();bottom.Children.Add(more);bottom.Children.Add(Feedback);Grid.SetRow(bottom,3);Children.Add(bottom);
        query.TextChanged+=(_,_)=>{revision++;debounce.Stop();debounce.Start();};debounce.Tick+=async(_,_)=>{debounce.Stop();await Run(()=>Search());};query.PreviewKeyDown+=async(_,e)=>{if(e.Key==Key.Enter){debounce.Stop();e.Handled=true;await Run(()=>Search());}};
    }
    internal override async Task ActivateAsync(){query.Focus();if(!searched)await Search();}
    private async Task Search(bool append=false)
    {
        searched=true;int current=++revision;if(!append)offset=0;var found=await Runtime.Store.SearchAsync(query.Text,kind,offset);if(current!=revision)return;
        if(!append)results.Children.Clear();filters.Children.Clear();Filter("全部",null,found.Counts.Values.Sum());foreach(var k in Enum.GetValues<LibraryKind>())Filter(KindName(k),k,found.Counts.GetValueOrDefault(k));
        foreach(var item in found.Items){var title=string.IsNullOrEmpty(item.Title)?JotBloom.Windows.Core.TextRules.Prefix(item.Content.Replace('\n',' '),80):item.Title;
            var button=Ui.Button(KindName(item.Kind)+" · "+title,()=>Run(async()=>{if(item.Kind==LibraryKind.Clipboard)await Runtime.Clipboard!.CopyAsync(item,true);else Runtime.Navigate?.Invoke(item.Kind==LibraryKind.Prompts?"prompts":"inspirations",item.Id);}));button.HorizontalContentAlignment=HorizontalAlignment.Left;button.Content=Ui.Text(KindName(item.Kind)+" · "+title);var menu=new ContextMenu();IDisposable? guard=null;menu.Opened+=(_,_)=>guard=Runtime.ProtectFocus();menu.Closed+=(_,_)=>{guard?.Dispose();guard=null;};var copy=new MenuItem{Header="复制并保留面板"};copy.Click+=async(_,_)=>await Run(()=>Runtime.Clipboard!.CopyAsync(item,false));menu.Items.Add(copy);button.ContextMenu=menu;results.Children.Add(button);}
        offset+=found.Items.Count;more.Visibility=kind is not null&&found.Counts.GetValueOrDefault(kind.Value)>offset?Visibility.Visible:Visibility.Collapsed;
        Feedback.Text=string.IsNullOrWhiteSpace(query.Text)?"输入关键词搜索本地内容。":found.Counts.Values.Sum()==0?"没有找到匹配内容。":"全部分类各展示 2 条；选择分类可查看完整结果。";
    }
    private void Filter(string label,LibraryKind? target,int count){var b=Ui.Button($"{label} {count}",()=>Run(async()=>{kind=target;await Search();}));if(kind==target)b.Foreground=BloomTheme.Blue;filters.Children.Add(b);}
    private static string KindName(LibraryKind kind)=>kind switch{LibraryKind.Clipboard=>"剪贴板",LibraryKind.Prompts=>"提示词",_=>"灵感"};
}
