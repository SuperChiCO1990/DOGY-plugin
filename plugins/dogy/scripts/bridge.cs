using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

// Only transport plumbing: the closed DOGY executable implements all tools.
public static class DogyBridge {
    const int MaxMessage = 16 * 1024 * 1024;
    static byte[] Receive(System.IO.Pipes.NamedPipeClientStream pipe) {
        using (var message = new MemoryStream()) {
            var buffer = new byte[4096];
            do {
                int count = pipe.Read(buffer, 0, buffer.Length);
                if (count == 0) throw new EndOfStreamException();
                message.Write(buffer, 0, count);
                if (message.Length > MaxMessage) throw new IOException("MCP message too large");
            } while (!pipe.IsMessageComplete);
            return message.ToArray();
        }
    }
    static void Send(System.IO.Pipes.NamedPipeClientStream pipe, byte[] data) {
        if (data.Length > MaxMessage) throw new IOException("MCP message too large");
        pipe.Write(data, 0, data.Length);
        pipe.Flush();
    }
    static System.IO.Pipes.NamedPipeClientStream Connect(string endpoint) {
        System.IO.Pipes.NamedPipeClientStream pipe = null;
        try {
            var lines = File.ReadAllLines(endpoint);
            if (lines.Length != 3) return null;
            pipe = new System.IO.Pipes.NamedPipeClientStream(".", lines[0],
                System.IO.Pipes.PipeDirection.InOut, System.IO.Pipes.PipeOptions.Asynchronous);
            pipe.Connect(300);
            pipe.ReadMode = System.IO.Pipes.PipeTransmissionMode.Message;
            Send(pipe, Encoding.ASCII.GetBytes(lines[1]));
            var ready = Task.Run(() => Receive(pipe));
            if (!ready.Wait(3000) || Encoding.ASCII.GetString(ready.Result) != "OK")
                throw new IOException("DOGY backend authentication failed");
            return pipe;
        } catch (Exception) {
            if (pipe != null) pipe.Dispose();
            return null;
        }
    }
    static System.IO.Pipes.NamedPipeClientStream Open(string executable) {
        string identity = System.Security.Principal.WindowsIdentity.GetCurrent().User.Value;
        string key;
        using (var hash = System.Security.Cryptography.SHA256.Create()) {
            var source = identity + "|" + Path.GetFullPath(executable).ToLowerInvariant()
                + "|" + (Environment.GetEnvironmentVariable("DOGY_LIBRARY_ROOT") ?? "");
            key = BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(source))).Replace("-", "");
        }
        string directory = Path.Combine(Environment.GetEnvironmentVariable("LOCALAPPDATA") ??
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "MediaDownloader", "Agent", "Backends");
        Directory.CreateDirectory(directory);
        string endpoint = Path.Combine(directory, key + ".endpoint");
        using (var mutex = new System.Threading.Mutex(false, "Local\\DOGY-MCP-" + key)) {
            bool acquired = false;
            try {
                try { acquired = mutex.WaitOne(60000); }
                catch (System.Threading.AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new IOException("DOGY backend startup timed out");
                var existing = Connect(endpoint);
                if (existing != null) return existing;
                var info = new ProcessStartInfo(executable, "--mcp-shared-backend \"" + endpoint + "\"") {
                    UseShellExecute = false, CreateNoWindow = true
                };
                info.EnvironmentVariables["PYINSTALLER_RESET_ENVIRONMENT"] = "1";
                using (var child = Process.Start(info)) {
                    var deadline = DateTime.UtcNow.AddSeconds(60);
                    while (DateTime.UtcNow < deadline) {
                        var connected = Connect(endpoint);
                        if (connected != null) return connected;
                        if (child.HasExited) throw new IOException("DOGY backend failed; update DOGY and retry");
                        System.Threading.Thread.Sleep(100);
                    }
                }
                throw new IOException("DOGY backend startup timed out");
            } finally { if (acquired) mutex.ReleaseMutex(); }
        }
    }
    static int Relay(System.IO.Pipes.NamedPipeClientStream pipe, StreamReader reader,
                     StreamWriter writer, string first) {
        Send(pipe, Encoding.UTF8.GetBytes(first));
        var input = Task.Run(delegate {
            try {
                string line;
                while ((line = reader.ReadLine()) != null) {
                    if (line.Trim().Length != 0) Send(pipe, Encoding.UTF8.GetBytes(line));
                }
            } finally { pipe.Dispose(); }
        });
        try { while (true) writer.WriteLine(Encoding.UTF8.GetString(Receive(pipe))); }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
        if (input.IsFaulted) throw input.Exception;
        return 0;
    }
    public static int Run(string executable) {
        using (var reader = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false)))
        using (var writer = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false))) {
            writer.AutoFlush = true;
            string first = reader.ReadLine();
            if (first == null) return 0;
            using (var pipe = Open(executable)) return Relay(pipe, reader, writer, first);
        }
    }
    public static int RunLazy(Func<string> resolve, string catalogPath) {
        var json = new System.Web.Script.Serialization.JavaScriptSerializer { MaxJsonLength = MaxMessage };
        var catalog = json.Deserialize<System.Collections.Generic.Dictionary<string, object>>(File.ReadAllText(catalogPath));
        using (var reader = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false)))
        using (var writer = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false))) {
            writer.AutoFlush = true;
            string line;
            while ((line = reader.ReadLine()) != null) {
                if (line.Trim().Length == 0) continue;
                System.Collections.Generic.Dictionary<string, object> message;
                object id = null, methodValue;
                try { message = json.Deserialize<System.Collections.Generic.Dictionary<string, object>>(line); }
                catch (ArgumentException) {
                    writer.WriteLine(json.Serialize(new { jsonrpc = "2.0", id = id,
                        error = new { code = -32700, message = "Parse error" } }));
                    continue;
                }
                if (message == null || !message.TryGetValue("method", out methodValue) || !(methodValue is string)) {
                    if (message != null) message.TryGetValue("id", out id);
                    writer.WriteLine(json.Serialize(new { jsonrpc = "2.0", id = id,
                        error = new { code = -32600, message = "Invalid Request" } }));
                    continue;
                }
                if (!message.TryGetValue("id", out id)) continue;
                string method = (string)methodValue;
                if (method == "tools/call") {
                    using (var pipe = Open(resolve())) return Relay(pipe, reader, writer, line);
                }
                object result;
                if (method == "initialize") {
                    var initial = new System.Collections.Generic.Dictionary<string, object>(
                        (System.Collections.Generic.Dictionary<string, object>)catalog[method]);
                    object parameters, protocol;
                    if (message.TryGetValue("params", out parameters) &&
                        parameters is System.Collections.Generic.Dictionary<string, object> &&
                        ((System.Collections.Generic.Dictionary<string, object>)parameters).TryGetValue("protocolVersion", out protocol) &&
                        protocol is string && ((string)protocol).Length != 0) initial["protocolVersion"] = protocol;
                    result = initial;
                } else if (method == "ping") result = new object();
                else if (method == "tools/list") result = catalog[method];
                else {
                    writer.WriteLine(json.Serialize(new { jsonrpc = "2.0", id = id,
                        error = new { code = -32601, message = "Method not found: " + method } }));
                    continue;
                }
                writer.WriteLine(json.Serialize(new { jsonrpc = "2.0", id = id, result = result }));
            }
            return 0;
        }
    }
    public static string Doctor(string executable) {
        var info = new ProcessStartInfo(executable, "doctor") {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false)
        };
        using (var child = Process.Start(info)) {
            child.StandardInput.Close();
            var output = child.StandardOutput.ReadToEndAsync();
            var error = child.StandardError.ReadToEndAsync();
            if (!child.WaitForExit(60000)) {
                child.Kill();
                throw new Exception("DOGY doctor timed out");
            }
            Task.WaitAll(output, error);
            if (child.ExitCode != 0) throw new Exception("DOGY doctor failed: " + error.Result);
            return output.Result;
        }
    }
}
