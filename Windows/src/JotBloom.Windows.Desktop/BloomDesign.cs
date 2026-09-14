using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace JotBloom.Windows.Desktop;

internal static class BloomTheme
{
    internal static bool Light { get; private set; }
    internal static bool ReduceMotion { get; set; }
    internal static bool Animate => !ReduceMotion && SystemParameters.ClientAreaAnimation;
    internal static SolidColorBrush Brush(string hex) { var b=new SolidColorBrush(ColorOf(hex));b.Freeze();return b; }
    internal static Color ColorOf(string hex)=>(Color)ColorConverter.ConvertFromString(hex);
    // Shared mutable brushes update existing editors without rebuilding pages or losing drafts.
    internal static readonly SolidColorBrush Shell=new(),Surface=new(),Well=new(),Raised=new(),Text=new(),Muted=new(),Blue=new(),Stroke=new(),Selected=new(),Bubble=new(),Track=new(),Thumb=new(),Primary=new();
    internal static readonly LinearGradientBrush Rim=new(Colors.Transparent,ColorOf("#28FFFFFF"),90);
    internal static readonly FontFamily LabelFont=new(new Uri("pack://application:,,,/"),"./Assets/Fonts/#MiSans");
    internal static readonly FontFamily BodyFont=new(new Uri("pack://application:,,,/"),"./Assets/Fonts/#MiSans Normal");
    static BloomTheme(){Apply("dark");}
    internal static void Apply(string appearance)
    {
        Light=appearance=="light";Rim.GradientStops[1].Color=ColorOf(Light?"#24000000":"#28FFFFFF");
        var brushes=new[]{Shell,Surface,Well,Raised,Text,Muted,Blue,Stroke,Selected,Bubble,Track,Thumb,Primary};
        var dark=new[]{"#080A0E","#14171D","#191D25","#272D37","#EDF0F6","#AEBBCF","#3B7DFF","#303640","#070A0E","#183D92","#111720","#AEBBCF","#1955E2"};
        var light=new[]{"#EDEFF2","#F6F7F9","#FAFBFC","#FCFDFE","#242A34","#616B7B","#1E5DE0","#DCE1E9","#E4E8EF","#DAE8FF","#D1D7E0","#F7F9FC","#427BF1"};
        for(int i=0;i<brushes.Length;i++)brushes[i].Color=ColorOf((Light?light:dark)[i]);
    }
    internal static void Enter(UIElement view)
    {
        if(!Animate)return;
        view.BeginAnimation(UIElement.OpacityProperty,new DoubleAnimation(.25,1,TimeSpan.FromSeconds(.44)){EasingFunction=new CubicEase{EasingMode=EasingMode.EaseOut}});
        var move=new TranslateTransform();view.RenderTransform=move;
        move.BeginAnimation(TranslateTransform.YProperty,new DoubleAnimation(5,0,TimeSpan.FromSeconds(.44)){EasingFunction=new CubicEase{EasingMode=EasingMode.EaseOut}});
    }
}

internal sealed class BloomButton:Button
{
    internal string? Icon {get;set;}
    internal readonly string LabelText;
    internal string Accent {get;set;}="";
    internal bool Plain {get;set;}
    internal bool VerticalLabel {get;set;}
    private readonly double seed=Random.Shared.NextDouble()*100;
    private static readonly List<WeakReference<BloomButton>> buttons=[];
    private static readonly DispatcherTimer timer=new(TimeSpan.FromMilliseconds(40),DispatcherPriority.Render,(_,_)=>Tick(),Dispatcher.CurrentDispatcher);
    internal BloomButton(string text)
    {
        LabelText=text;Content=text;FontSize=13;FontFamily=BloomTheme.LabelFont;FontWeight=FontWeights.Normal;
        Foreground=BloomTheme.Text;Padding=new Thickness(14,0,14,0);Height=34;MinWidth=34;Margin=new Thickness(0,0,8,0);
        HorizontalContentAlignment=HorizontalAlignment.Center;VerticalContentAlignment=VerticalAlignment.Center;Cursor=Cursors.Hand;
        Background=Brushes.Transparent;BorderThickness=new Thickness(0);FocusVisualStyle=null;
        var presenter=new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetBinding(ContentPresenter.ContentProperty,new Binding("Content"){RelativeSource=RelativeSource.TemplatedParent});
        presenter.SetBinding(FrameworkElement.MarginProperty,new Binding("Padding"){RelativeSource=RelativeSource.TemplatedParent});
        presenter.SetValue(FrameworkElement.HorizontalAlignmentProperty,HorizontalAlignment.Center);
        presenter.SetValue(FrameworkElement.VerticalAlignmentProperty,VerticalAlignment.Center);
        Template=new ControlTemplate(typeof(Button)){VisualTree=presenter};
        AutomationProperties.SetName(this,text);
        buttons.Add(new(this));timer.Start();
        Loaded+=(_,_)=>RefreshLabel();IsEnabledChanged+=(_,_)=>UpdateInk();
    }
    private static void Tick()
    {
        for(int i=buttons.Count-1;i>=0;i--){if(!buttons[i].TryGetTarget(out var b)){buttons.RemoveAt(i);continue;}if(b.IsVisible){b.UpdateInk();if(b.Accent!=""&&BloomTheme.Animate)b.InvalidateVisual();}}
    }
    internal void RefreshLabel()
    {
        if(Content is not string text||Icon is null)return;
        var group=new StackPanel{Orientation=VerticalLabel?Orientation.Vertical:Orientation.Horizontal,VerticalAlignment=VerticalAlignment.Center,HorizontalAlignment=HorizontalAlignment.Center};
        var icon=new BloomIcon(Icon){Width=16,Height=16,Margin=VerticalLabel?new Thickness(0,0,0,4):new Thickness(0,0,text.Length==0?0:7,0)};
        icon.SetBinding(BloomIcon.InkProperty,new Binding("Foreground"){Source=this});group.Children.Add(icon);
        if(text.Length>0)group.Children.Add(new TextBlock{Text=text,VerticalAlignment=VerticalAlignment.Center,HorizontalAlignment=HorizontalAlignment.Center});
        Content=group;
    }
    private void UpdateInk(){Foreground=Accent!=""?(IsEnabled?Brushes.White:BloomTheme.Brush("#80FFFFFF")):(Plain?BloomTheme.Muted:BloomTheme.Text);}
    protected override void OnRender(DrawingContext dc)
    {
        UpdateInk();var rect=new Rect(.375,.375,Math.Max(0,ActualWidth-.75),Math.Max(0,ActualHeight-.75));
        double radius=VerticalLabel?16:12;dc.PushOpacity(IsPressed ? .86 : 1);
        if((!Plain||Accent!="")&&Accent!="ink"){
            dc.PushClip(new RectangleGeometry(rect,radius,radius));
            if(Accent=="")dc.DrawRoundedRectangle(BloomTheme.Raised,null,rect,radius,radius);
            else{
                dc.PushOpacity(IsEnabled?1:.72);
                bool purple=Accent=="purple";double t=BloomTheme.Animate?Environment.TickCount64/7000.0+seed:seed;
                var gradient=new LinearGradientBrush(BloomTheme.ColorOf(purple?(BloomTheme.Light?"#A76AF3":"#7039E5"):(BloomTheme.Light?"#5783FF":"#214FEA")),BloomTheme.ColorOf(purple?(BloomTheme.Light?"#CA69DE":"#A012D4"):(BloomTheme.Light?"#279FEE":"#006DE0")),25);
                dc.DrawRectangle(gradient,null,rect);
                for(int i=0;i<3;i++){
                    var color=BloomTheme.ColorOf(purple?(i==0?"#BC28EB":i==1?"#704CFF":"#E66DBD"):(i==0?"#473EFF":i==1?"#00BDF0":"#3294FF"));color.A=(byte)(BloomTheme.Light?115:155);
                    var radial=new RadialGradientBrush(color,Colors.Transparent){Center=new Point(.5+.46*Math.Sin(t*(.39+i*.12)+i*2),.5+.5*Math.Cos(t*(.27+i*.15)+i)),GradientOrigin=new Point(.5+.46*Math.Sin(t*(.39+i*.12)+i*2),.5+.5*Math.Cos(t*(.27+i*.15)+i)),RadiusX=.72,RadiusY=1.3};dc.DrawRectangle(radial,null,rect);
                }dc.Pop();
            }
            dc.Pop();
            var edge=new LinearGradientBrush(BloomTheme.ColorOf(BloomTheme.Light?"#90FFFFFF":"#29FFFFFF"),Colors.Transparent,90);dc.DrawRoundedRectangle(null,new Pen(edge,.75),rect,radius,radius);
        }
        if(IsMouseOver)dc.DrawRoundedRectangle(BloomTheme.Brush("#0CFFFFFF"),null,rect,radius,radius);
        if(IsKeyboardFocused)dc.DrawRoundedRectangle(null,new Pen(BloomTheme.Blue,1),new Rect(1.5,1.5,Math.Max(0,ActualWidth-3),Math.Max(0,ActualHeight-3)),radius,radius);
        dc.Pop();
    }
}
internal sealed class BloomIcon(string name):FrameworkElement
{
    internal static readonly DependencyProperty InkProperty=DependencyProperty.Register("Ink",typeof(Brush),typeof(BloomIcon),new FrameworkPropertyMetadata(Brushes.White,FrameworkPropertyMetadataOptions.AffectsRender));
    public Brush Ink {get=>(Brush)GetValue(InkProperty);set=>SetValue(InkProperty,value);}
    protected override void OnRender(DrawingContext dc){if(!BloomIcons.Paths.TryGetValue(name,out var path))return;dc.PushTransform(new ScaleTransform(ActualWidth/24,ActualHeight/24));dc.DrawGeometry(null,new Pen(Ink,1.8){StartLineCap=PenLineCap.Round,EndLineCap=PenLineCap.Round,LineJoin=PenLineJoin.Round},Geometry.Parse(path));dc.Pop();}
}

internal sealed class BloomNavigation:Grid
{
    private readonly bool horizontal;
    private readonly StackPanel items;
    private readonly BloomButton highlight=new(""){Accent="blue",IsHitTestVisible=false,Margin=new Thickness(0),HorizontalAlignment=HorizontalAlignment.Left,VerticalAlignment=VerticalAlignment.Top};
    private readonly TranslateTransform offset=new();
    private readonly List<(string key,BloomButton button)> entries=[];
    private string selected="";
    internal BloomNavigation(bool horizontal=false)
    {
        this.horizontal=horizontal;Background=Brushes.Transparent;
        items=new(){Orientation=horizontal?Orientation.Horizontal:Orientation.Vertical};
        highlight.RenderTransform=offset;Children.Add(highlight);Children.Add(items);Margin=new Thickness(4);
        SizeChanged+=(_,_)=>Position(false);
    }
    internal void SetVertical(bool vertical){if(horizontal)return;foreach(var e in entries){e.button.VerticalLabel=vertical;e.button.Height=vertical?64:38;e.button.Content=e.button.LabelText;e.button.RefreshLabel();}Position(false);}
    internal FrameworkElement ElementFor(string key)=>entries.First(e=>e.key==key).button;
    internal void Clear(){entries.Clear();items.Children.Clear();}
    internal void Add(string key,string text,string icon,Func<Task> action,bool vertical=false)
    {
        var b=new BloomButton(text){Plain=true,Icon=icon,VerticalLabel=vertical,Height=vertical?64:horizontal?28:42,Margin=new Thickness(0),Padding=new Thickness(horizontal?10:12,0,horizontal?10:12,0),HorizontalAlignment=HorizontalAlignment.Stretch};
        if(horizontal)b.MinWidth=70;else b.MinWidth=80;
        b.Click+=async(_,_)=>await action();items.Children.Add(b);entries.Add((key,b));
    }
    internal void Select(string key){selected=key;Position(true);}
    private void Position(bool animate)
    {
        var entry=entries.FirstOrDefault(e=>e.key==selected);if(entry.button is null)return;
        foreach(var e in entries){e.button.Accent=e.key==selected?"ink":"";e.button.InvalidateVisual();}
        // Ink-only selected buttons let one continuous plate move underneath the labels.
        UpdateLayout();var p=entry.button.TranslatePoint(new Point(),this);highlight.Width=entry.button.ActualWidth;highlight.Height=entry.button.ActualHeight;
        if(animate&&BloomTheme.Animate){offset.BeginAnimation(TranslateTransform.XProperty,new DoubleAnimation(p.X,TimeSpan.FromSeconds(.44)){EasingFunction=new CubicEase{EasingMode=EasingMode.EaseInOut}});offset.BeginAnimation(TranslateTransform.YProperty,new DoubleAnimation(p.Y,TimeSpan.FromSeconds(.44)){EasingFunction=new CubicEase{EasingMode=EasingMode.EaseInOut}});}
        else{offset.BeginAnimation(TranslateTransform.XProperty,null);offset.BeginAnimation(TranslateTransform.YProperty,null);offset.X=p.X;offset.Y=p.Y;}
    }
}

internal sealed class BloomSwitch:CheckBox
{
    private static readonly DependencyProperty ProgressProperty=DependencyProperty.Register("Progress",typeof(double),typeof(BloomSwitch),new FrameworkPropertyMetadata(0d,FrameworkPropertyMetadataOptions.AffectsRender));
    internal BloomSwitch()
    {
        FontFamily=BloomTheme.LabelFont;FontSize=13;MinHeight=28;HorizontalContentAlignment=HorizontalAlignment.Stretch;FocusVisualStyle=null;
        var presenter=new FrameworkElementFactory(typeof(ContentPresenter));presenter.SetBinding(ContentPresenter.ContentProperty,new Binding("Content"){RelativeSource=RelativeSource.TemplatedParent});presenter.SetValue(FrameworkElement.MarginProperty,new Thickness(0,0,56,0));presenter.SetValue(FrameworkElement.VerticalAlignmentProperty,VerticalAlignment.Center);Template=new ControlTemplate(typeof(CheckBox)){VisualTree=presenter};
    }
    protected override void OnChecked(RoutedEventArgs e){base.OnChecked(e);Move(true);}
    protected override void OnUnchecked(RoutedEventArgs e){base.OnUnchecked(e);Move(false);}
    private void Move(bool value){BeginAnimation(ProgressProperty,new DoubleAnimation(value?1:0,TimeSpan.FromSeconds(BloomTheme.Animate&&IsLoaded ? .24 : 0)){EasingFunction=new CubicEase{EasingMode=EasingMode.EaseOut}});}
    protected override void OnRender(DrawingContext dc)
    {
        double p=(double)GetValue(ProgressProperty);var rect=new Rect(Math.Max(0,ActualWidth-38),Math.Max(0,(ActualHeight-22)/2),38,22);
        dc.DrawRoundedRectangle(BloomTheme.Track,new Pen(BloomTheme.Stroke,.5),rect,11,11);dc.PushOpacity(p);dc.DrawRoundedRectangle(BloomTheme.Primary,null,rect,11,11);dc.Pop();dc.DrawEllipse(IsChecked==true?Brushes.White:BloomTheme.Thumb,null,new Point(rect.X+11+16*p,rect.Y+11),8,8);
        if(IsKeyboardFocused)dc.DrawRoundedRectangle(null,new Pen(BloomTheme.Blue,1),rect,11,11);
    }
}
