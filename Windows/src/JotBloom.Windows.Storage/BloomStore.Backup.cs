namespace JotBloom.Windows.Storage;

public sealed partial class BloomStore
{
    public Task<string> CopyDirectoryAsync(string parent,bool backup)=>Enqueue(()=> {
        parent=Path.GetFullPath(parent);DataLocation.RequireDirectory(parent);
        string source=Path.GetFullPath(DirectoryPath).TrimEnd(Path.DirectorySeparatorChar);
        if(parent.Equals(source,StringComparison.OrdinalIgnoreCase)||parent.StartsWith(source+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase))throw new IOException("请选择原数据目录之外的位置。");
        string name=backup?"JotBloom-备份-"+DateTime.Now.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N")[..6]:"JotBloom";
        string target=Path.Combine(parent,name);if(Path.Exists(target))throw new IOException("目标已存在，不会覆盖已有文件。");
        string staging=Path.Combine(parent,".jotbloom-copy-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(staging);
        try {
            using(var destination=Connect(Path.Combine(staging,DatabaseName),Microsoft.Data.Sqlite.SqliteOpenMode.ReadWriteCreate))connection.BackupDatabase(destination);
            string assets=Path.Combine(staging,"Clipboard");Directory.CreateDirectory(assets);
            var names=new HashSet<string>();using(var cmd=Command("SELECT image_file_name,thumbnail_file_name FROM clipboard_items WHERE content_type='image'"))using(var rows=cmd.ExecuteReader()){while(rows.Read()){names.Add(rows.GetString(0));names.Add(rows.GetString(1));}}
            foreach(string asset in names)File.Copy(AssetPath(asset),Path.Combine(assets,asset));
            DataLocation.RequireRegularFile(Path.Combine(source,"data-identity"));File.Copy(Path.Combine(source,"data-identity"),Path.Combine(staging,"data-identity"));
            Validate(staging);Directory.Move(staging,target);return target;
        } catch {if(Directory.Exists(staging))Directory.Delete(staging,true);throw;}
    });
}
