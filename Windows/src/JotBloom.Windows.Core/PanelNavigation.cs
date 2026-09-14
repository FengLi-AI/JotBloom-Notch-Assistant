namespace JotBloom.Windows.Core;

public sealed class PanelNavigation(string initial = "input")
{
    public string Current { get; private set; } = initial;
    public bool OrdinaryExpanded { get; private set; }
    public bool Expanded { get; private set; } = initial is "chat" or "search";
    public void Select(string page)
    {
        Current = page;
        Expanded = page is "chat" or "search" or "settings" || OrdinaryExpanded;
    }
    public void Resize(bool expanded)
    {
        Expanded = expanded;
        if (Current is not ("chat" or "search" or "settings")) OrdinaryExpanded = expanded;
    }
}
