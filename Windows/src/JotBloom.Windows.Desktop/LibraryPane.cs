using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using JotBloom.Windows.Storage;

namespace JotBloom.Windows.Desktop;

internal sealed class LibraryPane:BloomPage
{
    private readonly LibraryKind kind;
    private readonly StackPanel tools=new(){Orientation=Orientation.Horizontal};
    private readonly ListBox list=new(){Background=Brushes.Transparent,BorderThickness=new Thickness(0),Foreground=BloomTheme.Text};
    private readonly Grid content=new();
    private readonly TextBox title=Ui.Editor("标题",false),body=Ui.Editor("正文");
    private readonly ComboBox category=new(){ItemsSource=BloomStore.Categories,MinWidth=90};
    private readonly ComboBox filter=new(){MinWidth=100};
    private readonly Button more,undo;
    private readonly DebouncedSave autosave;
    private LibraryItem? selected;
    private PageCursor? cursor;
    private bool detail,loading,newPrompt,favorites,refreshing;
    private string? categoryFilter,undoToken;
    private Point down;
    private double listOffset;
    private readonly SemaphoreSlim saveGate=new(1);
    private bool Edited=>detail&&(newPrompt? !string.IsNullOrWhiteSpace(body.Text)||!string.IsNullOrWhiteSpace(title.Text):selected is not null&&(title.Text!=selected.Title||body.Text!=selected.Content||kind==LibraryKind.Inspirations&&(category.SelectedItem as string)!=selected.Category));
    internal LibraryPane(AppRuntime runtime,LibraryKind kind):base(runtime)
    {
        this.kind=kind;autosave=new(SaveDetail,e=>Feedback.Text=Ui.Error(e));
        RowDefinitions.Add(new(){Height=GridLength.Auto});RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});RowDefinitions.Add(new(){Height=GridLength.Auto});
        if(kind==LibraryKind.Inspirations){filter.ItemsSource=new[]{"全部分类"}.Concat(BloomStore.Categories);filter.SelectedIndex=0;filter.SelectionChanged+=async(_,_)=>{categoryFilter=filter.SelectedIndex==0?null:filter.SelectedItem as string;await Run(()=>Refresh());};tools.Children.Add(filter);}
        if(kind==LibraryKind.Prompts){tools.Children.Add(Ui.Button("新建提示词",()=>Run(NewPrompt)));var favorite=new CheckBox{Content="只看常用",Foreground=BloomTheme.Text,Margin=new Thickness(10),VerticalAlignment=VerticalAlignment.Center};favorite.Checked+=async(_,_)=>{favorites=true;await Run(()=>Refresh());};favorite.Unchecked+=async(_,_)=>{favorites=false;await Run(()=>Refresh());};tools.Children.Add(favorite);}
        tools.Children.Add(Ui.Button("刷新",()=>Run(()=>Refresh())));Children.Add(tools);
        content.Children.Add(list);Grid.SetRow(content,1);Children.Add(content);
        var footer=new StackPanel();more=Ui.Button("加载更多",()=>Run(()=>Refresh(true)));undo=Ui.Button("撤销删除",()=>Run(Undo));undo.Visibility=Visibility.Collapsed;
        footer.Children.Add(Ui.Row(more,undo));footer.Children.Add(Feedback);Grid.SetRow(footer,2);Children.Add(footer);
        title.TextChanged+=(_,_)=>Dirty();body.TextChanged+=(_,_)=>Dirty();category.SelectionChanged+=(_,_)=>Dirty();
        list.PreviewMouseLeftButtonDown+=(_,e)=>down=e.GetPosition(list);
        list.PreviewKeyDown+=async(_,e)=>{if(e.Key==Key.Enter&&list.SelectedItem is ListBoxItem row&&row.Tag is LibraryItem item){e.Handled=true;await Run(()=>Open(item));}};
    }
    private void Dirty(){if(!loading&&detail){Feedback.Text=kind==LibraryKind.Prompts?"有未保存的修改。":"正在保存修改…";if(kind==LibraryKind.Inspirations)autosave.Changed();}}
    internal override Task ActivateAsync()=>detail?Task.CompletedTask:Refresh();
    internal override async Task FlushAsync(){
        if(kind==LibraryKind.Inspirations){await autosave.FlushAsync();return;}
        if(!Edited)return;using var guard=Runtime.ProtectFocus();var choice=MessageBox.Show("保存对提示词的修改？","萌生",MessageBoxButton.YesNoCancel,MessageBoxImage.Question);
        if(choice==MessageBoxResult.Cancel)throw new InvalidOperationException("修改已保留，请继续编辑。");
        if(choice==MessageBoxResult.Yes)await SaveDetail();else{loading=true;body.Text=selected?.Content??"";title.Text=selected?.Title??"";loading=false;}
    }
    internal override async Task<bool> BackAsync()
    {
        if(!detail)return false;
        await FlushAsync();detail=false;newPrompt=false;selected=null;content.Children.Clear();content.Children.Add(list);tools.Visibility=Visibility.Visible;await Refresh();_ = Dispatcher.InvokeAsync(()=>FindScroll(list)?.ScrollToVerticalOffset(listOffset),System.Windows.Threading.DispatcherPriority.Loaded);return true;
    }
    internal async Task OpenId(long id){var item=await Runtime.Store.GetAsync(kind,id);if(item is null)throw new InvalidOperationException("记录已不存在。");await Open(item);}
    private async Task Refresh(bool append=false)
    {
        if(detail||refreshing)return;refreshing=true;
        try{var page=await Runtime.Store.ListAsync(kind,append?cursor:null,categoryFilter,favorites);if(!append)list.Items.Clear();foreach(var item in page.Items)list.Items.Add(Row(item));cursor=page.Next;more.Visibility=cursor is null?Visibility.Collapsed:Visibility.Visible;
            if(list.Items.Count==0)Feedback.Text=kind==LibraryKind.Clipboard?"还没有记录。复制文字、链接或图片后会显示在这里。":"还没有记录。";
        }finally{refreshing=false;}
    }
    private ListBoxItem Row(LibraryItem item)
    {
        var stack=new StackPanel();string heading=kind==LibraryKind.Clipboard?item.ContentType=="image"?"图片":JotBloom.Windows.Core.TextRules.Prefix(item.Content.Replace('\n',' '),90):string.IsNullOrWhiteSpace(item.Title)?"未命名":item.Title;
        stack.Children.Add(Ui.Text((item.Favorite&&kind==LibraryKind.Prompts?"★ ":"")+heading,14));
        if(item.ContentType=="image"&&item.Thumbnail is not null){try{var image=new BitmapImage();image.BeginInit();image.CacheOption=BitmapCacheOption.OnLoad;image.UriSource=new Uri(Runtime.Store.AssetPath(item.Thumbnail));image.DecodePixelWidth=200;image.EndInit();image.Freeze();stack.Children.Add(new Image{Source=image,Height=76,Stretch=Stretch.Uniform,HorizontalAlignment=HorizontalAlignment.Left});}catch{stack.Children.Add(Ui.Text("缩略图暂不可用",11,BloomTheme.Muted));}}
        stack.Children.Add(Ui.Text((kind==LibraryKind.Inspirations?item.Category+" · ":"")+item.Source+"  "+DateTimeOffset.FromUnixTimeMilliseconds(item.Created).ToLocalTime().ToString("MM-dd HH:mm"),11,BloomTheme.Muted));
        var row=new ListBoxItem{Content=Ui.Card(stack),Tag=item,HorizontalContentAlignment=HorizontalAlignment.Stretch,Padding=new Thickness(0),Margin=new Thickness(0,2,0,2),Foreground=BloomTheme.Text};
        row.MouseLeftButtonUp+=async(_,e)=>{if((e.GetPosition(list)-down).Length>5)return;e.Handled=true;await Run(()=>Open(item));};
        var menu=new ContextMenu();IDisposable? focus=null;menu.Opened+=(_,_)=>focus=Runtime.ProtectFocus();menu.Closed+=(_,_)=>{focus?.Dispose();focus=null;};Add("复制并保留面板",()=>Runtime.Clipboard!.CopyAsync(item,false));
        if(kind==LibraryKind.Clipboard&&item.ContentType!="image"){
            Add("保存到提示词库",async()=>{var saved=await Runtime.Store.CreatePromptAsync(item.Content,clipboardId:item.Id);Runtime.ScheduleAI(saved);Runtime.Notify(LibraryKind.Prompts);Feedback.Text="已保存到提示词库";await Refresh();});
            Add("保存到灵感库",async()=>{var saved=await Runtime.Store.ImportClipboardInspirationAsync(item.Id);Runtime.ScheduleAI(saved);Runtime.Notify(LibraryKind.Inspirations);Feedback.Text="已保存到灵感库";});}
        if(kind==LibraryKind.Prompts)Add(item.Favorite?"取消常用":"设为常用",async()=>{await Runtime.Store.SetFavoriteAsync(item.Id,!item.Favorite);await Refresh();});
        if(kind!=LibraryKind.Clipboard){Add("打开编辑",()=>Open(item));Add("置顶",async()=>{if(list.Items.Count>0&&((ListBoxItem)list.Items[0]).Tag is LibraryItem first)await Runtime.Store.MoveBeforeAsync(kind,item.Id,first.Id);await Refresh();});}
        Add("删除",()=>Delete(item));row.ContextMenu=menu;
        void Add(string text,Func<Task> action){var m=new MenuItem{Header=text};m.Click+=async(_,_)=>await Run(action);menu.Items.Add(m);}
        if(kind!=LibraryKind.Clipboard){row.AllowDrop=true;row.MouseMove+=(_,e)=>{if(e.LeftButton==MouseButtonState.Pressed&&(e.GetPosition(list)-down).Length>8){using var guard=Runtime.ProtectFocus();DragDrop.DoDragDrop(row,new DataObject("JotBloom.Library",item),DragDropEffects.Move);}};row.Drop+=async(_,e)=>{if(e.Data.GetData("JotBloom.Library") is LibraryItem source&&source.Kind==kind){e.Handled=true;await Run(async()=>{await Runtime.Store.MoveBeforeAsync(kind,source.Id,item.Id);await Refresh();});}};}
        return row;
    }
    private async Task Open(LibraryItem item){if(kind==LibraryKind.Clipboard){await Runtime.Clipboard!.CopyAsync(item,true);return;}await FlushAsync();if(!detail)listOffset=FindScroll(list)?.VerticalOffset??0;selected=await Runtime.Store.GetAsync(kind,item.Id)??throw new InvalidOperationException("记录已删除。");newPrompt=false;ShowDetail();}
    private async Task NewPrompt(){await FlushAsync();newPrompt=true;selected=null;ShowDetail();}
    private void ShowDetail()
    {
        foreach(var field in new FrameworkElement[]{title,body,category})if(field.Parent is Panel parent)parent.Children.Remove(field);
        loading=true;detail=true;tools.Visibility=Visibility.Collapsed;more.Visibility=Visibility.Collapsed;title.Text=selected?.Title??"";body.Text=selected?.Content??"";category.SelectedItem=selected?.Category??"idea";
        var grid=new Grid();grid.RowDefinitions.Add(new(){Height=GridLength.Auto});grid.RowDefinitions.Add(new(){Height=GridLength.Auto});grid.RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});
        var actions=Ui.Row(Ui.Button("‹ 返回列表",()=>Run(async()=>{await BackAsync();})),Ui.Button("保存修改",()=>Run(async()=>{if(kind==LibraryKind.Inspirations)await autosave.FlushAsync();else await SaveDetail();})));
        if(kind==LibraryKind.Prompts)actions.Children.Add(Ui.Button("另存为新提示词",()=>Run(async()=>{var saved=await Runtime.Store.CreatePromptAsync(body.Text,string.IsNullOrWhiteSpace(title.Text)?null:title.Text);Runtime.ScheduleAI(saved);selected=saved;newPrompt=false;ShowDetail();Runtime.Notify(kind);Feedback.Text="已另存为新提示词，原记录保持不变。";})));else actions.Children.Add(category);
        grid.Children.Add(actions);Grid.SetRow(title,1);grid.Children.Add(title);Grid.SetRow(body,2);grid.Children.Add(body);body.Margin=new Thickness(0,8,0,0);
        content.Children.Clear();content.Children.Add(grid);Feedback.Text=kind==LibraryKind.Prompts?"修改后点击保存；另存会创建新记录。":"修改会自动保存；返回时会确认写入完成。";loading=false;
    }
    private async Task SaveDetail()
    {
        await saveGate.WaitAsync();try{if(!detail||!Edited)return;
        if(newPrompt){var created=await Runtime.Store.CreatePromptAsync(body.Text,string.IsNullOrWhiteSpace(title.Text)?null:title.Text);selected=created;newPrompt=false;Runtime.ScheduleAI(created);}
        else if(selected is not null)selected=await Runtime.Store.UpdateAsync(selected,title.Text,body.Text,category.SelectedItem as string??selected.Category);
        loading=true;title.Text=selected!.Title;body.Text=selected.Content;category.SelectedItem=selected.Category;loading=false;Feedback.Text="已保存";Runtime.Notify(kind);
        }finally{saveGate.Release();}
    }
    private static ScrollViewer? FindScroll(DependencyObject parent){if(parent is ScrollViewer scroll)return scroll;for(int i=0;i<VisualTreeHelper.GetChildrenCount(parent);i++){var found=FindScroll(VisualTreeHelper.GetChild(parent,i));if(found is not null)return found;}return null;}
    private async Task Delete(LibraryItem item)
    {
        var removed=await Runtime.Store.DeleteAsync(kind,item.Id);undoToken=removed.Token;undo.Visibility=Visibility.Visible;Feedback.Text="已删除，3 秒内可撤销。";await Refresh();Runtime.Notify(kind);
        await Task.Delay(3000);if(undoToken==removed.Token){undo.Visibility=Visibility.Collapsed;undoToken=null;}
    }
    private async Task Undo(){if(undoToken is not null){bool restored=await Runtime.Store.UndoAsync(undoToken);undo.Visibility=Visibility.Collapsed;Feedback.Text=restored?"已恢复":"撤销时间已过";undoToken=null;await Refresh();Runtime.Notify(kind);}}
}
