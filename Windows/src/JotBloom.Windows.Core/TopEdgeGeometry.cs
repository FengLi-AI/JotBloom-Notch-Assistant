namespace JotBloom.Windows.Core;

// All coordinates at this boundary are physical pixels, not WPF device-independent units.
public readonly record struct PixelPoint(int X, int Y);
public readonly record struct PixelRect(int Left, int Top, int Width, int Height)
{
    public int Right => Left + Width;
    public int Bottom => Top + Height;
    public bool Contains(PixelPoint p) => p.X >= Left && p.X < Right && p.Y >= Top && p.Y < Bottom;
}

public readonly record struct DisplayArea(PixelRect Bounds, double Scale)
{
    public void Validate()
    {
        if (Bounds.Width <= 0 || Bounds.Height <= 0 || !double.IsFinite(Scale) || Scale <= 0)
            throw new ArgumentOutOfRangeException(nameof(DisplayArea));
    }
}

public static class TopEdgeGeometry
{
    public static PixelRect Trigger(DisplayArea display)
    {
        display.Validate();
        var width = Math.Min(display.Bounds.Width, Math.Max(1, (int)Math.Round(300 * display.Scale)));
        return new(display.Bounds.Left + (display.Bounds.Width - width) / 2, display.Bounds.Top, width, 1);
    }

    public static PixelRect Hint(DisplayArea display)
    {
        var trigger = Trigger(display);
        return trigger with { Height = Math.Min(display.Bounds.Height, Math.Max(1, (int)Math.Round(10 * display.Scale))) };
    }

    public static PixelRect Panel(DisplayArea display, bool expanded)
    {
        display.Validate();
        var width = Math.Min(display.Bounds.Width, (int)Math.Round(640 * display.Scale));
        var height = Math.Min(display.Bounds.Height, (int)Math.Round((expanded ? 700 : 300) * display.Scale));
        return new(display.Bounds.Left + (display.Bounds.Width - width) / 2, display.Bounds.Top, width, height);
    }
}
