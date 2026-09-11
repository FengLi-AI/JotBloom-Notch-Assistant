using JotBloom.Windows.Core;

var screen = new DisplayArea(new(0, 0, 1920, 1080), 1);
int passed = 0;
void Check(string name, Action run)
{
    try { run(); passed++; Console.WriteLine($"PASS {name}"); }
    catch (Exception error) { Console.Error.WriteLine($"FAIL {name}: {error.Message}"); Environment.Exit(1); }
}
void Require(bool condition) { if (!condition) throw new Exception("Contract not met"); }
TopEdgeController Hint()
{
    var controller = new TopEdgeController();
    controller.Observe(screen, new(960, 0), 0, true);
    return controller;
}

Check("1080p centered 300px interval", () => Require(TopEdgeGeometry.Trigger(screen) == new PixelRect(810, 0, 300, 1)));
Check("only top physical row", () => {
    var r = TopEdgeGeometry.Trigger(screen);
    Require(r.Contains(new(810, 0)) && r.Contains(new(1109, 0)));
    Require(!r.Contains(new(809, 0)) && !r.Contains(new(1110, 0)) && !r.Contains(new(960, 1)) && !r.Contains(new(960, -1)));
});
Check("mixed DPI width scales but trigger height does not", () => {
    foreach (double scale in new[] { 1.0, 1.25, 1.5, 2.0 }) {
        var r = TopEdgeGeometry.Trigger(screen with { Scale = scale });
        Require(r.Width == (int)(300 * scale) && r.Height == 1);
    }
});
Check("negative monitor origin", () => {
    var d = new DisplayArea(new(-1920, -1080, 1920, 1080), 1);
    Require(TopEdgeGeometry.Trigger(d) == new PixelRect(-1110, -1080, 300, 1));
});
Check("small screen clamps panel and hint", () => {
    var d = new DisplayArea(new(5, 6, 200, 150), 2);
    Require(TopEdgeGeometry.Trigger(d).Width == 200 && TopEdgeGeometry.Panel(d, true) == d.Bounds);
});
Check("invalid scale rejected", () => {
    try { TopEdgeGeometry.Trigger(screen with { Scale = double.NaN }); }
    catch (ArgumentOutOfRangeException) { return; }
    throw new Exception("Invalid geometry accepted");
});
Check("near edge does not reveal", () => {
    var c = new TopEdgeController(); c.Observe(screen, new(960, 1), 0, true); Require(c.State == EntryState.Hidden);
});
Check("touch reveals hint only", () => Require(Hint().State == EntryState.HintVisible));
Check("pointer may move down to click hint", () => {
    var c = Hint(); c.Observe(screen, new(960, 8), 500, true);
    Require(c.State == EntryState.HintVisible && c.ClickHint() && c.State == EntryState.PanelVisible);
});
Check("leave waits 200ms", () => {
    var c = Hint(); c.Observe(screen, new(960, 20), 10, true); c.Observe(screen, new(960, 20), 209, true);
    Require(c.State == EntryState.HintVisible); c.Observe(screen, new(960, 20), 210, true); Require(c.State == EntryState.Hidden);
});
Check("return cancels pending hide", () => {
    var c = Hint(); c.Observe(screen, new(960, 20), 10, true); c.Observe(screen, new(960, 5), 100, true);
    c.Observe(screen, new(960, 5), 500, true); Require(c.State == EntryState.HintVisible);
});
Check("shortcut bypasses hint", () => {
    var c = new TopEdgeController(); c.ToggleShortcut(screen); Require(c.State == EntryState.PanelVisible);
    c.ToggleShortcut(screen); Require(c.State == EntryState.Hidden);
});
Check("panel suppresses hint", () => {
    var c = Hint(); c.ClickHint(); c.Observe(screen, new(960, 0), 100, true); Require(c.State == EntryState.PanelVisible);
});
Check("collapse requires leave and reenter", () => {
    var c = Hint(); c.ClickHint(); c.HidePanel(); c.Observe(screen, new(960, 0), 100, true);
    Require(c.State == EntryState.Hidden); c.Observe(screen, new(960, 5), 200, true);
    c.Observe(screen, new(960, 0), 300, true); Require(c.State == EntryState.HintVisible);
});
Check("drag or fullscreen suppresses mouse but not shortcut", () => {
    var c = Hint(); c.Observe(screen, new(960, 0), 100, false); Require(c.State == EntryState.Hidden);
    c.ToggleShortcut(screen); Require(c.State == EntryState.PanelVisible);
});
Check("display change discards old hint", () => {
    var c = Hint(); c.Observe(new(new(1920, 0, 1920, 1080), 1), new(2000, 100), 100, true);
    Require(c.State == EntryState.Hidden);
});
Check("suspend clears panel and stale display", () => {
    var c = Hint(); c.ClickHint(); c.Suspend(); Require(c.State == EntryState.Hidden && c.Display == null);
});
Check("hidden hint cannot be clicked", () => Require(!new TopEdgeController().ClickHint()));
Check("motion opens and closes at its exact endpoints", () => {
    var m = new EdgeMotion(); Require(m.IsComplete && m.Progress == 0);
    m.SetVisible(true, 0); Require(m.Sample(0) == 0 && !m.IsComplete);
    Require(m.Sample(140) == 1 && m.IsComplete);
    m.SetVisible(false, 200); Require(m.Sample(340) == 0 && m.IsComplete);
});
Check("hide reverses an opening without a position jump", () => {
    var m = new EdgeMotion(); m.SetVisible(true, 0); double at = m.Sample(50);
    m.SetVisible(false, 50); Require(m.Sample(50) == at);
    Require(m.Sample(60) < at && m.Sample(200) == 0);
});
Check("reopen interrupts closing without an obsolete hide", () => {
    var m = new EdgeMotion(); m.SetVisible(true, 0, animate: false); m.SetVisible(false, 100);
    double at = m.Sample(150); m.SetVisible(true, 150); Require(m.Sample(150) == at);
    Require(m.Sample(300) == 1 && m.VisibleRequested && m.IsComplete);
});
Check("repeated target does not restart the animation", () => {
    var m = new EdgeMotion(); m.SetVisible(true, 0); m.SetVisible(true, 100);
    Require(m.Sample(140) == 1 && m.IsComplete);
});
Check("reduced motion and lock hide settle immediately", () => {
    var m = new EdgeMotion(); m.SetVisible(true, 0); m.Sample(30);
    m.SetVisible(true, 30, animate: false); Require(m.Progress == 1 && m.IsComplete);
    m.SetVisible(false, 31, animate: false); Require(m.Progress == 0 && m.IsComplete);
    Require(m.Sample(200) == 0);
});
Check("rapid direction changes remain bounded and reach final target", () => {
    var m = new EdgeMotion();
    for (int t = 0; t < 100; ++t) {
        m.SetVisible(t % 2 == 0, t); double v = m.Sample(t); Require(v >= 0 && v <= 1);
    }
    m.SetVisible(true, 100); Require(m.Sample(240) == 1 && m.IsComplete);
});
Check("restore shortcut persists default and preserves other settings", () => {
    string dir=Path.Combine(Path.GetTempPath(),"jotbloom-shortcut-"+Guid.NewGuid());
    try {
        var file=new SettingsFile(Path.Combine(dir,"settings.json"));
        var old=new ProductSettings{Shortcut=new(0x4B,3,"Ctrl+Alt+K"),ShowTrayIcon=false,DefaultPage="prompts"};file.Save(old);
        Hotkey? registered=null;
        ShortcutSettings.Apply(old,Hotkey.Default,key=>{registered=key;return true;},file.Save);
        var saved=file.Load();Require(registered==Hotkey.Default&&saved.Shortcut==Hotkey.Default&&!saved.ShowTrayIcon&&saved.DefaultPage=="prompts");
        ShortcutSettings.Apply(saved,Hotkey.Default,_=>true,file.Save);Require(file.Load().Shortcut==Hotkey.Default);
    } finally {if(Directory.Exists(dir))Directory.Delete(dir,true);}
});
Check("restore shortcut conflict leaves custom shortcut and settings intact", () => {
    var old=new ProductSettings{Shortcut=new(0x4B,3,"Ctrl+Alt+K")};bool saved=false,failed=false;
    try {ShortcutSettings.Apply(old,Hotkey.Default,_=>false,_=>saved=true);}catch(InvalidOperationException){failed=true;}
    Require(failed&&!saved&&old.Shortcut.Key==0x4B);
});
Check("restore shortcut save failure re-registers original combination", () => {
    var old=new ProductSettings{Shortcut=new(0x4B,3,"Ctrl+Alt+K")};var registrations=new List<Hotkey>();bool failed=false;
    try {ShortcutSettings.Apply(old,Hotkey.Default,key=>{registrations.Add(key);return true;},_=>throw new IOException("fixture"));}catch(IOException){failed=true;}
    Require(failed&&registrations.SequenceEqual(new[]{Hotkey.Default,old.Shortcut}));
});
passed+=await AiContracts.Run();
Console.WriteLine($"Passed {passed} contract checks; Windows UI not exercised.");
