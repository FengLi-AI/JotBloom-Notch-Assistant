using System.Text;
using System.Text.Json;

namespace JotBloom.Windows.Storage;

/// <summary>Small local locator only; user content lives in the selected directory.</summary>
public sealed class DataLocation(string controlDirectory)
{
    private sealed record Location(int Version, string ActivePath, string Identity, string? StagingPath = null);
    private readonly string control = Path.GetFullPath(controlDirectory);
    private string Locator => Path.Combine(control, "data-location.json");
    private string Pending => Path.Combine(control, "initial-setup.json");

    public string? Resolve()
    {
        if (Directory.Exists(control)) RequireDirectory(control);
        else if (Path.Exists(control)) throw new IOException("配置位置不可访问，请先恢复该位置。");
        if (Path.Exists(Locator)) {
            var record = Read(Locator); ValidateLocation(record);
            // Locator wins after an interrupted final cleanup, but only for the same identity.
            if (Path.Exists(Pending)) {
                var pending = Read(Pending);
                if (pending.Identity != record.Identity || pending.ActivePath != record.ActivePath)
                    throw new IOException("检测到未完成的数据目录操作，请保留配置与数据目录。");
                File.Delete(Pending);
            }
            return record.ActivePath;
        }
        if (Path.Exists(Pending)) {
            var pending = Read(Pending);
            if (!Directory.Exists(pending.ActivePath)) {
                if (pending.StagingPath is null) throw new IOException("首次设置记录不完整，请恢复原目录。");
                ValidateLocation(pending with { ActivePath = pending.StagingPath });
                Directory.Move(pending.StagingPath, pending.ActivePath);
            }
            ValidateLocation(pending);
            WriteAtomic(Locator, pending with { StagingPath = null });
            File.Delete(Pending); return pending.ActivePath;
        }
        // Unknown control artifacts may represent a interrupted/older setup. Fail closed.
        if (Directory.Exists(control) && Directory.EnumerateFileSystemEntries(control).Any())
            throw new IOException("发现已有配置但无法确认数据位置，请保留该目录并恢复定位记录。");
        return null;
    }

    public string Create(string parent)
    {
        if (Resolve() is not null) throw new IOException("已经选择过存储位置，不能重新初始化。");
        parent = Path.GetFullPath(parent); RequireDirectory(parent);
        if (OperatingSystem.IsWindows()) {
            var drive = new DriveInfo(Path.GetPathRoot(parent)!);
            if (drive.DriveType is not (DriveType.Fixed or DriveType.Removable))
                throw new IOException("请选择本地磁盘中的文件夹。");
        }
        string target = Path.Combine(parent, "JotBloom");
        if (Path.Exists(target) || Directory.EnumerateFileSystemEntries(parent).Any(p =>
                string.Equals(Path.GetFileName(p), "JotBloom", StringComparison.OrdinalIgnoreCase)))
            throw new IOException("这里已经有 JotBloom 文件或文件夹，请选择其他位置。原内容不会被覆盖。");
        if (control.Equals(target, StringComparison.OrdinalIgnoreCase) || control.StartsWith(target + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException("请选择配置目录之外的数据位置。");
        string id = Guid.NewGuid().ToString("D");
        string staging = Path.Combine(parent, ".jotbloom-setup-" + id);
        var pending = new Location(1, target, id, staging);
        Directory.CreateDirectory(control); RequireDirectory(control);
        WriteAtomic(Pending, pending);
        bool moved = false;
        try {
            Directory.CreateDirectory(staging);
            BloomStore.Initialize(staging);
            WriteNew(Path.Combine(staging, "data-identity"), id);
            ValidateLocation(pending with { ActivePath = staging });
            Directory.Move(staging, target); moved = true;
            WriteAtomic(Locator, pending with { StagingPath = null });
            File.Delete(Pending); return target;
        } catch {
            // Once moved, keep the journal and complete on next Resolve. No user data deletion.
            if (!moved) {
                if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
                File.Delete(Pending);
            }
            throw;
        }
    }

    private static Location Read(string path)
    {
        RequireRegularFile(path);
        var value = JsonSerializer.Deserialize<Location>(File.ReadAllText(path)) ?? throw new IOException("无法读取数据位置记录。");
        if (value.Version != 1 || !Guid.TryParseExact(value.Identity, "D", out _) || !Path.IsPathFullyQualified(value.ActivePath))
            throw new IOException("数据位置记录无效，请保留原文件并恢复备份。");
        if (value.StagingPath is not null && value.StagingPath != Path.Combine(Path.GetDirectoryName(value.ActivePath)!, ".jotbloom-setup-" + value.Identity))
            throw new IOException("首次设置记录不匹配。");
        return value;
    }
    private static void ValidateLocation(Location location)
    {
        RequireDirectory(location.ActivePath);
        string identity = Path.Combine(location.ActivePath, "data-identity");
        RequireRegularFile(identity);
        if (File.ReadAllText(identity) != location.Identity) throw new IOException("原数据目录无法确认，请恢复原位置。");
        BloomStore.EnsureCurrent(location.ActivePath);BloomStore.Validate(location.ActivePath);
    }
    internal static void RequireRegularFile(string path)
    {
        if (!File.Exists(path) || (File.GetAttributes(path) & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new IOException("所需的数据文件无法读取，请恢复原位置。");
    }
    internal static void RequireDirectory(string path)
    {
        if (!Directory.Exists(path)) throw new IOException("原数据目录暂时不可访问，请连接对应磁盘后重试。");
        for (var directory = new DirectoryInfo(path); directory is not null; directory = directory.Parent)
            if ((directory.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new IOException("请选择不经过链接或目录联接的本地位置。");
    }
    private static void WriteNew(string path, string content)
    {
        using var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        stream.Write(Encoding.UTF8.GetBytes(content)); stream.Flush(flushToDisk: true);
    }
    public string Relocate(string directory)
    {
        var record=Read(Locator);directory=Path.GetFullPath(directory);
        var next=record with{ActivePath=directory,StagingPath=null};ValidateLocation(next);WriteAtomic(Locator,next);return directory;
    }
    public string Reconnect(string directory)
    {
        try{_ = Read(Locator);return Relocate(directory);}
        catch(System.Text.Json.JsonException){return Repair();}
        catch(IOException){if(File.Exists(Locator)){try{_ = Read(Locator);}catch{return Repair();}}throw;}
        string Repair(){directory=Path.GetFullPath(directory);RequireDirectory(directory);string identity=Path.Combine(directory,"data-identity");RequireRegularFile(identity);string id=File.ReadAllText(identity);if(!Guid.TryParseExact(id,"D",out _))throw new IOException("所选数据身份无效。");var next=new Location(1,directory,id);ValidateLocation(next);if(File.Exists(Locator))File.Copy(Locator,Locator+".recovery-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(control);WriteAtomic(Locator,next);return directory;}
    }
    private static void WriteAtomic(string path, Location record)
    {
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { WriteNew(temporary, JsonSerializer.Serialize(record)); File.Move(temporary, path, overwrite: true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
