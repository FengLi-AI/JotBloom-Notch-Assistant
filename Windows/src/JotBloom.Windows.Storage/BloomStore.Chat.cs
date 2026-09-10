using JotBloom.Windows.Core;

namespace JotBloom.Windows.Storage;

public sealed partial class BloomStore
{
    private ChatSession Session(long id)
    {
        using var cmd=Command("SELECT id,token,title,draft,COALESCE(system_prompt,$system),updated_at_utc_ms FROM chat_sessions WHERE id=$id",null,("$system",AiPrompts.Chat),("$id",id));using var r=cmd.ExecuteReader();
        if(!r.Read())throw new InvalidOperationException("对话已不存在。");return new(r.GetInt64(0),r.GetString(1),r.GetString(2),r.GetString(3),r.GetString(4),r.GetInt64(5));
    }
    private ChatSession NewSession(string system)
    {
        using var tx=connection.BeginTransaction();Execute(connection,"UPDATE chat_sessions SET slot=NULL WHERE slot=1",tx);
        using var cmd=Command("INSERT INTO chat_sessions(slot,token,updated_at_utc_ms,system_prompt) VALUES(1,$token,$time,$system);SELECT last_insert_rowid();",tx,("$token",Guid.NewGuid().ToString("N")),("$time",DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()),("$system",system));
        long id=Convert.ToInt64(cmd.ExecuteScalar());tx.Commit();return Session(id);
    }
    public Task<ChatSession> CurrentSessionAsync(string system)=>Enqueue(()=> {object? id=Scalar(connection,"SELECT id FROM chat_sessions WHERE slot=1");return id is null?NewSession(system):Session(Convert.ToInt64(id));});
    public Task<ChatSession> NewSessionAsync(string system)=>Enqueue(()=>NewSession(system));
    public Task<ChatSession> SelectSessionAsync(long id)=>Enqueue(()=> {
        var value=Session(id);using var tx=connection.BeginTransaction();Execute(connection,"UPDATE chat_sessions SET slot=NULL WHERE slot=1",tx);using var cmd=Command("UPDATE chat_sessions SET slot=1 WHERE id=$id",tx,("$id",id));cmd.ExecuteNonQuery();tx.Commit();return value;
    });
    public Task<IReadOnlyList<ChatSession>> SessionsAsync(int offset=0)=>Enqueue<IReadOnlyList<ChatSession>>(()=> {
        using var cmd=Command("SELECT id,token,title,draft,COALESCE(system_prompt,$system),updated_at_utc_ms FROM chat_sessions ORDER BY updated_at_utc_ms DESC,id DESC LIMIT 50 OFFSET $offset",null,("$system",AiPrompts.Chat),("$offset",Math.Max(offset,0)));
        using var r=cmd.ExecuteReader();var list=new List<ChatSession>();while(r.Read())list.Add(new(r.GetInt64(0),r.GetString(1),r.GetString(2),r.GetString(3),r.GetString(4),r.GetInt64(5)));return list;
    });
    public Task DeleteSessionAsync(long id)=>Enqueue(()=> {using var cmd=Command("DELETE FROM chat_sessions WHERE id=$id",null,("$id",id));return cmd.ExecuteNonQuery();});
    public Task PersistChatDraftAsync(long id,string text)=>Enqueue(()=> {using var cmd=Command("UPDATE chat_sessions SET draft=$text WHERE id=$id",null,("$text",text),("$id",id));if(cmd.ExecuteNonQuery()!=1)throw new IOException("对话草稿未能写入。");return 0;});
    public Task<IReadOnlyList<ChatTurn>> TurnsAsync(long session,int limit=200)=>Enqueue<IReadOnlyList<ChatTurn>>(()=> {
        using var cmd=Command("""
            SELECT u.id,u.turn_token,a.attempt_token,u.content,a.content,a.state,a.error_code FROM chat_messages u JOIN chat_messages a ON u.session_id=a.session_id AND u.turn_token=a.turn_token AND a.role='assistant'
            WHERE u.session_id=$session AND u.role='user' ORDER BY u.id DESC LIMIT $limit
            """,null,("$session",session),("$limit",Math.Clamp(limit,1,10000)));using var rows=cmd.ExecuteReader();var result=new List<ChatTurn>();
        while(rows.Read())result.Add(new(rows.GetInt64(0),rows.GetString(1),rows.GetString(2),rows.GetString(3),rows.GetString(4),rows.GetString(5),rows.IsDBNull(6)?null:rows.GetString(6)));result.Reverse();return result;
    });
    public Task<ChatTurn> SubmitAsync(long session,string input,bool fromInput=false)=>Enqueue<ChatTurn>(()=> {
        if(string.IsNullOrWhiteSpace(input))throw new ArgumentException("请输入消息。");
        using var tx=connection.BeginTransaction();using(var check=Command("SELECT COUNT(*) FROM chat_messages WHERE session_id=$id AND state IN ('waiting','streaming')",tx,("$id",session)))if(Convert.ToInt64(check.ExecuteScalar())>0)throw new InvalidOperationException("请先等待回复完成或停止。");
        string turn=Guid.NewGuid().ToString("N"),attempt=Guid.NewGuid().ToString("N");long time=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();long userId=0;
        foreach(string role in new[]{"user","assistant"}){using var cmd=Command("INSERT INTO chat_messages(session_id,role,content,created_at_utc_ms,turn_token,attempt_token,state) VALUES($id,$role,$text,$time,$turn,$attempt,$state);SELECT last_insert_rowid();",tx,("$id",session),("$role",role),("$text",role=="user"?input:""),("$time",time),("$turn",turn),("$attempt",attempt),("$state",role=="user"?"complete":"waiting"));long id=Convert.ToInt64(cmd.ExecuteScalar());if(role=="user")userId=id;}
        using(var cmd=Command("UPDATE chat_sessions SET draft='',title=CASE WHEN title='' THEN $title ELSE title END,updated_at_utc_ms=$time WHERE id=$id",tx,("$title",TextRules.Prefix(input,30)),("$time",time),("$id",session)))cmd.ExecuteNonQuery();
        if(fromInput)Execute(connection,"DELETE FROM drafts WHERE kind='inspiration'",tx);
        tx.Commit();return new(userId,turn,attempt,input,"","waiting",null);
    });
    public Task<ChatTurn> RetryAsync(long session,ChatTurn expected)=>Enqueue(()=> {
        using var tx=connection.BeginTransaction();using var latest=Command("SELECT turn_token FROM chat_messages WHERE session_id=$id AND role='user' ORDER BY id DESC LIMIT 1",tx,("$id",session));
        if(latest.ExecuteScalar() as string!=expected.TurnToken||expected.State is "complete" or "waiting" or "streaming")throw new InvalidOperationException("仅能重试最后一个未完成轮次。");
        string attempt=Guid.NewGuid().ToString("N");using var cmd=Command("UPDATE chat_messages SET attempt_token=$new,content='',state='waiting',error_code=NULL WHERE session_id=$id AND turn_token=$turn AND role='assistant' AND attempt_token=$old AND state NOT IN ('waiting','streaming','complete')",tx,("$new",attempt),("$id",session),("$turn",expected.TurnToken),("$old",expected.Attempt));
        if(cmd.ExecuteNonQuery()!=1)throw new InvalidOperationException("对话状态已改变。");tx.Commit();return expected with{Attempt=attempt,Answer="",State="waiting",Error=null};
    });
    public Task UpdateTurnAsync(long session,ChatTurn turn)=>Enqueue(()=> {
        if(!new[]{"streaming","complete","stopped","failed","interrupted","length"}.Contains(turn.State))throw new ArgumentException("状态无效。");
        using var cmd=Command("UPDATE chat_messages SET content=$text,state=$state,error_code=$error WHERE session_id=$id AND turn_token=$turn AND attempt_token=$attempt AND role='assistant' AND state IN ('waiting','streaming')",null,("$text",turn.Answer),("$state",turn.State),("$error",turn.Error),("$id",session),("$turn",turn.TurnToken),("$attempt",turn.Attempt));
        if(cmd.ExecuteNonQuery()!=1)throw new InvalidOperationException("对话已改变，迟到回复未写入。");return 0;
    });
    public Task<LibraryItem> SaveSummaryAsync(string title,string body,string category)=>Enqueue(()=> {
        if(string.IsNullOrWhiteSpace(body)||!Categories.Contains(category))throw new ArgumentException("请检查整理内容和分类。");
        using var tx=connection.BeginTransaction();CheckDuplicate(LibraryKind.Inspirations,body,tx:tx);
        using var cmd=Command("INSERT INTO inspirations(title,body,category,category_source,title_source,created_at_utc_ms,updated_at_utc_ms,source,origin_kind,sort_order) VALUES($title,$body,$category,'user','user',$time,$time,'ai_chat','ai_chat',(SELECT COALESCE(MAX(sort_order),0)+1 FROM inspirations));SELECT last_insert_rowid();",tx,("$title",title),("$body",body),("$category",category),("$time",DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
        long id=Convert.ToInt64(cmd.ExecuteScalar());tx.Commit();return Item(LibraryKind.Inspirations,id)!;
    });
}
