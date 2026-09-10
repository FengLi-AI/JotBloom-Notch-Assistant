using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace JotBloom.Windows.Storage;

public sealed record Inspiration(long Id, string Title, string Body, string Category, long CreatedAt);
public sealed class DuplicateInspirationException() : Exception("这条灵感已经保存过了，输入内容仍为你保留。");

/// <summary>One ordered worker queue. No SQLite work runs on the WPF dispatcher.</summary>
public sealed partial class BloomStore : IAsyncDisposable
{
    public const string DatabaseName = "jotbloom.sqlite";
    private readonly SqliteConnection connection;
    private readonly object gate = new();
    private Task tail = Task.CompletedTask;
    private bool closing;
    public string DirectoryPath { get; }
    internal static string Schema {
        get {
            using var reader = new StreamReader(typeof(BloomStore).Assembly.GetManifestResourceStream(
                "JotBloom.Windows.Storage.SchemaV7.sql")!);
            return reader.ReadToEnd();
        }
    }
    private BloomStore(string directory)
    {
        DirectoryPath = directory;
        EnsureCurrent(directory);Validate(directory);
        connection = Connect(Path.Combine(directory, DatabaseName), SqliteOpenMode.ReadWrite);
        try { Execute(connection, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; UPDATE chat_messages SET state='interrupted',error_code='interrupted' WHERE state IN ('waiting','streaming');"); }
        catch { connection.Dispose(); throw; }
    }
    public static Task<BloomStore> OpenAsync(string directory) => Task.Run(() => new BloomStore(directory));
    internal static SqliteConnection Connect(string path, SqliteOpenMode mode)
    {
        var result = new SqliteConnection(new SqliteConnectionStringBuilder {
            DataSource = path, Mode = mode, Pooling = false, ForeignKeys = true, DefaultTimeout = 5
        }.ToString());
        try { result.Open(); return result; } catch { result.Dispose(); throw; }
    }
    internal static void Initialize(string directory)
    {
        string path = Path.Combine(directory, DatabaseName);
        // Exclusively reserve our database; never bootstrap an existing file.
        using (new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { }
        using var db = Connect(path, SqliteOpenMode.ReadWrite);
        using var tx = db.BeginTransaction();
        Execute(db, Schema, tx); tx.Commit();
        Directory.CreateDirectory(Path.Combine(directory, "Clipboard"));
    }
    public static void Validate(string directory)
    {
        string path = Path.Combine(directory, DatabaseName);
        DataLocation.RequireRegularFile(path);
        using var db = Connect(path, SqliteOpenMode.ReadOnly);
        if (Convert.ToInt64(Scalar(db, "PRAGMA user_version")) != 7)
            throw new IOException("数据版本暂不支持。请保留原目录，当前 Windows 开发版只接入 V7 数据。");
        if (!Equals(Scalar(db, "PRAGMA quick_check"), "ok") || Scalar(db, "PRAGMA foreign_key_check") is not null)
            throw new IOException("数据检查未通过，请保留原目录并恢复备份。");
        using var expected = Connect(":memory:", SqliteOpenMode.Memory);
        Execute(expected, Schema);
        if (!Objects(db).SequenceEqual(Objects(expected)))
            throw new IOException("数据结构与当前版本不匹配，已停止打开，未新建空库。");
    }
    private static List<string> Objects(SqliteConnection db,SqliteTransaction? tx=null)
    {
        using var command = db.CreateCommand();command.Transaction=tx;
        command.CommandText = "SELECT type,name,sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY type,name";
        using var rows = command.ExecuteReader();
        var result = new List<string>();
        while (rows.Read()) result.Add(rows.GetString(0) + ":" + rows.GetString(1) + ":" + Regex.Replace(rows.GetString(2), @"\s+", " ").Trim());
        return result;
    }
    private Task<T> Enqueue<T>(Func<T> action)
    {
        lock (gate) {
            if (closing) return Task.FromException<T>(new ObjectDisposedException(nameof(BloomStore)));
            // Continue even when an earlier request failed; callers still receive its exception.
            var next = tail.ContinueWith(_ => action(), CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
            tail = next; return next;
        }
    }
    public Task<string> LoadDraftAsync() => Enqueue(() => Scalar(connection,
        "SELECT content FROM drafts WHERE kind='inspiration'") as string ?? "");
    public Task PersistDraftAsync(string text) => Enqueue(() => {
        using var cmd = connection.CreateCommand();
        cmd.CommandText = text.Length == 0 ? "DELETE FROM drafts WHERE kind='inspiration'" :
            "INSERT INTO drafts(kind,content,updated_at_utc_ms) VALUES('inspiration',$text,$time) " +
            "ON CONFLICT(kind) DO UPDATE SET content=excluded.content,updated_at_utc_ms=excluded.updated_at_utc_ms";
        if (text.Length != 0) { cmd.Parameters.AddWithValue("$text", text); cmd.Parameters.AddWithValue("$time", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()); }
        return cmd.ExecuteNonQuery();
    });
    public Task<Inspiration> SaveAsync(string text) => Enqueue(() => {
        if (string.IsNullOrWhiteSpace(text)) throw new ArgumentException("先写下一点想法吧。");
        string firstLine = text.Split('\n')[0];
        int[] elements = StringInfo.ParseCombiningCharacters(firstLine);
        string title = elements.Length > 30 ? firstLine[..elements[30]] : firstLine;
        long time = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        using var tx = connection.BeginTransaction();
        using (var check = connection.CreateCommand()) {
            check.Transaction = tx; check.CommandText = "SELECT body FROM inspirations";
            using var rows = check.ExecuteReader();
            string normalized = text.Normalize(NormalizationForm.FormC);
            while (rows.Read()) if (rows.GetString(0).Normalize(NormalizationForm.FormC) == normalized) throw new DuplicateInspirationException();
        }
        using var insert = connection.CreateCommand(); insert.Transaction = tx;
        insert.CommandText = """
            INSERT INTO inspirations(title,body,category,category_source,created_at_utc_ms,updated_at_utc_ms,source,sort_order)
            VALUES($title,$body,'idea','fallback',$time,$time,'manual',(SELECT COALESCE(MAX(sort_order),0)+1 FROM inspirations));
            SELECT last_insert_rowid();
            """;
        insert.Parameters.AddWithValue("$title", title); insert.Parameters.AddWithValue("$body", text); insert.Parameters.AddWithValue("$time", time);
        long id = Convert.ToInt64(insert.ExecuteScalar());
        Execute(connection, "DELETE FROM drafts WHERE kind='inspiration'", tx);
        tx.Commit(); return new Inspiration(id, title, text, "idea", time);
    });
    public Task<IReadOnlyList<Inspiration>> RecentAsync(int limit = 5) => Enqueue<IReadOnlyList<Inspiration>>(() => {
        using var cmd = connection.CreateCommand();
        cmd.CommandText = "SELECT id,title,body,category,created_at_utc_ms FROM inspirations ORDER BY created_at_utc_ms DESC,id DESC LIMIT $limit";
        cmd.Parameters.AddWithValue("$limit", Math.Clamp(limit, 0, 5));
        using var rows = cmd.ExecuteReader(); var result = new List<Inspiration>();
        while (rows.Read()) result.Add(new(rows.GetInt64(0), rows.GetString(1), rows.GetString(2), rows.GetString(3), rows.GetInt64(4)));
        return result;
    });
    internal static object? Scalar(SqliteConnection db, string sql)
    {
        using var cmd = db.CreateCommand(); cmd.CommandText = sql; return cmd.ExecuteScalar();
    }
    internal static void Execute(SqliteConnection db, string sql, SqliteTransaction? tx = null)
    {
        using var cmd = db.CreateCommand(); cmd.CommandText = sql; cmd.Transaction = tx; cmd.ExecuteNonQuery();
    }
    public ValueTask DisposeAsync()
    {
        lock (gate) {
            if (!closing) { closing = true; tail = tail.ContinueWith(_ => connection.Dispose(), TaskScheduler.Default); }
            return new ValueTask(tail);
        }
    }
}
