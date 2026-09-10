using Microsoft.Data.Sqlite;

namespace JotBloom.Windows.Storage;

public sealed partial class BloomStore
{
    private static string MigrationResource(string name)
    {
        using var reader=new StreamReader(typeof(BloomStore).Assembly.GetManifestResourceStream("JotBloom.Windows.Storage.Migrations."+name)??throw new IOException("迁移资源不完整。"));return reader.ReadToEnd();
    }
    internal static void EnsureCurrent(string directory)
    {
        string path=Path.Combine(directory,DatabaseName);DataLocation.RequireRegularFile(path);
        int version;
        using(var original=Connect(path,SqliteOpenMode.ReadOnly)){
            version=Convert.ToInt32(Scalar(original,"PRAGMA user_version"));if(version==7)return;
            if(version<1||version>7)throw new IOException("数据版本不受支持，原文件已保留。");
            ValidateVersion(original,version);
            string backup=path+".bak-v"+version;
            // Exclusive reservation: an existing backup is never overwritten.
            using(new FileStream(backup,FileMode.CreateNew,FileAccess.Write,FileShare.None)){ }
            try{using var copy=Connect(backup,SqliteOpenMode.ReadWrite);original.BackupDatabase(copy);ValidateVersion(copy,version);}
            catch{File.Delete(backup);throw;}
        }
        using var db=Connect(path,SqliteOpenMode.ReadWrite);using var tx=db.BeginTransaction();ValidateVersion(db,version,tx);
        for(int next=version+1;next<=7;next++)Execute(db,MigrationResource("V"+next+".sql"),tx);
        using(var command=db.CreateCommand()){
            command.Transaction=tx;command.CommandText="UPDATE chat_sessions SET system_prompt=$prompt WHERE EXISTS(SELECT 1 FROM chat_messages WHERE session_id=chat_sessions.id) OR length(draft)>0 OR (slot=1 AND EXISTS(SELECT 1 FROM drafts WHERE kind='ai_chat' AND length(content)>0))";
            command.Parameters.AddWithValue("$prompt",MigrationResource("LegacySystem.txt"));command.ExecuteNonQuery();
        }
        ValidateVersion(db,7,tx);tx.Commit();
    }
    private static void ValidateVersion(SqliteConnection db,int version,SqliteTransaction? tx=null)
    {
        using var expected=Connect(":memory:",SqliteOpenMode.Memory);Execute(expected,MigrationResource("SchemaV"+version+".sql"));
        if(!Objects(db,tx).SequenceEqual(Objects(expected)))throw new IOException("数据结构不匹配，迁移未执行；原数据已保留。");
        using var check=db.CreateCommand();check.Transaction=tx;check.CommandText="PRAGMA quick_check";if(!Equals(check.ExecuteScalar(),"ok"))throw new IOException("数据完整性检查未通过。");
        check.CommandText="PRAGMA foreign_key_check";if(check.ExecuteScalar() is not null)throw new IOException("数据关联检查未通过。");
        check.CommandText="PRAGMA user_version";if(Convert.ToInt32(check.ExecuteScalar())!=version)throw new IOException("数据版本已改变，请重新打开。");
    }
}
