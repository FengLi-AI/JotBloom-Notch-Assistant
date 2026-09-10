using JotBloom.Windows.Core;
using Microsoft.Data.Sqlite;

namespace JotBloom.Windows.Storage;

public sealed partial class BloomStore
{
    public static readonly string[] Categories = ["文章类", "作品类", "产品类", "idea"];
    private static string Table(LibraryKind kind) => kind switch {
        LibraryKind.Inspirations => "inspirations", LibraryKind.Prompts => "prompts", LibraryKind.Clipboard => "clipboard_items", _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };
    private SqliteCommand Command(string sql, SqliteTransaction? tx = null, params (string, object?)[] args)
    {
        var cmd = connection.CreateCommand(); cmd.CommandText = sql; cmd.Transaction = tx;
        foreach (var (key, value) in args) cmd.Parameters.AddWithValue(key, value ?? DBNull.Value);
        return cmd;
    }
    private static string Select(LibraryKind kind) => kind switch {
        LibraryKind.Inspirations => "SELECT id,title,body,category,created_at_utc_ms,sort_order,0,'text',NULL,NULL,COALESCE(source_application_name,''),0,lifecycle_token,content_revision,title_revision,category_revision FROM inspirations",
        LibraryKind.Prompts => "SELECT id,title,content,'',created_at_utc_ms,sort_order,is_favorite,'text',NULL,NULL,COALESCE(source_application_name,''),0,lifecycle_token,0,title_revision,0 FROM prompts",
        LibraryKind.Clipboard => "SELECT id,'',COALESCE(text_content,''),'',copied_at_utc_ms,copied_at_utc_ms,is_favorited_to_prompt,content_type,image_file_name,thumbnail_file_name,COALESCE(source_application_name,''),content_byte_count,'',0,0,0 FROM clipboard_items",
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };
    private static LibraryItem ReadItem(SqliteDataReader r, LibraryKind kind) => new(kind,r.GetInt64(0),r.GetString(1),r.GetString(2),r.GetString(3),r.GetInt64(4),r.GetInt64(5),r.GetInt64(6)!=0,r.GetString(7),r.IsDBNull(8)?null:r.GetString(8),r.IsDBNull(9)?null:r.GetString(9),r.GetString(10),r.GetInt64(11),r.GetString(12),r.GetInt64(13),r.GetInt64(14),r.GetInt64(15));
    private LibraryItem? Item(LibraryKind kind, long id, SqliteTransaction? tx = null)
    {
        using var cmd = Command(Select(kind)+" WHERE id=$id", tx, ("$id",id)); using var r=cmd.ExecuteReader(); return r.Read()?ReadItem(r,kind):null;
    }
    public Task<LibraryItem?> GetAsync(LibraryKind kind, long id) => Enqueue(()=>Item(kind,id));
    public Task<LibraryPage> ListAsync(LibraryKind kind, PageCursor? after = null, string? category = null, bool favorites = false, int limit = 50) => Enqueue(()=> {
        limit=Math.Clamp(limit,1,100); string sort=kind==LibraryKind.Clipboard?"copied_at_utc_ms":"sort_order";
        string where=" WHERE 1=1";
        if (category is not null && kind==LibraryKind.Inspirations) where+=" AND category=$category";
        if (favorites && kind==LibraryKind.Prompts) where+=" AND is_favorite=1";
        if(after is not null) where+=$" AND ({sort}<$sort OR ({sort}=$sort AND id<$id))";
        using var cmd=Command(Select(kind)+where+$" ORDER BY {sort} DESC,id DESC LIMIT $limit",null,("$category",category),("$sort",after?.Sort),("$id",after?.Id),("$limit",limit+1));
        using var r=cmd.ExecuteReader();var rows=new List<LibraryItem>();while(r.Read())rows.Add(ReadItem(r,kind));
        bool more=rows.Count>limit;if(more)rows.RemoveAt(limit);
        return new LibraryPage(rows,more?new(rows[^1].Sort,rows[^1].Id):null);
    });
    private void CheckDuplicate(LibraryKind kind,string text,long exclude=-1,SqliteTransaction? tx=null)
    {
        string column=kind==LibraryKind.Inspirations?"body":"content";
        using var cmd=Command($"SELECT {column} FROM {Table(kind)} WHERE id!=$id",tx,("$id",exclude));using var r=cmd.ExecuteReader();
        while(r.Read()) if(TextRules.Same(r.GetString(0),text)) throw new InvalidOperationException(kind==LibraryKind.Inspirations?"这条灵感已经保存过了。":"这条提示词已经存在。");
    }
    public Task<LibraryItem> CreatePromptAsync(string content,string? title=null,long? clipboardId=null,bool consumeDraft=false) => Enqueue(()=> {
        if(string.IsNullOrWhiteSpace(content))throw new ArgumentException("请输入提示词内容。");
        using var tx=connection.BeginTransaction();CheckDuplicate(LibraryKind.Prompts,content,tx:tx);
        string token=Guid.NewGuid().ToString("N");long time=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        using var cmd=Command("""
            INSERT INTO prompts(title,content,title_source,created_at_utc_ms,origin_kind,source_clipboard_id,source_application_name,source_bundle_identifier,submission_token,lifecycle_token,sort_order)
            VALUES($title,$text,$source,$time,$origin,$clip,(SELECT source_application_name FROM clipboard_items WHERE id=$clip),(SELECT source_bundle_identifier FROM clipboard_items WHERE id=$clip),$token,$token,(SELECT COALESCE(MAX(sort_order),0)+1 FROM prompts));SELECT last_insert_rowid();
            """,tx,("$title",title??TextRules.Prefix(content.Split('\n')[0],10)),("$text",content),("$source",title is null?"fallback":"user"),("$time",time),("$origin",clipboardId is null?"input":"clipboard"),("$clip",clipboardId),("$token",token));
        long id=Convert.ToInt64(cmd.ExecuteScalar());if(consumeDraft)Execute(connection,"DELETE FROM drafts WHERE kind='inspiration'",tx);tx.Commit();return Item(LibraryKind.Prompts,id)!;
    });
    public Task<LibraryItem> UpdateAsync(LibraryItem expected,string title,string content,string category) => Enqueue(()=> {
        if(expected.Kind==LibraryKind.Clipboard)throw new InvalidOperationException();
        if(string.IsNullOrWhiteSpace(content))throw new ArgumentException("内容不能为空，当前输入已保留。");
        if(TextRules.Count(title)>200)throw new ArgumentException("标题请控制在 200 字以内。");
        if(expected.Kind==LibraryKind.Inspirations&&!Categories.Contains(category))throw new ArgumentException("请选择有效分类。");
        using var tx=connection.BeginTransaction();var current=Item(expected.Kind,expected.Id,tx)??throw new InvalidOperationException("这条记录已删除。");
        bool titleEdited=title!=expected.Title,bodyEdited=content!=expected.Content,categoryEdited=category!=expected.Category;
        if(current.Lifecycle!=expected.Lifecycle||bodyEdited&&current.Content!=expected.Content||titleEdited&&current.TitleRevision!=expected.TitleRevision||categoryEdited&&current.CategoryRevision!=expected.CategoryRevision)throw new InvalidOperationException("记录已被更新，当前输入仍保留；请复制需要保留的修改后重新打开。");
        if(!titleEdited)title=current.Title;if(!bodyEdited)content=current.Content;if(!categoryEdited)category=current.Category;
        CheckDuplicate(expected.Kind,content,expected.Id,tx);
        using var cmd=expected.Kind==LibraryKind.Inspirations
            ?Command("UPDATE inspirations SET title=$title,body=$body,category=$category,title_source=CASE WHEN title!=$title THEN 'user' ELSE title_source END,category_source=CASE WHEN category!=$category THEN 'user' ELSE category_source END,content_revision=content_revision+CASE WHEN body!=$body THEN 1 ELSE 0 END,title_revision=title_revision+CASE WHEN title!=$title THEN 1 ELSE 0 END,category_revision=category_revision+CASE WHEN category!=$category THEN 1 ELSE 0 END,updated_at_utc_ms=$time WHERE id=$id",tx,("$title",title),("$body",content),("$category",category),("$time",DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()),("$id",expected.Id))
            :Command("UPDATE prompts SET title=$title,content=$body,title_source=CASE WHEN title!=$title THEN 'user' ELSE title_source END,title_revision=title_revision+1,lifecycle_token=$token WHERE id=$id",tx,("$title",title),("$body",content),("$token",Guid.NewGuid().ToString("N")),("$id",expected.Id));
        cmd.ExecuteNonQuery();tx.Commit();return Item(expected.Kind,expected.Id)!;
    });
    public Task SetFavoriteAsync(long id,bool favorite)=>Enqueue(()=>{using var cmd=Command("UPDATE prompts SET is_favorite=$favorite WHERE id=$id",null,("$favorite",favorite?1:0),("$id",id));return cmd.ExecuteNonQuery();});
    public Task MoveBeforeAsync(LibraryKind kind,long source,long target)=>Enqueue(()=> {
        if(kind==LibraryKind.Clipboard||source==target)return 0;
        using var tx=connection.BeginTransaction();using var read=Command($"SELECT id FROM {Table(kind)} ORDER BY sort_order DESC,id DESC",tx);var ids=new List<long>();using(var rows=read.ExecuteReader()){while(rows.Read())ids.Add(rows.GetInt64(0));}
        if(!ids.Remove(source)||!ids.Contains(target))return 0;ids.Insert(ids.IndexOf(target),source);
        for(int i=0;i<ids.Count;i++){using var cmd=Command($"UPDATE {Table(kind)} SET sort_order=$sort WHERE id=$id",tx,("$sort",ids.Count-i),("$id",ids[i]));cmd.ExecuteNonQuery();}tx.Commit();return 1;
    });
    public Task<SearchResults> SearchAsync(string query,LibraryKind? only=null,int offset=0,int limit=50)=>Enqueue(()=> {
        var counts=new Dictionary<LibraryKind,int>();var result=new List<LibraryItem>();
        if(string.IsNullOrWhiteSpace(query))return new SearchResults(counts,result);
        foreach(var kind in Enum.GetValues<LibraryKind>()) {
            using var cmd=Command(Select(kind)+" ORDER BY 6 DESC,1 DESC");using var rows=cmd.ExecuteReader();int count=0;
            while(rows.Read()) {var item=ReadItem(rows,kind);if(!TextRules.Matches(item.Title+"\n"+item.Content,query))continue;
                if(only is null?count<2:only==kind&&count>=offset&&count<offset+Math.Clamp(limit,1,100))result.Add(item);count++;}
            counts[kind]=count;
        }
        return new SearchResults(counts,result);
    });
    public Task<bool> ApplyAIAsync(LibraryItem snapshot,string? title,string? category)=>Enqueue(()=> {
        if(title is not null&&(string.IsNullOrWhiteSpace(title)||TextRules.Count(title)>20||title.Contains('\n')||title.Contains('\r')))throw new ArgumentException("标题格式无效。");
        if(category is not null&&!Categories.Contains(category))throw new ArgumentException("分类无效。");
        using var cmd=snapshot.Kind==LibraryKind.Inspirations
            ?Command("""
                UPDATE inspirations SET title=CASE WHEN $title IS NOT NULL AND title_source!='user' AND title_revision=$tr THEN $title ELSE title END,
                title_source=CASE WHEN $title IS NOT NULL AND title_source!='user' AND title_revision=$tr THEN 'ai' ELSE title_source END,
                category=CASE WHEN $category IS NOT NULL AND category_source!='user' AND category_revision=$cr THEN $category ELSE category END,
                category_source=CASE WHEN $category IS NOT NULL AND category_source!='user' AND category_revision=$cr THEN 'ai' ELSE category_source END
                WHERE id=$id AND lifecycle_token=$life AND content_revision=$revision
                """,null,("$title",title),("$category",category),("$tr",snapshot.TitleRevision),("$cr",snapshot.CategoryRevision),("$id",snapshot.Id),("$life",snapshot.Lifecycle),("$revision",snapshot.Revision))
            :Command("UPDATE prompts SET title=$title,title_source='ai' WHERE id=$id AND lifecycle_token=$life AND title_revision=$tr AND title_source!='user'",null,("$title",title??snapshot.Title),("$id",snapshot.Id),("$life",snapshot.Lifecycle),("$tr",snapshot.TitleRevision));
        return cmd.ExecuteNonQuery()==1;
    });
}
