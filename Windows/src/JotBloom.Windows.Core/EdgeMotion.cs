namespace JotBloom.Windows.Core;

/// <summary>Normalized position, independent of DPI. Retargeting samples the current position.</summary>
public sealed class EdgeMotion
{
    public const double FullDurationMilliseconds = 140;
    public bool VisibleRequested { get; private set; }
    public bool IsComplete { get; private set; } = true;
    public double Progress { get; private set; }
    private double from, duration;
    private long started;

    public void SetVisible(bool visible, long now, bool animate = true)
    {
        Sample(now);
        if (!animate) {
            VisibleRequested = visible; Progress = visible ? 1 : 0; IsComplete = true; return;
        }
        if (visible == VisibleRequested) return;
        VisibleRequested = visible;
        from = Progress; started = now;
        duration = FullDurationMilliseconds * Math.Abs((visible ? 1 : 0) - from);
        IsComplete = duration == 0;
    }

    public double Sample(long now)
    {
        if (IsComplete) return Progress;
        double t = Math.Clamp((now - started) / duration, 0, 1);
        double eased = 1 - Math.Pow(1 - t, 3);
        Progress = from + ((VisibleRequested ? 1 : 0) - from) * eased;
        if (t >= 1) { IsComplete = true; Progress = VisibleRequested ? 1 : 0; }
        return Progress;
    }
}
