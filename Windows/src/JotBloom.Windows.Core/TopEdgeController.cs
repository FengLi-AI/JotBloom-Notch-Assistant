namespace JotBloom.Windows.Core;

public enum EntryState { Hidden, HintVisible, PanelVisible }

/// <summary>Pure state machine: no hooks, windows, timers, data access or animation callbacks.</summary>
public sealed class TopEdgeController
{
    public const long LeaveDelayMilliseconds = 200;
    public EntryState State { get; private set; } = EntryState.Hidden;
    public DisplayArea? Display { get; private set; }
    private long? leaveStarted;
    private bool armed = true;

    public void Observe(DisplayArea display, PixelPoint pointer, long nowMilliseconds, bool mouseEntryAllowed)
    {
        display.Validate();
        if (State == EntryState.PanelVisible) return;
        if (Display != display)
        {
            Display = display;
            State = EntryState.Hidden;
            leaveStarted = null;
        }
        bool atEdge = TopEdgeGeometry.Trigger(display).Contains(pointer);
        if (!atEdge) armed = true;
        if (!mouseEntryAllowed)
        {
            State = EntryState.Hidden;
            leaveStarted = null;
            armed = false;
            return;
        }
        if (State == EntryState.Hidden)
        {
            if (armed && atEdge) State = EntryState.HintVisible;
            return;
        }
        if (TopEdgeGeometry.Hint(display).Contains(pointer))
        {
            leaveStarted = null;
            return;
        }
        leaveStarted ??= nowMilliseconds;
        if (nowMilliseconds - leaveStarted >= LeaveDelayMilliseconds)
        {
            State = EntryState.Hidden;
            leaveStarted = null;
        }
    }

    public bool ClickHint()
    {
        if (State != EntryState.HintVisible) return false;
        State = EntryState.PanelVisible;
        leaveStarted = null;
        return true;
    }

    public void ToggleShortcut(DisplayArea display)
    {
        display.Validate();
        if (State == EntryState.PanelVisible) { HidePanel(); return; }
        Display = display;
        State = EntryState.PanelVisible;
        leaveStarted = null;
    }

    public void HidePanel()
    {
        State = EntryState.Hidden;
        leaveStarted = null;
        armed = false;
    }

    public void Suspend()
    {
        State = EntryState.Hidden;
        Display = null;
        leaveStarted = null;
        armed = false;
    }
}
