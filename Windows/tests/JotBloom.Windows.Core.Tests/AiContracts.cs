using System.Net;
using System.Text;
using System.Text.Json;
using JotBloom.Windows.Core;

internal static class AiContracts
{
    internal static async Task<int> Run()
    {
        int count=0;
        async Task Check(string name,Func<Task> test){await test();count++;Console.WriteLine("PASS "+name);}
        void Require(bool value){if(!value)throw new Exception("AI/settings contract failed");}
        async Task Throws(Func<Task> action){try{await action();}catch(Exception e)when(e is AiException or JsonException or DecoderFallbackException or IOException or OperationCanceledException){return;}throw new Exception("Expected rejection");}
        string Delta(string text)=>"data: "+JsonSerializer.Serialize(new{choices=new[]{new{index=0,delta=new{role="assistant",content=text},finish_reason=(string?)null}}})+"\n\n";
        const string finish="data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n";
        ModelConfiguration config=new("https://example.com/v1","model");
        HttpClient Client(Func<HttpRequestMessage,HttpResponseMessage> reply)=>new(new Handler(reply)){Timeout=Timeout.InfiniteTimeSpan};
        HttpResponseMessage SSE(Stream body){var response=new HttpResponseMessage(HttpStatusCode.OK){Content=new StreamContent(body)};response.Content.Headers.ContentType=new("text/event-stream");return response;}
        await Check("HTTPS endpoint normalization and local HTTP",()=>{Require(ModelEndpoint.Normalize(" https://example.com/v1/chat/completions/ ").AbsoluteUri=="https://example.com/v1/chat/completions");Require(ModelEndpoint.Normalize("http://127.0.0.1:11434/v1").IsLoopback);return Task.CompletedTask;});
        await Check("remote HTTP credentials query fragments rejected",async()=>{foreach(string value in new[]{"http://example.com","https://user:pass@example.com","https://example.com?q=key","https://example.com/#token"})await Throws(()=>Task.Run(()=>ModelEndpoint.Normalize(value)));});
        await Check("SSE handles fragmented Chinese emoji and CRLF",()=>{var decoder=new SseDecoder();var text=new StringBuilder();foreach(byte value in Encoding.UTF8.GetBytes((": heartbeat\n\n"+Delta("你好👩🏽‍💻")+finish).Replace("\n","\r\n")))text.Append(decoder.Feed(value));Require(text.ToString()=="你好👩🏽‍💻"&&decoder.Completion()=="complete");return Task.CompletedTask;});
        await Check("SSE missing terminal marker never claims completion",async()=>{var decoder=new SseDecoder();foreach(byte value in Encoding.UTF8.GetBytes(Delta("partial")))decoder.Feed(value);await Throws(()=>Task.Run(()=>decoder.Completion()));});
        await Check("SSE missing finish reason or empty answer rejected",async()=>{foreach(string text in new[]{Delta("text")+"data: [DONE]\n\n",finish}){var decoder=new SseDecoder();foreach(byte value in Encoding.UTF8.GetBytes(text))decoder.Feed(value);await Throws(()=>Task.Run(()=>decoder.Completion()));}});
        await Check("SSE frame bounds and invalid UTF8 rejected",async()=>{await Throws(()=>Task.Run(()=>{var decoder=new SseDecoder();for(int i=0;i<65538;i++)decoder.Feed(65);}));await Throws(()=>Task.Run(()=>{var decoder=new SseDecoder();decoder.Feed(255);decoder.Feed(10);}));});
        await Check("SSE tools are not interpreted as a text answer",async()=>{await Throws(()=>Task.Run(()=>{var decoder=new SseDecoder();foreach(byte value in Encoding.UTF8.GetBytes("data: {\"choices\":[{\"delta\":{\"tool_calls\":[]}}]}\n\n"))decoder.Feed(value);}));});
        await Check("streamed network failure preserves already decoded text",async()=>{using var http=Client(_=>SSE(new BrokenStream(Encoding.UTF8.GetBytes(Delta("保留收到的内容")))));using var ai=new AiClient(http);string result="";await Throws(()=>ai.StreamAsync(config,"fake-test-key",[new("user","hi")],delta=>{result+=delta;return Task.CompletedTask;},CancellationToken.None));Require(result=="保留收到的内容");});
        await Check("stream returns complete only after proper termination",async()=>{using var http=Client(_=>SSE(new MemoryStream(Encoding.UTF8.GetBytes(Delta("hello")+finish))));using var ai=new AiClient(http);string answer="";string state=await ai.StreamAsync(config,"fake-test-key",[new("user","hi")],text=>{answer+=text;return Task.CompletedTask;},CancellationToken.None);Require(answer=="hello"&&state=="complete");});
        await Check("HTTP authentication failures expose no response body",async()=>{using var http=Client(_=>new(HttpStatusCode.Unauthorized){Content=new StringContent("SENSITIVE_RAW_RESPONSE")});using var ai=new AiClient(http);try{await ai.CompleteAsync(config,"fake-test-key",[new("user","hi")]);throw new Exception("Expected auth failure");}catch(AiException e){Require(!e.Message.Contains("SENSITIVE")&&e.Message.Contains("认证"));}});
        await Check("redirect responses are rejected without reposting credentials",async()=>{int calls=0;using var http=Client(_=>{calls++;var reply=new HttpResponseMessage(HttpStatusCode.TemporaryRedirect);reply.Headers.Location=new("https://other.example");return reply;});using var ai=new AiClient(http);await Throws(()=>ai.CompleteAsync(config,"fake-test-key",[new("user","hi")]));Require(calls==1);});
        await Check("short request serializes text and bounds response",async()=>{string? body=null;using var http=Client(request=>{body=request.Content!.ReadAsStringAsync().GetAwaiter().GetResult();return new(HttpStatusCode.OK){Content=new StringContent("{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"role\":\"assistant\",\"content\":\"OK\"}}]}")};});using var ai=new AiClient(http);Require(await ai.CompleteAsync(config,"fake-test-key",[new("user","hello")])=="OK");using var json=JsonDocument.Parse(body!);Require(!json.RootElement.GetProperty("stream").GetBoolean()&&json.RootElement.GetProperty("max_tokens").GetInt32()==128);});
        await Check("oversized and reasoning-only short responses rejected",async()=>{foreach(string body in new[]{new string('x',262145),"{\"choices\":[{\"message\":{\"role\":\"assistant\",\"reasoning_content\":\"hidden\",\"content\":\"\"}}]}"}){using var http=Client(_=>new(HttpStatusCode.OK){Content=new StringContent(body)});using var ai=new AiClient(http);await Throws(()=>ai.CompleteAsync(config,"fake-test-key",[new("user","hello")]));}});
        await Check("context trims complete old pairs and retains newest three",()=>{var turns=Enumerable.Range(0,10).Select(i=>(User:"user"+i+new string('文',700),Answer:new string('答',600)));var context=AiClient.Context(turns,"new","system");Require(context.Count<22&&context[^1].Content=="new"&&context.Count>=8&&context[1].Role=="user");return Task.CompletedTask;});
        await Check("oversized recent context refused before network submission",async()=>await Throws(()=>Task.Run(()=>AiClient.Context([],new string('文',9000),"system"))));
        await Check("settings roundtrip has no credentials and corrupt file is preserved",async()=>{string path=Path.Combine(Path.GetTempPath(),"jotbloom-settings-"+Guid.NewGuid()+".json");try{var settings=new SettingsFile(path);settings.Save(new(){DefaultPage="chat",Main=new("https://example.com","model")});Require(settings.Load().DefaultPage=="chat"&&!File.ReadAllText(path).Contains("fake-test-key"));File.WriteAllText(path,"broken");await Throws(()=>Task.Run(()=>settings.Load()));Require(File.ReadAllText(path)=="broken");}finally{File.Delete(path);}});
        await Check("hotkey requires modifier and protects editing shortcuts",()=>{Require(new Hotkey().IsValid&&!new Hotkey(0x20,4).IsValid&&!new Hotkey(0x43,2).IsValid&&new Hotkey(0x4B,3).IsValid);return Task.CompletedTask;});
        await Check("auxiliary model key routing respects sharing and blank fallback",()=>{var settings=new ProductSettings{Main=new("https://main.example","main"),Auxiliary=new("https://aux.example","aux")};Require(settings.Resolve(true).KeySlot=="main"&&settings.Resolve(true).Configuration.BaseUrl=="https://main.example");Require((settings with{AuxiliaryUsesMain=false}).Resolve(true).KeySlot=="auxiliary");Require((settings with{Auxiliary=new()}).Resolve(true).Configuration.Model=="main");return Task.CompletedTask;});
        return count;
    }
    private sealed class Handler(Func<HttpRequestMessage,HttpResponseMessage> reply):HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellationToken){cancellationToken.ThrowIfCancellationRequested();return Task.FromResult(reply(request));}
    }
    private sealed class BrokenStream(byte[] bytes):MemoryStream(bytes)
    {
        public override ValueTask<int> ReadAsync(Memory<byte> buffer,CancellationToken cancellationToken=default)=>Position==Length?ValueTask.FromException<int>(new IOException("injected disconnect")):base.ReadAsync(buffer,cancellationToken);
    }
}
