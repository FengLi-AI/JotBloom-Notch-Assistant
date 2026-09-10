namespace JotBloom.Windows.Storage;

public sealed partial class BloomStore
{
    private sealed record UndoRecord(string Token,DateTimeOffset Expires,LibraryKind Kind,Dictionary<string,object?> Row,List<(LibraryKind Kind,long Id,string Life)> References);
    private UndoRecord? undo;
    public Task<Deletion> DeleteAsync(LibraryKind kind,long id)=>Enqueue(()=> {
        using var tx=connection.BeginTransaction();var values=new Dictionary<string,object?>();
        using(var cmd=Command($"SELECT * FROM {Table(kind)} WHERE id=$id",tx,("$id",id)))using(var rows=cmd.ExecuteReader()){
            if(!rows.Read())throw new InvalidOperationException("记录已删除。");for(int i=0;i<rows.FieldCount;i++)values[rows.GetName(i)]=rows.IsDBNull(i)?null:rows.GetValue(i);}
        var references=new List<(LibraryKind,long,string)>();
        if(kind==LibraryKind.Clipboard)foreach(var target in new[]{LibraryKind.Prompts,LibraryKind.Inspirations}){using var cmd=Command($"SELECT id,lifecycle_token FROM {Table(target)} WHERE source_clipboard_id=$id",tx,("$id",id));using var rows=cmd.ExecuteReader();while(rows.Read())references.Add((target,rows.GetInt64(0),rows.GetString(1)));}
        using(var cmd=Command($"DELETE FROM {Table(kind)} WHERE id=$id",tx,("$id",id)))cmd.ExecuteNonQuery();tx.Commit();
        var result=new Deletion(Guid.NewGuid().ToString("N"),DateTimeOffset.UtcNow.AddSeconds(3));undo=new(result.Token,result.Expires,kind,values,references);return result;
    });
    public Task<bool> UndoAsync(string token)=>Enqueue(()=> {
        var pending=undo;if(pending is null||pending.Token!=token||pending.Expires<DateTimeOffset.UtcNow)return false;
        using var tx=connection.BeginTransaction();
        if(pending.Kind!=LibraryKind.Clipboard){string text=(string)pending.Row[pending.Kind==LibraryKind.Prompts?"content":"body"]!;CheckDuplicate(pending.Kind,text,tx:tx);}
        var row=new Dictionary<string,object?>(pending.Row);
        if(row.ContainsKey("lifecycle_token"))row["lifecycle_token"]=Guid.NewGuid().ToString("N");
        if(row.TryGetValue("source_clipboard_id",out var source)&&source is not null){using var check=Command("SELECT id FROM clipboard_items WHERE id=$id",tx,("$id",source));if(check.ExecuteScalar() is null)row["source_clipboard_id"]=null;}
        string[] keys=row.Keys.ToArray();using(var cmd=Command($"INSERT INTO {Table(pending.Kind)} ({string.Join(',',keys)}) VALUES ({string.Join(',',keys.Select((_,i)=>"$v"+i))})",tx,keys.Select((k,i)=>("$v"+i,row[k])).ToArray()))cmd.ExecuteNonQuery();
        if(pending.Kind==LibraryKind.Clipboard){foreach(var reference in pending.References){using var cmd=Command($"UPDATE {Table(reference.Kind)} SET source_clipboard_id=$clip WHERE id=$id AND lifecycle_token=$life AND source_clipboard_id IS NULL",tx,("$clip",row["id"]),("$id",reference.Id),("$life",reference.Life));cmd.ExecuteNonQuery();}
            using var flag=Command("UPDATE clipboard_items SET is_favorited_to_prompt=EXISTS(SELECT 1 FROM prompts WHERE source_clipboard_id=$id) WHERE id=$id",tx,("$id",row["id"]));flag.ExecuteNonQuery();}
        tx.Commit();undo=null;return true;
    });
}
