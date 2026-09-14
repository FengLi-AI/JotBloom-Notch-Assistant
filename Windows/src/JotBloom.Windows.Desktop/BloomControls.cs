using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace JotBloom.Windows.Desktop;
internal static class BloomControls
{
    internal static void Install()
    {
        var resources=Application.Current.Resources;
        foreach(var (key,brush) in new[]{("BloomWell",BloomTheme.Well),("BloomText",BloomTheme.Text),("BloomMuted",BloomTheme.Muted),("BloomRaised",BloomTheme.Raised),("BloomStroke",BloomTheme.Stroke),("BloomBlue",BloomTheme.Primary),("BloomTrack",BloomTheme.Track),("BloomThumb",BloomTheme.Thumb)})resources[key]=brush;
        var styles=(ResourceDictionary)XamlReader.Parse("""
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
 <Style TargetType="TextBox"><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox"><Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="16"><ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/></Border></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="PasswordBox"><Setter Property="BorderBrush" Value="{DynamicResource BloomStroke}"/><Setter Property="BorderThickness" Value="0.5"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="PasswordBox"><Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="12"><ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/></Border></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="CheckBox"><Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox"><Grid Background="Transparent"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="42"/></Grid.ColumnDefinitions><ContentPresenter VerticalAlignment="Center" Margin="0,0,16,0"/><Border x:Name="Track" Grid.Column="1" Width="38" Height="22" CornerRadius="11" Background="{DynamicResource BloomTrack}" BorderBrush="{DynamicResource BloomStroke}" BorderThickness="0.5"><Ellipse x:Name="Knob" Fill="{DynamicResource BloomThumb}" Width="16" Height="16" HorizontalAlignment="Left" Margin="3,0,0,0"/></Border></Grid><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="Track" Property="Background" Value="{DynamicResource BloomBlue}"/><Setter TargetName="Knob" Property="HorizontalAlignment" Value="Right"/><Setter TargetName="Knob" Property="Margin" Value="0,0,3,0"/><Setter TargetName="Knob" Property="Fill" Value="#F5F8FF"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Track" Property="BorderBrush" Value="{DynamicResource BloomBlue}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 <Style x:Key="BloomThumbStyle" TargetType="Thumb"><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb"><Border Background="{DynamicResource BloomMuted}" Opacity="0.5" Width="3" CornerRadius="1.5" Margin="2,0"/></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="ScrollBar"><Setter Property="Width" Value="8"/><Setter Property="Opacity" Value="0"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar"><Track x:Name="PART_Track" IsDirectionReversed="True" Orientation="Vertical"><Track.Thumb><Thumb Style="{StaticResource BloomThumbStyle}" MinHeight="22"/></Track.Thumb></Track></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="ListBoxItem"><Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="Padding" Value="8"/><Setter Property="Margin" Value="0,2"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem"><Border x:Name="Row" Background="Transparent" CornerRadius="12" Padding="{TemplateBinding Padding}"><ContentPresenter/></Border><ControlTemplate.Triggers><Trigger Property="IsSelected" Value="True"><Setter TargetName="Row" Property="Background" Value="{DynamicResource BloomWell}"/><Setter TargetName="Row" Property="BorderBrush" Value="{DynamicResource BloomBlue}"/><Setter TargetName="Row" Property="BorderThickness" Value="0.5"/></Trigger><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Row" Property="Background" Value="{DynamicResource BloomWell}"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="ComboBox"><Setter Property="Background" Value="{DynamicResource BloomRaised}"/><Setter Property="Foreground" Value="{DynamicResource BloomText}"/><Setter Property="Padding" Value="12,7"/><Setter Property="MinHeight" Value="32"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox"><Grid><ToggleButton Focusable="False" IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent},Mode=TwoWay}"><ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border Background="{DynamicResource BloomRaised}" BorderBrush="{DynamicResource BloomStroke}" BorderThickness="0.75" CornerRadius="10"><TextBlock Text="⌄" Foreground="{DynamicResource BloomMuted}" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,8,0"/></Border></ControlTemplate></ToggleButton.Template></ToggleButton><ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}" Margin="12,6,28,6" VerticalAlignment="Center"/><Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False"><Border Background="{DynamicResource BloomWell}" BorderBrush="{DynamicResource BloomStroke}" BorderThickness="0.5" CornerRadius="10" Padding="6" MinWidth="{Binding ActualWidth,RelativeSource={RelativeSource TemplatedParent}}"><ScrollViewer MaxHeight="260"><ItemsPresenter/></ScrollViewer></Border></Popup></Grid></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="ComboBoxItem"><Setter Property="Foreground" Value="{DynamicResource BloomText}"/><Setter Property="Padding" Value="10,6"/></Style>
</ResourceDictionary>
""");
        resources.MergedDictionaries.Add(styles);
        // This routed handler also covers native editor/list scroll viewers.
        EventManager.RegisterClassHandler(typeof(ScrollViewer),ScrollViewer.ScrollChangedEvent,new ScrollChangedEventHandler(OnScroll));
    }
    private static readonly System.Runtime.CompilerServices.ConditionalWeakTable<ScrollViewer,ScrollMotion> scrolls=new();
    private static void OnScroll(object sender,ScrollChangedEventArgs e)
    {
        if(sender is not ScrollViewer viewer||e.VerticalChange==0)return;
        scrolls.GetValue(viewer,v=>new ScrollMotion(v)).Show();
    }
    private sealed class ScrollMotion
    {
        private readonly ScrollViewer viewer;
        private readonly DispatcherTimer delay=new(){Interval=TimeSpan.FromSeconds(2)};
        internal ScrollMotion(ScrollViewer viewer){this.viewer=viewer;delay.Tick+=(_,_)=>{delay.Stop();Set(false);};viewer.Unloaded+=(_,_)=>delay.Stop();}
        internal void Show(){Set(true);delay.Stop();delay.Start();}
        private void Set(bool show)
        {
            viewer.ApplyTemplate();if(viewer.Template.FindName("PART_VerticalScrollBar",viewer) is not ScrollBar bar)return;
            var move=bar.RenderTransform as TranslateTransform??new TranslateTransform();bar.RenderTransform=move;
            var duration=TimeSpan.FromSeconds(BloomTheme.Animate ? .28 : 0);
            bar.BeginAnimation(UIElement.OpacityProperty,new DoubleAnimation(show?1:0,duration){EasingFunction=new CubicEase{EasingMode=EasingMode.EaseOut}});
            move.BeginAnimation(TranslateTransform.XProperty,new DoubleAnimation(show?0:6,duration){EasingFunction=new CubicEase{EasingMode=EasingMode.EaseOut}});
        }
    }
}
