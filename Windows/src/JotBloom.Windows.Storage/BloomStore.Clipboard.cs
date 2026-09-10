using System.Security.Cryptography;
using System.Text;
using JotBloom.Windows.Core;

namespace JotBloom.Windows.Storage;

public sealed partial class BloomStore
{
    public string AssetPath(string name)
    {
        if(string.IsNullOrEmpty(name)||Path.GetFileName(name)!=name||name.Contains('/')||name.Contains('\\')||name is "." or "..")throw new IOException("图片路径无效。");
        string directory=Path.Combine(DirectoryPath,"Clipboard");
        if(!Directory.Exists(directory)||(File.GetAttributes(directory)&FileAttributes.ReparsePoint)!=0)throw new IOException("图片目录不可用。");
        string path=Path.Combine(directory,name);if(Path.Exists(path))DataLocation.RequireRegularFile(path);return path;
    }
    public Task<LibraryItem?> CaptureAsync(ClipboardInput input)=>Enqueue(()=> {
        bool image=input.Png is not null;
        if(!image&&string.IsNullOrWhiteSpace(input.Text))return null;
        long count=image?input.Png!.LongLength:Encoding.UTF8.GetByteCount(input.Text!);
        if(count>20_000_000||image&&(input.Thumbnail is null||input.Width<=0||input.Height<=0||(long)input.Width*input.Height>40_000_000))return null;
        string type=image?"image":Uri.TryCreate(input.Text,UriKind.Absolute,out var u)&&u.Scheme is "http" or "https"?"link":"text";
        string? hash=image?Convert.ToHexString(SHA256.HashData(input.Png!)).ToLowerInvariant():null;
        long now=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        using var tx=connection.BeginTransaction();
        using var old=Command(image?"SELECT id FROM clipboard_items WHERE content_type='image' AND image_sha256=$hash AND content_byte_count=$bytes":"SELECT id FROM clipboard_items WHERE content_type=$type AND text_content=$text",tx,("$hash",hash),("$bytes",count),("$type",type),("$text",input.Text));
        object? found=old.ExecuteScalar();
        if(found is not null){long id=Convert.ToInt64(found);using var update=Command("UPDATE clipboard_items SET copied_at_utc_ms=$time,source_application_name=$name,source_bundle_identifier=$source WHERE id=$id",tx,("$time",now),("$name",input.SourceName),("$source",input.SourceId),("$id",id));update.ExecuteNonQuery();tx.Commit();return Item(LibraryKind.Clipboard,id);}
        string? filename=image?hash+"-image.png":null,thumbnail=image?hash+"-thumb.png":null;
        if(image){string file=AssetPath(filename!),thumb=AssetPath(thumbnail!);if(!File.Exists(file))AtomicFile.Write(file,input.Png!);if(!File.Exists(thumb))AtomicFile.Write(thumb,input.Thumbnail!);}
        using var insert=Command("""
            INSERT INTO clipboard_items(content_type,text_content,image_file_name,thumbnail_file_name,content_byte_count,image_sha256,image_width_px,image_height_px,copied_at_utc_ms,source_application_name,source_bundle_identifier)
            VALUES($type,$text,$image,$thumb,$bytes,$hash,$width,$height,$time,$name,$source);SELECT last_insert_rowid();
            """,tx,("$type",type),("$text",image?null:input.Text),("$image",filename),("$thumb",thumbnail),("$bytes",count),("$hash",hash),("$width",image?input.Width:null),("$height",image?input.Height:null),("$time",now),("$name",input.SourceName),("$source",input.SourceId));
        long inserted=Convert.ToInt64(insert.ExecuteScalar());tx.Commit();return Item(LibraryKind.Clipboard,inserted);
    });
    public Task<LibraryItem> ImportClipboardInspirationAsync(long id)=>Enqueue(()=> {
        using var tx=connection.BeginTransaction();var item=Item(LibraryKind.Clipboard,id,tx)??throw new IOException("剪贴板记录已不存在。");
        if(item.ContentType=="image")throw new InvalidOperationException("图片不能直接转为文字灵感。");
        CheckDuplicate(LibraryKind.Inspirations,item.Content,tx:tx);
        using var cmd=Command("""
            INSERT INTO inspirations(title,body,category,category_source,created_at_utc_ms,updated_at_utc_ms,source,origin_kind,source_clipboard_id,source_application_name,source_bundle_identifier,sort_order)
            SELECT $title,text_content,'idea','fallback',$time,$time,'manual','clipboard',id,source_application_name,source_bundle_identifier,(SELECT COALESCE(MAX(sort_order),0)+1 FROM inspirations) FROM clipboard_items WHERE id=$id;SELECT last_insert_rowid();
            """,tx,("$title",TextRules.Prefix(item.Content.Split('\n').FirstOrDefault(l=>!string.IsNullOrWhiteSpace(l))??item.Content,30)),("$time",DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()),("$id",id));
        long added=Convert.ToInt64(cmd.ExecuteScalar());tx.Commit();return Item(LibraryKind.Inspirations,added)!;
    });
    public Task<StorageUsage> UsageAsync()=>Enqueue(()=>new StorageUsage(Convert.ToInt64(Scalar(connection,"SELECT COUNT(*) FROM clipboard_items")),Convert.ToInt64(Scalar(connection,"SELECT COALESCE(SUM(content_byte_count),0) FROM clipboard_items")),Convert.ToInt64(Scalar(connection,"SELECT COUNT(*) FROM clipboard_items WHERE content_type='image'"))));
    public Task<int> PruneAsync(ProductSettings settings)=>Enqueue(()=> {
        using var tx=connection.BeginTransaction();var ids=new List<long>();using(var cmd=Command("SELECT id,copied_at_utc_ms,content_byte_count FROM clipboard_items ORDER BY copied_at_utc_ms DESC,id DESC",tx))using(var rows=cmd.ExecuteReader()){
            long bytes=0;int count=0;long threshold=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()-(long)settings.MaximumDays*86_400_000;
            while(rows.Read()){bytes+=rows.GetInt64(2);count++;if(settings.MaximumCount>0&&count>settings.MaximumCount||settings.MaximumDays>0&&rows.GetInt64(1)<threshold)ids.Add(rows.GetInt64(0));}
        }
        foreach(long id in ids){using var cmd=Command("DELETE FROM clipboard_items WHERE id=$id",tx,("$id",id));cmd.ExecuteNonQuery();}
        using var sum=Command("SELECT COALESCE(SUM(content_byte_count),0) FROM clipboard_items",tx);long total=Convert.ToInt64(sum.ExecuteScalar());
        if(settings.MaximumBytes>0&&total>settings.MaximumBytes){using var old=Command("SELECT id,content_byte_count FROM clipboard_items ORDER BY copied_at_utc_ms,id",tx);var candidates=new List<(long,long)>();using(var rows=old.ExecuteReader()){while(rows.Read())candidates.Add((rows.GetInt64(0),rows.GetInt64(1)));}
            foreach(var (id,size) in candidates){if(total<=settings.MaximumBytes/2)break;using var cmd=Command("DELETE FROM clipboard_items WHERE id=$id",tx,("$id",id));cmd.ExecuteNonQuery();total-=size;ids.Add(id);}}
        tx.Commit();CleanupAssets();return ids.Count;
    });
    public Task ClearClipboardAsync()=>Enqueue(()=>{Execute(connection,"DELETE FROM clipboard_items");undo=null;CleanupAssets();return 0;});
    private void CleanupAssets()
    {
        var used=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using(var cmd=Command("SELECT image_file_name,thumbnail_file_name FROM clipboard_items WHERE content_type='image'"))using(var rows=cmd.ExecuteReader()){while(rows.Read()){used.Add(rows.GetString(0));used.Add(rows.GetString(1));}}
        if(undo is not null&&undo.Expires>DateTimeOffset.UtcNow&&undo.Kind==LibraryKind.Clipboard){foreach(var key in new[]{"image_file_name","thumbnail_file_name"})if(undo.Row[key] is string name)used.Add(name);}
        foreach(string file in Directory.EnumerateFiles(Path.Combine(DirectoryPath,"Clipboard"))){if(used.Contains(Path.GetFileName(file)))continue;
            if(!System.Text.RegularExpressions.Regex.IsMatch(Path.GetFileName(file),"^[a-f0-9]{64}-(image|thumb)\\.png$"))continue;DataLocation.RequireRegularFile(file);File.Delete(file);}
    }
}
