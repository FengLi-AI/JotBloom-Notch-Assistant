namespace JotBloom.Windows.Storage;

public enum LibraryKind { Inspirations, Prompts, Clipboard }
public sealed record LibraryItem(LibraryKind Kind, long Id, string Title, string Content, string Category,
    long Created, long Sort, bool Favorite = false, string ContentType = "text", string? Image = null,
    string? Thumbnail = null, string Source = "", long Bytes = 0, string Lifecycle = "", long Revision = 0,
    long TitleRevision = 0, long CategoryRevision = 0);
public sealed record PageCursor(long Sort, long Id);
public sealed record LibraryPage(IReadOnlyList<LibraryItem> Items, PageCursor? Next);
public sealed record SearchResults(IReadOnlyDictionary<LibraryKind, int> Counts, IReadOnlyList<LibraryItem> Items);
public sealed record Deletion(string Token, DateTimeOffset Expires);
public sealed record ClipboardInput(string? Text, byte[]? Png = null, byte[]? Thumbnail = null,
    int Width = 0, int Height = 0, string SourceName = "", string SourceId = "");
public sealed record ChatSession(long Id, string Token, string Title, string Draft, string SystemPrompt, long Updated);
public sealed record ChatTurn(long Id, string TurnToken, string Attempt, string User, string Answer, string State, string? Error);
public sealed record StorageUsage(long Records, long Bytes, long Images);
