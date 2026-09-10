using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace JotBloom.Windows.Core;

public sealed record AiMessage([property:JsonPropertyName("role")]string Role,[property:JsonPropertyName("content")]string Content);
public sealed class AiException(string message):Exception(message);
public static class ModelEndpoint
{
    public static Uri Normalize(string raw)
    {
        string value=raw.Trim().TrimEnd('/');
        if(value.EndsWith("/chat/completions",StringComparison.Ordinal))value=value[..^17].TrimEnd('/');
        if(value.Any(char.IsWhiteSpace)||!Uri.TryCreate(value,UriKind.Absolute,out var uri)||string.IsNullOrEmpty(uri.Host)||
            uri.UserInfo.Length>0||uri.Query.Length>0||uri.Fragment.Length>0||
            !(uri.Scheme=="https"||uri.Scheme=="http"&&new[]{"localhost","127.0.0.1","[::1]","::1"}.Contains(uri.Host.ToLowerInvariant())))
            throw new AiException("请输入 HTTPS 接口地址；只有本机回环地址允许 HTTP。地址不能包含账号、查询参数或片段。");
        return new Uri(value+"/chat/completions");
    }
}
public sealed class SseDecoder
{
    private readonly List<byte> line=[];
    private readonly List<string> data=[];
    private int frameBytes,total;
    private string? finish;
    private bool hasText;
    public bool Done {get;private set;}
    public string Feed(byte value)
    {
        if(++total>1_048_576)throw new AiException("回复超过长度限制，已停止接收。");
        if(value!=10){line.Add(value);if(line.Count+frameBytes>65_536)throw new AiException("回复片段过大。");return "";}
        if(line.Count>0&&line[^1]==13)line.RemoveAt(line.Count-1);
        string text=new UTF8Encoding(false,true).GetString(line.ToArray());line.Clear();
        if(text.Length!=0){frameBytes+=Encoding.UTF8.GetByteCount(text)+1;if(frameBytes>65_536)throw new AiException("回复片段过大。");
            if(text=="data")data.Add("");else if(text.StartsWith("data:",StringComparison.Ordinal)){var payload=text[5..];data.Add(payload.StartsWith(' ')?payload[1..]:payload);}return "";}
        string content=string.Join("\n",data);data.Clear();frameBytes=0;if(content.Length==0)return "";
        if(Done)throw new AiException("流式回复格式无效。");
        if(content=="[DONE]"){Done=true;return "";}
        using var json=JsonDocument.Parse(content);var root=json.RootElement;
        if(root.TryGetProperty("error",out _)||!root.TryGetProperty("choices",out var choices)||choices.ValueKind!=JsonValueKind.Array)throw new AiException("服务未返回有效流式回复。");
        if(choices.GetArrayLength()==0)return "";
        if(finish is not null)throw new AiException("回复结束后收到异常内容。");
        var choice=choices[0];if(choice.TryGetProperty("index",out var index)&&index.GetInt32()!=0)throw new AiException("回复索引无效。");
        var delta=choice.GetProperty("delta");
        if(delta.TryGetProperty("tool_calls",out _)||delta.TryGetProperty("function_call",out _)||delta.TryGetProperty("role",out var role)&&role.GetString()!="assistant")throw new AiException("仅支持文本回复。");
        if(choice.TryGetProperty("finish_reason",out var reason)&&reason.ValueKind!=JsonValueKind.Null){finish=reason.GetString();if(finish is not("stop" or "length"))throw new AiException("回复被服务中止。");}
        string result=delta.TryGetProperty("content",out var c)&&c.ValueKind!=JsonValueKind.Null?c.GetString()??"":"";
        if(!string.IsNullOrWhiteSpace(result))hasText=true;return result;
    }
    public string Completion()
    {
        if(!Done||finish is null)throw new AiException("回复中途断开，已收到的内容保留，可重试。");
        if(!hasText)throw new AiException("模型没有返回正式回答，请检查模型配置。");return finish=="length"?"length":"complete";
    }
}
public sealed class AiClient:IDisposable
{
    private readonly HttpClient http;
    private readonly bool owned;
    public AiClient(HttpClient? client=null)
    {
        owned=client is null;http=client??new HttpClient(new HttpClientHandler{AllowAutoRedirect=false,UseCookies=false}){Timeout=Timeout.InfiniteTimeSpan};
    }
    public static int Estimate(string text){int ascii=0,other=0;foreach(var rune in text.EnumerateRunes()){if(rune.IsAscii)ascii++;else other++;}return other+(ascii+3)/4;}
    public static IReadOnlyList<AiMessage> Context(IEnumerable<(string User,string Answer)> history,string input,string system)
    {
        if(string.IsNullOrWhiteSpace(input))throw new AiException("请输入消息。");
        var turns=history.ToList();string prompt=AiPrompts.Rules+"\n\n用户行为偏好：\n"+system;
        int total=Estimate(prompt)+Estimate(input)+12+turns.Sum(t=>Estimate(t.User)+Estimate(t.Answer)+12);
        while(total>8000&&turns.Count>3){var t=turns[0];turns.RemoveAt(0);total-=Estimate(t.User)+Estimate(t.Answer)+12;}
        if(total>8000)throw new AiException("输入或最近三轮内容太长，请缩短输入或开始新对话。");
        var messages=new List<AiMessage>{new("system",prompt)};foreach(var t in turns){messages.Add(new("user",t.User));messages.Add(new("assistant",t.Answer));}messages.Add(new("user",input));return messages;
    }
    private static HttpRequestMessage Request(ModelConfiguration config,string key,IReadOnlyList<AiMessage> messages,bool stream)
    {
        if(string.IsNullOrWhiteSpace(config.Model))throw new AiException("请先在设置中填写模型名称。");
        if(string.IsNullOrWhiteSpace(key)||key.Contains('\r')||key.Contains('\n'))throw new AiException("请先在设置中保存 API Key。");
        var endpoint=ModelEndpoint.Normalize(config.BaseUrl);
        var body=new Dictionary<string,object>{{"model",config.Model.Trim()},{"messages",messages},{"stream",stream},{"temperature",stream?0.8:0.3},{"max_tokens",stream?2048:128}};
        if(endpoint.Host=="api.deepseek.com"&&config.Model.StartsWith("deepseek-v4-",StringComparison.OrdinalIgnoreCase))body["thinking"]=new{type="disabled"};
        var request=new HttpRequestMessage(HttpMethod.Post,endpoint){Content=new StringContent(JsonSerializer.Serialize(body),Encoding.UTF8,"application/json")};
        request.Headers.Authorization=new AuthenticationHeaderValue("Bearer",key);request.Headers.Accept.Add(new(stream?"text/event-stream":"application/json"));return request;
    }
    private static void CheckStatus(HttpResponseMessage response)
    {
        if(response.IsSuccessStatusCode)return;
        int code=(int)response.StatusCode;throw new AiException(code is 401 or 403?"认证失败，请检查 API Key 和模型权限。":code==429?"请求受限，请稍后重试。":$"服务返回 HTTP {code}，请检查接口配置。");
    }
    public async Task<string> CompleteAsync(ModelConfiguration config,string key,IReadOnlyList<AiMessage> messages,CancellationToken token=default)
    {
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(token);timeout.CancelAfter(TimeSpan.FromSeconds(10));
        using var request=Request(config,key,messages,false);using var response=await http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,timeout.Token).ConfigureAwait(false);CheckStatus(response);
        await using var stream=await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);using var data=new MemoryStream();byte[] buffer=new byte[8192];int read;
        while((read=await stream.ReadAsync(buffer,timeout.Token).ConfigureAwait(false))>0){if(data.Length+read>262144)throw new AiException("响应过大，已停止接收。");data.Write(buffer,0,read);}
        using var json=JsonDocument.Parse(data.ToArray());var choice=json.RootElement.GetProperty("choices")[0];
        if(choice.TryGetProperty("finish_reason",out var finish)&&finish.GetString()=="length")throw new AiException("回复达到输出上限，请使用适合短任务的非思考模型。");
        var message=choice.GetProperty("message");if(message.GetProperty("role").GetString()!="assistant")throw new AiException("模型返回格式无效。");
        string? text=message.TryGetProperty("content",out var content)&&content.ValueKind==JsonValueKind.String?content.GetString():null;
        if(string.IsNullOrWhiteSpace(text))throw new AiException("服务没有返回正式回答，请检查模型配置。");return text;
    }
    public async Task<string> StreamAsync(ModelConfiguration config,string key,IReadOnlyList<AiMessage> messages,Func<string,Task> onText,CancellationToken token)
    {
        using var timeout=CancellationTokenSource.CreateLinkedTokenSource(token);timeout.CancelAfter(TimeSpan.FromSeconds(90));
        using var request=Request(config,key,messages,true);using var headerTimeout=CancellationTokenSource.CreateLinkedTokenSource(timeout.Token);headerTimeout.CancelAfter(TimeSpan.FromSeconds(30));
        using var response=await http.SendAsync(request,HttpCompletionOption.ResponseHeadersRead,headerTimeout.Token).ConfigureAwait(false);CheckStatus(response);
        if(response.Content.Headers.ContentType?.MediaType!="text/event-stream")throw new AiException("接口未返回流式文本，请检查兼容协议。");
        await using var stream=await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
        var decoder=new SseDecoder();var pending=new StringBuilder();byte[] bytes=new byte[4096];long last=Environment.TickCount64;
        try {
            while(!decoder.Done){using var idle=CancellationTokenSource.CreateLinkedTokenSource(timeout.Token);idle.CancelAfter(TimeSpan.FromSeconds(30));int read=await stream.ReadAsync(bytes,idle.Token).ConfigureAwait(false);if(read==0)break;
                for(int i=0;i<read&&!decoder.Done;i++)pending.Append(decoder.Feed(bytes[i]));
                if(pending.Length>0&&(Environment.TickCount64-last>=35||decoder.Done)){string chunk=pending.ToString();pending.Clear();await onText(chunk).ConfigureAwait(false);last=Environment.TickCount64;}}
        } finally {if(pending.Length>0){string chunk=pending.ToString();pending.Clear();await onText(chunk).ConfigureAwait(false);}}
        return decoder.Completion();
    }
    public void Dispose(){if(owned)http.Dispose();}
}
