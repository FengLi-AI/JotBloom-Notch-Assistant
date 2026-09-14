using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using JotBloom.Windows.Storage;

namespace JotBloom.Windows.Desktop;

internal sealed class InputPane:BloomPage
{
    private readonly TextBox editor=Ui.Editor("灵感内容");
    private readonly TextBlock placeholder=Ui.Text("把脑子里的那点东西，先记下来。",14,BloomTheme.Muted);
    private readonly StackPanel recent=new();
    private readonly DebouncedSave drafts;
    private readonly ScrollViewer recentScroll;
    private bool loading=true,composing,saving;
    internal InputPane(AppRuntime runtime):base(runtime)
    {
        drafts=new(async()=>{await Runtime.Store.PersistDraftAsync(editor.Text);Feedback.Text="草稿已保留";},e=>Feedback.Text=Ui.Error(e));
        RowDefinitions.Add(new(){Height=new GridLength(1,GridUnitType.Star)});RowDefinitions.Add(new(){Height=GridLength.Auto});RowDefinitions.Add(new(){Height=new GridLength(0)});
        var input=new Grid();input.Children.Add(editor);editor.Padding=new Thickness(14,44,14,14);
        var capture=Ui.Text("捕捉此刻",12,BloomTheme.Blue);capture.Margin=new Thickness(36,14,14,0);capture.VerticalAlignment=VerticalAlignment.Top;input.Children.Add(capture);
        input.Children.Add(new BloomIcon("bulb"){Ink=BloomTheme.Blue,Width=16,Height=16,HorizontalAlignment=HorizontalAlignment.Left,VerticalAlignment=VerticalAlignment.Top,Margin=new Thickness(14,14,0,0)});placeholder.Margin=new Thickness(14,48,14,0);placeholder.IsHitTestVisible=false;input.Children.Add(placeholder);Children.Add(input);
        var actions=Ui.Row(Ui.Button("保存到提示词",()=>Run(()=>Save(true))),Ui.Accent("保存灵感","check","blue",()=>Run(()=>Save(false))),Ui.Accent("AI 探讨","sparkles","purple",()=>Run(Discuss)));
        actions.HorizontalAlignment=HorizontalAlignment.Right;actions.Margin=new Thickness(0,12,42,0);
        var bar=new Grid();bar.Children.Add(actions);Feedback.VerticalAlignment=VerticalAlignment.Bottom;Feedback.MaxWidth=120;Feedback.HorizontalAlignment=HorizontalAlignment.Left;bar.Children.Add(Feedback);Grid.SetRow(bar,1);Children.Add(bar);
        recentScroll=Ui.Scroll(recent);Grid.SetRow(recentScroll,2);Children.Add(recentScroll);recentScroll.Visibility=Visibility.Collapsed;
        editor.TextChanged+=(_,_)=>{if(!loading){drafts.Changed();Feedback.Text="正在保留草稿…";}Hint();};
        TextCompositionManager.AddPreviewTextInputStartHandler(editor,(_,_)=>{composing=true;Hint();});
        TextCompositionManager.AddPreviewTextInputHandler(editor,(_,_)=>{composing=false;Hint();});
        editor.LostKeyboardFocus+=(_,_)=>{composing=false;Hint();};
        editor.PreviewKeyDown+=async(_,e)=>{if(e.Key==Key.Enter&&Keyboard.Modifiers==ModifierKeys.Control&&!composing){e.Handled=true;await Run(()=>Save(false));}};
    }
    internal override void SetExpanded(bool expanded){RowDefinitions[2].Height=expanded?new GridLength(.7,GridUnitType.Star):new GridLength(0);recentScroll.Visibility=expanded?Visibility.Visible:Visibility.Collapsed;}
    private void Hint()=>placeholder.Visibility=editor.Text.Length==0&&!composing?Visibility.Visible:Visibility.Collapsed;
    internal override async Task ActivateAsync(){if(loading){editor.Text=await Runtime.Store.LoadDraftAsync();loading=false;Hint();}await Recent();}
    internal override Task FlushAsync()=>drafts.FlushAsync();
    private async Task Save(bool prompt)
    {
        if(saving)return;saving=true;IsEnabled=false;
        try{await FlushAsync();LibraryItem item;
            if(prompt)item=await Runtime.Store.CreatePromptAsync(editor.Text,consumeDraft:true);
            else{var saved=await Runtime.Store.SaveAsync(editor.Text);item=(await Runtime.Store.GetAsync(LibraryKind.Inspirations,saved.Id))!;}
            loading=true;drafts.Clear();editor.Clear();loading=false;Hint();Feedback.Text=prompt?"已存入提示词库":"已保存到灵感库";Runtime.ScheduleAI(item);Runtime.Notify(item.Kind);await Recent();
        }finally{saving=false;IsEnabled=true;editor.Focus();}
    }
    private async Task Discuss(){if(saving)return;if(string.IsNullOrWhiteSpace(editor.Text))throw new ArgumentException("先写下一点想法吧。");saving=true;IsEnabled=false;try{await FlushAsync();if(Runtime.Discuss is not null&&await Runtime.Discuss(editor.Text)){loading=true;editor.Clear();drafts.Clear();loading=false;Hint();}}finally{saving=false;IsEnabled=true;}}

    private async Task Recent()
    {
        var items=await Runtime.Store.RecentAsync();recent.Children.Clear();recent.Children.Add(Ui.Text("最近灵感",11,BloomTheme.Muted));
        foreach(var item in items)recent.Children.Add(Ui.Button(string.IsNullOrEmpty(item.Title)?"未命名灵感":item.Title,()=>{Runtime.Navigate?.Invoke("inspirations",item.Id);return Task.CompletedTask;}));
        if(items.Count==0)recent.Children.Add(Ui.Text("还没有记录，写下第一条想法吧。",12,BloomTheme.Muted));
    }
}
