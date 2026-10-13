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
    public static int Run(string executable) {
        using (var pipe = Open(executable)) {
            var input = Task.Run(delegate {
                try {
                    using (var reader = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false))) {
                        string line;
                        while ((line = reader.ReadLine()) != null) {
                            if (line.Trim().Length != 0) Send(pipe, Encoding.UTF8.GetBytes(line));
                        }
                    }
                } finally { pipe.Dispose(); }
            });
            using (var writer = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false))) {
                writer.AutoFlush = true;
                try { while (true) writer.WriteLine(Encoding.UTF8.GetString(Receive(pipe))); }
                catch (IOException) { }
                catch (ObjectDisposedException) { }
            }
            if (input.IsFaulted) throw input.Exception;
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
