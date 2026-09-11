using System.Globalization;
using System.Text;
using System.Text.Json;

namespace JotBloom.Windows.Core;

public sealed record ModelConfiguration(string BaseUrl = "", string Model = "");
public sealed record Hotkey(uint Key = 0x20, uint Modifiers = 3, string Label = "Ctrl+Alt+Space")
{
    public static Hotkey Default { get; } = new();
    public bool IsValid => Key is >= 0x20 and <= 0xFE && (Modifiers & ~7u) == 0 && (Modifiers & 3) != 0 &&
        Key is not (0x5B or 0x5C or 0x5D or 0x7B) && !(Modifiers == 2 && new uint[] { 0x41,0x43,0x56,0x58,0x5A,0x46,0x51,0x57,0x31,0x32,0x33,0x34,0x35,0x36 }.Contains(Key));
}
public static class ShortcutSettings
{
    public static void Apply(ProductSettings settings, Hotkey shortcut, Func<Hotkey, bool> register, Action<ProductSettings> save)
    {
        if (!shortcut.IsValid) throw new InvalidOperationException("请使用 Ctrl 或 Alt 加一个普通键。");
        if (!register(shortcut)) throw new InvalidOperationException("这组快捷键被系统或其他应用占用，请换一组。原快捷键仍有效。");
        try { save(settings with { Shortcut = shortcut }); }
        catch { register(settings.Shortcut); throw; }
    }
}
public sealed record ProductSettings
{
    public int Version { get; init; } = 1;
    public bool Monitoring { get; init; } = true;
    public int MaximumCount { get; init; } = 200;
    public int MaximumDays { get; init; }
    public long MaximumBytes { get; init; } = 2_000_000_000;
    public bool ReduceMotion { get; init; }
    public bool ShowTrayIcon { get; init; } = true;
    public bool StartWithWindows { get; init; }
    public bool OnboardingSeen { get; init; }
    public Hotkey Shortcut { get; init; } = Hotkey.Default;
    public string DefaultPage { get; init; } = "input";
    public string[] TabOrder { get; init; } = ["input", "clipboard", "prompts", "inspirations", "chat", "search"];
    public ModelConfiguration Main { get; init; } = new();
    public ModelConfiguration Auxiliary { get; init; } = new();
    public bool AuxiliaryUsesMain { get; init; } = true;
    public bool InspirationAI { get; init; }
    public string SystemPrompt { get; init; } = AiPrompts.Chat;
    public string[] ExcludedApplications { get; init; } = [];
    public (ModelConfiguration Configuration, string KeySlot) Resolve(bool auxiliary)
    {
        if (!auxiliary || string.IsNullOrWhiteSpace(Auxiliary.Model)) return (Main, "main");
        return (AuxiliaryUsesMain ? new(Main.BaseUrl, Auxiliary.Model) : Auxiliary, AuxiliaryUsesMain ? "main" : "auxiliary");
    }
    public void Validate()
    {
        if (Version != 1 || Shortcut is null || !Shortcut.IsValid || Main is null || Auxiliary is null ||
            TabOrder is null || TabOrder.Length != 6 || !TabOrder.Order().SequenceEqual(new[] { "input", "clipboard", "prompts", "inspirations", "chat", "search" }.Order()) ||
            !TabOrder.Contains(DefaultPage) || string.IsNullOrWhiteSpace(SystemPrompt) || TextRules.Count(SystemPrompt) > 2000 ||
            !new[] { 0, 100, 200, 500, 1000, 5000 }.Contains(MaximumCount) || !new[] { 0,7,30,90,365 }.Contains(MaximumDays) ||
            !new long[] { 0,500_000_000,1_000_000_000,2_000_000_000,5_000_000_000,10_000_000_000 }.Contains(MaximumBytes) || ExcludedApplications is null)
            throw new InvalidDataException("设置文件无效，请恢复备份；原文件已保留。");
    }
}
public sealed class SettingsFile(string file)
{
    public ProductSettings Load()
    {
        if (!File.Exists(file)) return new();
        var value = JsonSerializer.Deserialize<ProductSettings>(File.ReadAllText(file)) ?? throw new InvalidDataException("设置无法读取。");
        value.Validate(); return value;
    }
    public void Save(ProductSettings value)
    {
        value.Validate(); AtomicFile.Write(file, JsonSerializer.SerializeToUtf8Bytes(value));
    }
}
public static class AtomicFile
{
    public static void Write(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        string temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try {
            using (var file = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { file.Write(bytes); file.Flush(true); }
            File.Move(temp, path, true);
        } finally { if (File.Exists(temp)) File.Delete(temp); }
    }
}
public static class TextRules
{
    public static int Count(string text) => new StringInfo(text).LengthInTextElements;
    public static string Prefix(string text, int count)
    {
        var indices = StringInfo.ParseCombiningCharacters(text); return indices.Length > count ? text[..indices[count]] : text;
    }
    public static bool Same(string a, string b) => a.Normalize(NormalizationForm.FormC) == b.Normalize(NormalizationForm.FormC);
    public static bool Matches(string content, string query) => CultureInfo.InvariantCulture.CompareInfo.IndexOf(content, query.Trim(), CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace) >= 0;
}
