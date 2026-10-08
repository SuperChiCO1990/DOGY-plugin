using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;

// Only transport plumbing: the closed DOGY executable implements all tools.
public static class DogyBridge {
    static async Task Pump(Stream source, Stream destination) {
        byte[] buffer = new byte[4096];
        int count;
        while ((count = await source.ReadAsync(buffer, 0, buffer.Length)) != 0) {
            await destination.WriteAsync(buffer, 0, count);
            await destination.FlushAsync();
        }
    }
    public static int Run(string executable) {
        var info = new ProcessStartInfo(executable, "mcp") {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        using (var child = Process.Start(info)) {
            var output = Pump(child.StandardOutput.BaseStream, Console.OpenStandardOutput());
            var error = Pump(child.StandardError.BaseStream, Console.OpenStandardError());
            // Closing the client's input closes DOGY's input; do not wait for input
            // if the child itself fails before the client closes the connection.
            Task.Run(async delegate {
                try { await Pump(Console.OpenStandardInput(), child.StandardInput.BaseStream); }
                catch (IOException) { }
                catch (ObjectDisposedException) { }
                finally {
                    try { child.StandardInput.Close(); }
                    catch (IOException) { }
                    catch (ObjectDisposedException) { }
                }
            });
            child.WaitForExit();
            Task.WaitAll(output, error);
            return child.ExitCode;
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
