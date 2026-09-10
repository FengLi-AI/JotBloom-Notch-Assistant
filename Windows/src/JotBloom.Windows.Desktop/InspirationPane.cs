using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using JotBloom.Windows.Storage;

namespace JotBloom.Windows.Desktop;

internal sealed class InspirationPane : Grid
{
    private readonly BloomStore store;
    private readonly TextBox editor = new() {
        AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        Background = BloomTheme.Well, Foreground = BloomTheme.Text, CaretBrush = BloomTheme.Blue,
        BorderThickness = new Thickness(0), Padding = new Thickness(12), FontSize = 14, MinHeight = 50
    };
    private readonly TextBlock status = new() { Foreground = BloomTheme.Muted, TextWrapping = TextWrapping.Wrap, FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button save = PanelWindow.Button("保存灵感  Ctrl+Enter");
    private readonly StackPanel recent = new();
    private bool loading = true, saving;
    private long revision;
    private Task lastDraft = Task.CompletedTask;

    internal InspirationPane(BloomStore store)
    {
        this.store = store;
        Margin = new Thickness(12);
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 50 });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Children.Add(new TextBlock { Text = "捕捉此刻 · 把脑子里的那点东西先记下来", Foreground = BloomTheme.Blue, Margin = new Thickness(0, 0, 0, 8), FontSize = 13 });
        AutomationProperties.SetName(editor, "灵感内容");
        Grid.SetRow(editor, 1); Children.Add(editor);
        var actions = new DockPanel { Margin = new Thickness(0, 7, 0, 7) };
        DockPanel.SetDock(save, Dock.Right); actions.Children.Add(save); actions.Children.Add(status);
        Grid.SetRow(actions, 2); Children.Add(actions);
        var scroll = new ScrollViewer { Content = recent, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroll, 3); Children.Add(scroll);
        editor.IsEnabled = save.IsEnabled = false;
        editor.TextChanged += (_, _) => { if (!loading) QueueDraft(); };
        editor.PreviewKeyDown += async (_, e) => {
            if (e.Key == Key.Enter && Keyboard.Modifiers == ModifierKeys.Control && !saving && !loading) {
                e.Handled = true; await SaveAsync();
            }
        };
        save.Click += async (_, _) => await SaveAsync();
        Loaded += async (_, _) => { if (loading) await LoadAsync(); };
    }
    private async Task LoadAsync()
    {
        try {
            editor.Text = await store.LoadDraftAsync(); await RefreshRecentAsync();
            loading = false; editor.IsEnabled = save.IsEnabled = true;
            status.Text = "输入会自动保留为草稿";
        } catch { status.Text = "数据暂时无法读取。请检查存储磁盘后重新启动。"; }
    }
    private async void QueueDraft()
    {
        long current = ++revision;
        lastDraft = store.PersistDraftAsync(editor.Text);
        status.Text = "正在保留草稿…";
        try { await lastDraft; if (current == revision && !saving) status.Text = "草稿已保留"; }
        catch { if (current == revision) status.Text = "草稿未能写入，请保留当前窗口并检查存储位置。"; }
    }
    private async Task SaveAsync()
    {
        if (loading || saving) return;
        saving = true; editor.IsEnabled = save.IsEnabled = false;
        try {
            await store.SaveAsync(editor.Text);
            loading = true; editor.Clear(); loading = false;
            ++revision; lastDraft = Task.CompletedTask;
            status.Text = "已保存到灵感库";
            try { await RefreshRecentAsync(); }
            catch { status.Text = "已保存，最近记录暂时无法刷新。"; }
        } catch (DuplicateInspirationException e) { status.Text = e.Message; }
        catch (ArgumentException e) { status.Text = e.Message; }
        catch { status.Text = "保存未完成，输入仍在。请检查存储磁盘后重试。"; }
        finally { saving = false; editor.IsEnabled = save.IsEnabled = true; editor.Focus(); }
    }
    private async Task RefreshRecentAsync()
    {
        var items = await store.RecentAsync();
        recent.Children.Clear();
        recent.Children.Add(new TextBlock { Text = "最近灵感", Foreground = BloomTheme.Muted, Margin = new Thickness(0, 0, 0, 5), FontSize = 12 });
        if (items.Count == 0) recent.Children.Add(new TextBlock { Text = "还没有记录，写下第一条想法吧。", Foreground = BloomTheme.Muted, FontSize = 12 });
        foreach (var item in items) {
            var detail = new TextBox {
                Text = item.Body, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, Background = BloomTheme.Well,
                Foreground = BloomTheme.Text, BorderThickness = new Thickness(0), Padding = new Thickness(8),
                MaxHeight = 150, VerticalScrollBarVisibility = ScrollBarVisibility.Auto
            };
            AutomationProperties.SetName(detail, "灵感全文");
            recent.Children.Add(new Expander {
                Header = new TextBlock { Text = string.IsNullOrEmpty(item.Title) ? "未命名灵感" : item.Title, TextTrimming = TextTrimming.CharacterEllipsis },
                Content = detail, Foreground = BloomTheme.Text, Margin = new Thickness(0, 3, 0, 3)
            });
        }
    }
    internal async Task<bool> PrepareExitAsync()
    {
        // Every edit is already queued; prevent another edit racing the exit barrier.
        if (saving) { status.Text = "正在保存，请稍后退出。"; return false; }
        editor.IsEnabled = save.IsEnabled = false;
        try { await lastDraft; return true; }
        catch {
            editor.IsEnabled = save.IsEnabled = !loading;
            status.Text = "草稿尚未写入，已取消退出。请先复制内容或恢复存储磁盘，再重试。";
            // Retry the latest content on the next exit without dropping this warning.
            lastDraft = store.PersistDraftAsync(editor.Text);
            try { await lastDraft; } catch { }
            return false;
        }
    }
}
