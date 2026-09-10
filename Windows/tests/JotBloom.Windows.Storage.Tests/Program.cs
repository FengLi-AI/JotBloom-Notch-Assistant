using System.Text.Json.Nodes;
using JotBloom.Windows.Core;
using JotBloom.Windows.Storage;
using Microsoft.Data.Sqlite;

// Real SQLite/file IO on disposable directories. Never resolve the application's production locator.
string testRoot = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "jotbloom-storage-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(testRoot);
int passed = 0;
void Require(bool value) { if (!value) throw new Exception("Contract failed"); }
async Task Check(string name, Func<string, Task> test)
{
    string root = Path.Combine(testRoot, passed.ToString()); Directory.CreateDirectory(root);
    try { await test(root); ++passed; Console.WriteLine("PASS " + name); }
    catch (Exception e) { Console.Error.WriteLine("FAIL " + name + ": " + e); Environment.ExitCode = 1; throw; }
}
async Task Throws<T>(Func<Task> run) where T : Exception
{
    try { await run(); } catch (T) { return; }
    throw new Exception("Expected " + typeof(T).Name);
}
DataLocation Location(string root) => new(Path.Combine(root, "control"));
string Create(string root)
{
    string parent = Path.Combine(root, "chosen"); Directory.CreateDirectory(parent);
    return Location(root).Create(parent);
}
object? SQL(string directory, string sql)
{
    using var db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = Path.Combine(directory, BloomStore.DatabaseName), Mode = SqliteOpenMode.ReadWrite, Pooling = false, ForeignKeys = true }.ToString());
    db.Open(); using var cmd = db.CreateCommand(); cmd.CommandText = sql; return cmd.ExecuteScalar();
}
try {
    await Check("cancel-before-selection has no side effects", root => {
        Require(Location(root).Resolve() is null && !Directory.Exists(Path.Combine(root, "control"))); return Task.CompletedTask;
    });
    await Check("new selection creates V7 and durable locator; next launch reuses it", root => {
        string data = Create(root); Require(Location(root).Resolve() == data);
        Require(Convert.ToInt64(SQL(data, "PRAGMA user_version")) == 7);
        Require(File.ReadAllText(Path.Combine(data, "data-identity")).Length == 36); return Task.CompletedTask;
    });
    await Check("existing target never overwritten", async root => {
        string data = Path.Combine(root, "JotBloom"); Directory.CreateDirectory(data); File.WriteAllText(Path.Combine(data, "keep.txt"), "keep");
        await Throws<IOException>(() => Task.Run(() => Location(root).Create(root)));
        Require(File.ReadAllText(Path.Combine(data, "keep.txt")) == "keep" && Location(root).Resolve() is null);
    });
    await Check("invalid locator fails without creating a new database", async root => {
        string control = Path.Combine(root, "control"); Directory.CreateDirectory(control); File.WriteAllText(Path.Combine(control, "data-location.json"), "broken");
        await Throws<System.Text.Json.JsonException>(() => Task.Run(() => Location(root).Resolve()));
        Require(!Directory.Exists(Path.Combine(root, "JotBloom")));
    });
    await Check("missing original directory does not silently reset", async root => {
        string data = Create(root); Directory.Move(data, data + "-offline");
        await Throws<IOException>(() => Task.Run(() => Location(root).Resolve())); Require(!Directory.Exists(data));
    });
    await Check("identity mismatch stops opening", async root => {
        string data = Create(root); File.WriteAllText(Path.Combine(data, "data-identity"), Guid.NewGuid().ToString());
        await Throws<IOException>(() => Task.Run(() => Location(root).Resolve()));
    });
    await Check("missing database is not recreated", async root => {
        string data = Create(root); File.Delete(Path.Combine(data, BloomStore.DatabaseName));
        await Throws<IOException>(() => BloomStore.OpenAsync(data));
        Require(!File.Exists(Path.Combine(data, BloomStore.DatabaseName)));
    });
    await Check("mislabeled V7 schema cannot masquerade as historical V6", async root => {
        string data = Create(root); SQL(data, "PRAGMA user_version=6");
        await Throws<IOException>(() => BloomStore.OpenAsync(data)); Require(Convert.ToInt64(SQL(data, "PRAGMA user_version")) == 6);
    });
    await Check("newer schema refused without modification", async root => {
        string data = Create(root); SQL(data, "PRAGMA user_version=8");
        await Throws<IOException>(() => BloomStore.OpenAsync(data)); Require(Convert.ToInt64(SQL(data, "PRAGMA user_version")) == 8);
    });
    await Check("V7 with missing trigger refused", async root => {
        string data = Create(root); SQL(data, "DROP TRIGGER inspiration_lifecycle");
        await Throws<IOException>(() => BloomStore.OpenAsync(data));
    });
    await Check("draft survives close and reopen", async root => {
        string data = Create(root);
        await using (var db = await BloomStore.OpenAsync(data)) { await db.PersistDraftAsync("首行\nsecond\n"); }
        await using var reopened = await BloomStore.OpenAsync(data); Require(await reopened.LoadDraftAsync() == "首行\nsecond\n");
    });
    await Check("ordered rapid drafts cannot overwrite the newest text", async root => {
        await using var db = await BloomStore.OpenAsync(Create(root));
        var writes = Enumerable.Range(0, 100).Select(i => db.PersistDraftAsync("草稿" + i)).ToArray();
        await Task.WhenAll(writes); Require(await db.LoadDraftAsync() == "草稿99");
    });
    await Check("save preserves exact full text, clears draft and creates lifecycle", async root => {
        string data = Create(root); await using var db = await BloomStore.OpenAsync(data);
        const string text = "  标题  \n正文\n"; await db.PersistDraftAsync(text);
        var saved = await db.SaveAsync(text); Require(saved.Title == "  标题  " && saved.Body == text && saved.Category == "idea");
        Require(await db.LoadDraftAsync() == "" && Convert.ToInt64(SQL(data, "SELECT length(lifecycle_token) FROM inspirations")) == 32);
    });
    await Check("Unicode title uses 30 grapheme clusters", async root => {
        await using var db = await BloomStore.OpenAsync(Create(root));
        string title = string.Concat(Enumerable.Repeat("👨‍👩‍👧‍👦", 30)); var item = await db.SaveAsync(title + "Z\n正文");
        Require(item.Title == title);
    });
    await Check("blank input rejected and draft retained", async root => {
        await using var db = await BloomStore.OpenAsync(Create(root)); await db.PersistDraftAsync(" \n");
        await Throws<ArgumentException>(() => db.SaveAsync(" \n")); Require(await db.LoadDraftAsync() == " \n");
    });
    await Check("duplicate rollback retains draft and previous row", async root => {
        await using var db = await BloomStore.OpenAsync(Create(root)); await db.SaveAsync("café"); await db.PersistDraftAsync("cafe\u0301");
        await Throws<DuplicateInspirationException>(() => db.SaveAsync("cafe\u0301"));
        Require(await db.LoadDraftAsync() == "cafe\u0301" && (await db.RecentAsync()).Count == 1);
        await db.SaveAsync("next"); Require((await db.RecentAsync()).Count == 2); // Queue continues after an error.
    });
    await Check("failed insert rolls back atomically and keeps draft", async root => {
        string data = Create(root); await using var db = await BloomStore.OpenAsync(data); await db.PersistDraftAsync("keep me");
        SQL(data, "CREATE TRIGGER fail_insert BEFORE INSERT ON inspirations BEGIN SELECT RAISE(ABORT,'injected'); END;");
        await Throws<SqliteException>(() => db.SaveAsync("keep me"));
        Require(await db.LoadDraftAsync() == "keep me" && (await db.RecentAsync()).Count == 0);
    });
    await Check("recent list limited to five and ordered by newest", async root => {
        await using var db = await BloomStore.OpenAsync(Create(root)); for (int i = 0; i < 7; ++i) await db.SaveAsync("record " + i);
        var recent = await db.RecentAsync(100); Require(recent.Count == 5 && recent[0].Body == "record 6" && recent[4].Body == "record 2");
    });
    await Check("shutdown drains pending drafts", async root => {
        string data = Create(root); var db = await BloomStore.OpenAsync(data);
        var writes = Enumerable.Range(0, 30).Select(i => db.PersistDraftAsync(i.ToString())).ToArray();
        await db.DisposeAsync(); await Task.WhenAll(writes);
        await Throws<ObjectDisposedException>(() => db.LoadDraftAsync());
        await using var reopened = await BloomStore.OpenAsync(data); Require(await reopened.LoadDraftAsync() == "29");
    });
    await Check("interrupted locator commit recovers existing data", async root => {
        string data = Create(root);
        await using (var db = await BloomStore.OpenAsync(data)) { await db.SaveAsync("recover me"); }
        string locator = Path.Combine(root, "control", "data-location.json");
        File.Move(locator, Path.Combine(root, "control", "initial-setup.json"));
        Require(Location(root).Resolve() == data);
        await using var reopened = await BloomStore.OpenAsync(data); Require((await reopened.RecentAsync())[0].Body == "recover me");
    });
    await Check("interrupted directory rename completes with identity validation", root => {
        string data = Create(root), locator = Path.Combine(root, "control", "data-location.json");
        var record = JsonNode.Parse(File.ReadAllText(locator))!;
        string staging = Path.Combine(Path.GetDirectoryName(data)!, ".jotbloom-setup-" + record["Identity"]!.GetValue<string>());
        record["StagingPath"] = staging; Directory.Move(data, staging);
        File.WriteAllText(Path.Combine(root, "control", "initial-setup.json"), record.ToJsonString()); File.Delete(locator);
        Require(Location(root).Resolve() == data && !Directory.Exists(staging)); return Task.CompletedTask;
    });
    await Check("unknown old control files fail closed", async root => {
        Directory.CreateDirectory(Path.Combine(root, "control")); File.WriteAllText(Path.Combine(root, "control", "migration.json"), "keep");
        await Throws<IOException>(() => Task.Run(() => Location(root).Resolve()));
    });
    await Check("prompt save-as creates independent record and retains original",async root=>{
        await using var db=await BloomStore.OpenAsync(Create(root));var original=await db.CreatePromptAsync("original","原提示词");var copy=await db.CreatePromptAsync("edited copy","副本");
        Require((await db.GetAsync(LibraryKind.Prompts,original.Id))!.Content=="original"&&copy.Id!=original.Id);
        await Throws<InvalidOperationException>(()=>db.CreatePromptAsync("edited copy"));Require((await db.ListAsync(LibraryKind.Prompts)).Items.Count==2);
    });
    await Check("prompt consumption and duplicate preserve input draft atomically",async root=>{
        await using var db=await BloomStore.OpenAsync(Create(root));await db.PersistDraftAsync("prompt");await db.CreatePromptAsync("prompt",consumeDraft:true);Require(await db.LoadDraftAsync()=="");
        await db.PersistDraftAsync("prompt");await Throws<InvalidOperationException>(()=>db.CreatePromptAsync("prompt",consumeDraft:true));Require(await db.LoadDraftAsync()=="prompt");
    });
    await Check("manual fields and edited bodies reject stale AI",async root=>{
        await using var db=await BloomStore.OpenAsync(Create(root));var id=(await db.SaveAsync("idea")).Id;var snapshot=(await db.GetAsync(LibraryKind.Inspirations,id))!;
        var edited=await db.UpdateAsync(snapshot,"my title","idea","作品类");await db.ApplyAIAsync(snapshot,"AI title","产品类");var after=(await db.GetAsync(LibraryKind.Inspirations,id))!;Require(after.Title=="my title"&&after.Category=="作品类");
        edited=await db.UpdateAsync(after,after.Title,"changed body",after.Category);Require(!await db.ApplyAIAsync(snapshot,"late","idea"));
        await Throws<InvalidOperationException>(()=>db.UpdateAsync(snapshot,"stale","body","idea"));
    });
    await Check("prompt editing invalidates old AI response",async root=>{
        await using var db=await BloomStore.OpenAsync(Create(root));var p=await db.CreatePromptAsync("draft");await db.UpdateAsync(p,"manual","edited","");Require(!await db.ApplyAIAsync(p,"late",null));
    });
    await Check("delete undo creates fresh lifecycle and blocks late AI",async root=>{
        await using var db=await BloomStore.OpenAsync(Create(root));var item=await db.CreatePromptAsync("keep");var token=await db.DeleteAsync(LibraryKind.Prompts,item.Id);Require(await db.GetAsync(LibraryKind.Prompts,item.Id)==null);
        Require(await db.UndoAsync(token.Token));Require(!await db.ApplyAIAsync(item,"late",null));Require(!await db.UndoAsync(token.Token));
    });
    await Check("clipboard text and links deduplicate while updating source",async root=>{
        await using var db=await BloomStore.OpenAsync(Create(root));var first=(await db.CaptureAsync(new("hello",SourceName:"App1")))!;var second=(await db.CaptureAsync(new("hello",SourceName:"App2")))!;
        Require(first.Id==second.Id&&second.Source=="App2");var link=(await db.CaptureAsync(new("https://example.com")))!;Require(link.ContentType=="link"&&(await db.UsageAsync()).Records==2);
    });
    await Check("clipboard imports preserve content and source after deletion",async root=>{
        string data=Create(root);await using var db=await BloomStore.OpenAsync(data);var clip=(await db.CaptureAsync(new("source text",SourceName:"Editor")))!;
        var prompt=await db.CreatePromptAsync(clip.Content,clipboardId:clip.Id);var inspiration=await db.ImportClipboardInspirationAsync(clip.Id);Require((await db.GetAsync(LibraryKind.Clipboard,clip.Id))!.Favorite);
        var token=await db.DeleteAsync(LibraryKind.Clipboard,clip.Id);Require((await db.GetAsync(LibraryKind.Prompts,prompt.Id))!.Content==clip.Content);Require(SQL(data,"SELECT source_clipboard_id FROM prompts") is DBNull);
        Require(await db.UndoAsync(token.Token));Require(Convert.ToInt64(SQL(data,"SELECT source_clipboard_id FROM prompts"))==clip.Id);Require((await db.GetAsync(LibraryKind.Inspirations,inspiration.Id))!.Source=="Editor");
    });
    await Check("image assets are deduplicated and backup contains originals",async root=>{
        string data=Create(root);await using var db=await BloomStore.OpenAsync(data);byte[] png=Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=");
        var image=(await db.CaptureAsync(new(null,png,png,1,1)))!;Require((await db.CaptureAsync(new(null,png,png,1,1)))!.Id==image.Id);
        string backup=await db.CopyDirectoryAsync(root,true);Require(File.ReadAllBytes(Path.Combine(backup,"Clipboard",image.Image!)).SequenceEqual(png));
        var token=await db.DeleteAsync(LibraryKind.Clipboard,image.Id);await db.PruneAsync(new());Require(File.Exists(db.AssetPath(image.Image!)));Require(await db.UndoAsync(token.Token));
        await db.ClearClipboardAsync();Require(!File.Exists(db.AssetPath(image.Image!))&&File.Exists(Path.Combine(backup,"Clipboard",image.Image!)));
    });
    await Check("retention removes oldest excess without deleting saved prompts",async root=>{
        await using var db=await BloomStore.OpenAsync(Create(root));var first=(await db.CaptureAsync(new("first")))!;await db.CreatePromptAsync("first",clipboardId:first.Id);
        for(int i=0;i<105;i++)await db.CaptureAsync(new("record"+i));await db.PruneAsync(new(){MaximumCount=100});Require((await db.UsageAsync()).Records==100&&(await db.ListAsync(LibraryKind.Prompts)).Items.Count==1);
    });
    await Check("clear history preserves unrelated files",async root=>{
        string data=Create(root);await using var db=await BloomStore.OpenAsync(data);string keep=Path.Combine(data,"Clipboard","notes.txt");File.WriteAllText(keep,"keep");await db.ClearClipboardAsync();Require(File.ReadAllText(keep)=="keep");
    });
    await Check("manual order favorite filter and keyset pagination",async root=>{
        await using var db=await BloomStore.OpenAsync(Create(root));var a=await db.CreatePromptAsync("a");var b=await db.CreatePromptAsync("b");var c=await db.CreatePromptAsync("c");await db.MoveBeforeAsync(LibraryKind.Prompts,a.Id,c.Id);
        var first=await db.ListAsync(LibraryKind.Prompts,limit:2);var next=await db.ListAsync(LibraryKind.Prompts,first.Next,limit:2);Require(first.Items.Select(i=>i.Id).SequenceEqual(new[]{a.Id,c.Id})&&next.Items.Single().Id==b.Id&&next.Next is null);
        await db.SetFavoriteAsync(b.Id,true);Require((await db.ListAsync(LibraryKind.Prompts,favorites:true)).Items.Single().Id==b.Id);
    });
    await Check("search full content accents counts and category paging",async root=>{
        await using var db=await BloomStore.OpenAsync(Create(root));await db.SaveAsync("a\nCAFÉ hidden");for(int i=0;i<4;i++)await db.CreatePromptAsync("café "+i);await db.CaptureAsync(new("café clip"));
        var all=await db.SearchAsync("cafe");Require(all.Counts[LibraryKind.Prompts]==4&&all.Items.Count==4);var page=await db.SearchAsync("cafe",LibraryKind.Prompts,2);Require(page.Items.Count==2);
    });
    await Check("backup captures WAL and relocation preserves original",async root=>{
        string data=Create(root);await using var db=await BloomStore.OpenAsync(data);await db.SaveAsync("wal record");await db.PersistDraftAsync("draft");string backup=await db.CopyDirectoryAsync(root,true);
        Require(Location(root).Relocate(backup)==backup&&Location(root).Resolve()==backup&&Directory.Exists(data));await using var restored=await BloomStore.OpenAsync(backup);Require(await restored.LoadDraftAsync()=="draft"&&(await restored.RecentAsync()).Single().Body=="wal record");
        await Throws<IOException>(()=>db.CopyDirectoryAsync(data,true));await Throws<IOException>(()=>Task.Run(()=>Location(root).Relocate(Create(Path.Combine(root,"not-same")))));
    });
    await Check("chat submission consumes only intended drafts and snapshots system prompt",async root=>{
        await using var db=await BloomStore.OpenAsync(Create(root));var session=await db.CurrentSessionAsync("custom prompt");await db.PersistDraftAsync("from input");await db.PersistChatDraftAsync(session.Id,"chat draft");var turn=await db.SubmitAsync(session.Id,"from input",true);
        Require(await db.LoadDraftAsync()==""&&(await db.SelectSessionAsync(session.Id)).Draft==""&&session.SystemPrompt=="custom prompt");await Throws<InvalidOperationException>(()=>db.SubmitAsync(session.Id,"double"));
        await db.UpdateTurnAsync(session.Id,turn with{Answer="partial",State="stopped"});var retry=await db.RetryAsync(session.Id,turn with{State="stopped"});Require(retry.Attempt!=turn.Attempt);
        await Throws<InvalidOperationException>(()=>db.UpdateTurnAsync(session.Id,turn with{State="complete",Answer="late"}));await db.UpdateTurnAsync(session.Id,retry with{Answer="final",State="complete"});Require((await db.TurnsAsync(session.Id)).Single().Answer=="final");
    });
    await Check("reopening interrupts active stream and keeps partial answer",async root=>{
        string data=Create(root);long id;
        await using(var db=await BloomStore.OpenAsync(data)){var session=await db.CurrentSessionAsync("system");id=session.Id;var turn=await db.SubmitAsync(id,"hello");await db.UpdateTurnAsync(id,turn with{Answer="partial",State="streaming"});}
        await using var reopened=await BloomStore.OpenAsync(data);var saved=(await reopened.TurnsAsync(id)).Single();Require(saved.Answer=="partial"&&saved.State=="interrupted");
    });
    await Check("chat sessions preserve drafts and delete cascades messages",async root=>{
        await using var db=await BloomStore.OpenAsync(Create(root));var first=await db.CurrentSessionAsync("one");await db.PersistChatDraftAsync(first.Id,"retained");var second=await db.NewSessionAsync("two");await db.SubmitAsync(second.Id,"question");Require((await db.SelectSessionAsync(first.Id)).Draft=="retained");await db.DeleteSessionAsync(second.Id);Require((await db.TurnsAsync(second.Id)).Count==0&&(await db.SessionsAsync()).Count==1);
    });
    await Check("summary insertion preserves inspiration draft",async root=>{
        await using var db=await BloomStore.OpenAsync(Create(root));await db.PersistDraftAsync("unsent");var summary=await db.SaveSummaryAsync("title","summary","产品类");Require(summary.Category=="产品类"&&await db.LoadDraftAsync()=="unsent");
    });
    await Check("all six historical schemas migrate with verified non-overwriting backups",async root=>{
        for(int version=1;version<7;version++){
            string child=Path.Combine(root,"v"+version);Directory.CreateDirectory(child);string data=Create(child);
            File.Delete(Path.Combine(data,BloomStore.DatabaseName));using var reader=new StreamReader(typeof(BloomStore).Assembly.GetManifestResourceStream("JotBloom.Windows.Storage.Migrations.SchemaV"+version+".sql")!);
            using(var raw=new SqliteConnection("Data Source="+Path.Combine(data,BloomStore.DatabaseName))){raw.Open();using var cmd=raw.CreateCommand();cmd.CommandText=reader.ReadToEnd()+"INSERT INTO inspirations(title,body,category,category_source,created_at_utc_ms,updated_at_utc_ms,source) VALUES('标题','正文','idea','fallback',1,1,'manual');";cmd.ExecuteNonQuery();}
            Require(Location(child).Resolve()==data);Require(File.Exists(Path.Combine(data,BloomStore.DatabaseName)+".bak-v"+version));await using var upgraded=await BloomStore.OpenAsync(data);Require((await upgraded.RecentAsync()).Single().Body=="标题\n正文");
        }
    });
    await Check("migration stops if backup already exists without touching original",async root=>{
        string data=Create(root);File.Delete(Path.Combine(data,BloomStore.DatabaseName));using var reader=new StreamReader(typeof(BloomStore).Assembly.GetManifestResourceStream("JotBloom.Windows.Storage.Migrations.SchemaV6.sql")!);
        using(var raw=new SqliteConnection("Data Source="+Path.Combine(data,BloomStore.DatabaseName))){raw.Open();using var cmd=raw.CreateCommand();cmd.CommandText=reader.ReadToEnd();cmd.ExecuteNonQuery();}
        string backup=Path.Combine(data,BloomStore.DatabaseName)+".bak-v6";File.WriteAllText(backup,"keep");await Throws<IOException>(()=>BloomStore.OpenAsync(data));Require(Convert.ToInt64(SQL(data,"PRAGMA user_version"))==6&&File.ReadAllText(backup)=="keep");
    });
    await Check("late AI metadata merges with manual body editing",async root=>{
        await using var db=await BloomStore.OpenAsync(Create(root));var id=(await db.SaveAsync("body")).Id;var snapshot=(await db.GetAsync(LibraryKind.Inspirations,id))!;await db.ApplyAIAsync(snapshot,"AI title","产品类");
        var saved=await db.UpdateAsync(snapshot,snapshot.Title,"edited body",snapshot.Category);Require(saved.Title=="AI title"&&saved.Content=="edited body"&&saved.Category=="产品类");
    });
    await Check("explicit reconnect repairs corrupt locator and preserves its bytes",root=>{
        string data=Create(root);string locator=Path.Combine(root,"control","data-location.json");File.WriteAllText(locator,"corrupt original");Require(Location(root).Reconnect(data)==data&&Location(root).Resolve()==data);Require(Directory.GetFiles(Path.Combine(root,"control"),"data-location.json.recovery-*").Select(File.ReadAllText).Single()=="corrupt original");return Task.CompletedTask;
    });
    Console.WriteLine($"Passed {passed} storage contract checks; Windows UI not exercised.");
} finally { Directory.Delete(testRoot, recursive: true); }
