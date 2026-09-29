// No console subsystem. Runs only the configured bridge under the current user.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

internal static class BridgeGuardian
{
    internal const string Version = "0.1.0";
    static readonly string Root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
    static readonly string PauseFile = Path.Combine(Root, "guardian.paused");
    static readonly string StateFile = Path.Combine(Root, "guardian-state.json");
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static readonly string UserSid = WindowsIdentity.GetCurrent().User.Value;
    static Config Settings;
    static Process Worker;
    static long WorkerStart;
    static int RestartCount;
    static DateTime HealthySince = DateTime.MinValue;

    internal sealed class Config
    {
        public int schemaVersion { get; set; }
        public string nodePath { get; set; }
        public string bridgePath { get; set; }
        public int port { get; set; }
        public string taskName { get; set; }
        public int pollSeconds { get; set; }
        public int healthTimeoutSeconds { get; set; }
        public int failureThreshold { get; set; }
        public int healthyResetSeconds { get; set; }
        public int[] restartDelaySeconds { get; set; }
    }

    [DllImport("shell32.dll", SetLastError = true)]
    static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string commandLine, out int count);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr memory);

    static string[] SplitArguments(string value)
    {
        int count;
        IntPtr argv = CommandLineToArgvW(value, out count);
        if (argv == IntPtr.Zero) return new string[0];
        try {
            string[] result = new string[count];
            for (int i = 0; i < count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
            return result;
        } finally { LocalFree(argv); }
    }

    static bool SamePath(string a, string b)
    {
        try { return String.Equals(Path.GetFullPath(a), Path.GetFullPath(b), StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }

    static void LoadConfig()
    {
        Settings = Json.Deserialize<Config>(File.ReadAllText(Path.Combine(Root, "guardian-config.json"), Encoding.UTF8));
        if (Settings == null || Settings.schemaVersion != 1 || !File.Exists(Settings.nodePath) ||
            !SamePath(Settings.bridgePath, Path.Combine(Root, "foundry-bridge.mjs")) || !File.Exists(Settings.bridgePath) ||
            Settings.port < 1024 || Settings.port > 65535 || Settings.pollSeconds < 1 || Settings.pollSeconds > 300 ||
            Settings.healthTimeoutSeconds < 1 || Settings.healthTimeoutSeconds > 10 ||
            Settings.failureThreshold < 1 || Settings.failureThreshold > 10 || Settings.healthyResetSeconds < 1 ||
            Settings.restartDelaySeconds == null || Settings.restartDelaySeconds.Length == 0)
            throw new InvalidDataException("Invalid guardian configuration.");
        foreach (int delay in Settings.restartDelaySeconds) if (delay < 1 || delay > 300) throw new InvalidDataException("Invalid backoff.");
    }

    static void Log(string message)
    {
        try {
            string file = Path.Combine(Root, "guardian.log");
            if (File.Exists(file) && new FileInfo(file).Length > 1048576) {
                if (File.Exists(file + ".1")) File.Delete(file + ".1");
                File.Move(file, file + ".1");
            }
            File.AppendAllText(file, DateTime.UtcNow.ToString("o") + " " + message + Environment.NewLine, Encoding.UTF8);
        } catch { /* A logging failure must not terminate supervision. */ }
    }

    static bool Alive(Process process)
    {
        try { process.Refresh(); return !process.HasExited; } catch { return false; }
    }

    static List<Process> FindOwnedWorkers()
    {
        var workers = new List<Process>();
        // Include the WMI key (Handle), otherwise GetOwnerSid cannot bind the projected object.
        string query = "SELECT Handle, ProcessId, ExecutablePath, CommandLine FROM Win32_Process WHERE Name='" + Path.GetFileName(Settings.nodePath).Replace("'", "''") + "'";
        using (var search = new ManagementObjectSearcher(query))
        using (var objects = search.Get()) {
            foreach (ManagementObject entry in objects) {
                try {
                    if (!SamePath(Convert.ToString(entry["ExecutablePath"]), Settings.nodePath)) continue;
                    string[] args = SplitArguments(Convert.ToString(entry["CommandLine"]));
                    if (args.Length != 2 || !SamePath(args[1], Settings.bridgePath)) continue;
                    using (ManagementBaseObject owner = entry.InvokeMethod("GetOwnerSid", null, null)) {
                        if (owner == null || Convert.ToUInt32(owner["ReturnValue"]) != 0 || Convert.ToString(owner["Sid"]) != UserSid) continue;
                    }
                    Process process = Process.GetProcessById(Convert.ToInt32(entry["ProcessId"]));
                    if (Alive(process)) workers.Add(process); else process.Dispose();
                } catch { /* Process may have exited between the query and inspection. */ }
                finally { entry.Dispose(); }
            }
        }
        return workers;
    }

    static void StopOwnedWorker(Process process, long started)
    {
        if (process == null || !Alive(process)) return;
        foreach (Process candidate in FindOwnedWorkers()) {
            using (candidate) {
                if (candidate.Id == process.Id && candidate.StartTime.ToUniversalTime().Ticks == started) {
                    candidate.Kill();
                    candidate.WaitForExit(5000);
                    Log("worker-stopped pid=" + candidate.Id);
                }
            }
        }
    }

    static void SetWorker(Process process)
    {
        if (Worker != null) Worker.Dispose();
        Worker = process;
        WorkerStart = process.StartTime.ToUniversalTime().Ticks;
        HealthySince = DateTime.MinValue;
    }

    static void State(string phase, int failures, int nextDelay)
    {
        try {
            bool alive = Worker != null && Alive(Worker);
            var value = new Dictionary<string, object> {
                {"version",Version}, {"updatedUtc",DateTime.UtcNow.ToString("o")},
                {"guardianPid",Process.GetCurrentProcess().Id}, {"phase",phase},
                {"paused",File.Exists(PauseFile)}, {"workerPid",alive ? (object)Worker.Id : null},
                {"workerStartTicks",alive ? (object)WorkerStart : null},
                {"healthFailures",failures}, {"restartCount",RestartCount}, {"nextDelaySeconds",nextDelay},
                {"port",Settings.port}, {"azureAuthentication","not-checked-by-watchdog"}
            };
            string temporary = StateFile + ".tmp";
            File.WriteAllText(temporary, Json.Serialize(value), new UTF8Encoding(false));
            if (File.Exists(StateFile)) File.Replace(temporary, StateFile, null); else File.Move(temporary, StateFile);
        } catch { /* A reader can briefly hold the state file. Retry next iteration. */ }
    }

    static bool Healthy()
    {
        try {
            var request = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + Settings.port + "/health");
            request.Proxy = null;
            request.KeepAlive = false;
            request.AllowAutoRedirect = false;
            request.Timeout = Settings.healthTimeoutSeconds * 1000;
            request.ReadWriteTimeout = request.Timeout;
            using (var response = (HttpWebResponse)request.GetResponse())
            using (var stream = response.GetResponseStream())
            using (var reader = new StreamReader(stream)) {
                if (response.StatusCode != HttpStatusCode.OK || response.ContentLength > 16384) return false;
                char[] buffer = new char[16385];
                int length = reader.ReadBlock(buffer, 0, buffer.Length);
                if (length > 16384) return false;
                var result = Json.Deserialize<Dictionary<string, object>>(new string(buffer, 0, length));
                return result != null && result.ContainsKey("service") && Convert.ToString(result["service"]) == "OpenTypeless Foundry Bridge";
            }
        } catch { return false; }
    }

    static bool Delay(int seconds)
    {
        DateTime until = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < until) {
            if (File.Exists(PauseFile)) return false;
            Thread.Sleep(250);
        }
        return !File.Exists(PauseFile);
    }

    static Process StartWorker()
    {
        if (File.Exists(PauseFile)) return null;
        var info = new ProcessStartInfo(Settings.nodePath, "\"" + Settings.bridgePath + "\"") {
            WorkingDirectory = Root, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        var process = new Process { StartInfo = info };
        // Drain pipes without persisting application output, user text, or tokens.
        process.OutputDataReceived += delegate { };
        process.ErrorDataReceived += delegate { };
        if (!process.Start()) throw new InvalidOperationException("Bridge did not start.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        Log("worker-started pid=" + process.Id);
        return process;
    }

    static int Supervise()
    {
        int failures = 0;
        int attempt = 0;
        Log("guardian-started pid=" + Process.GetCurrentProcess().Id + " version=" + Version);
        while (!File.Exists(PauseFile)) {
            if (Worker == null || !Alive(Worker)) {
                if (Worker != null) {
                    RestartCount++;
                    int delay = Settings.restartDelaySeconds[Math.Min(attempt++, Settings.restartDelaySeconds.Length - 1)];
                    State("backoff", failures, delay);
                    Log("worker-exited retryInSeconds=" + delay);
                    if (!Delay(delay)) break;
                }
                List<Process> existing = FindOwnedWorkers();
                if (existing.Count > 1) {
                    foreach (Process process in existing) process.Dispose();
                    State("conflicting-workers", failures, 0);
                    if (!Delay(Settings.pollSeconds)) break;
                    continue;
                }
                if (existing.Count == 1) {
                    SetWorker(existing[0]);
                    Log("worker-adopted pid=" + Worker.Id);
                } else {
                    Process started = StartWorker();
                    if (started == null) break;
                    SetWorker(started);
                }
                failures = 0;
                State("starting", failures, 0);
                if (!Delay(1)) break;
                if (!Alive(Worker)) continue;
            }
            if (Healthy()) {
                failures = 0;
                if (HealthySince == DateTime.MinValue) HealthySince = DateTime.UtcNow;
                if ((DateTime.UtcNow - HealthySince).TotalSeconds >= Settings.healthyResetSeconds) attempt = 0;
                State("healthy", failures, 0);
            } else {
                HealthySince = DateTime.MinValue;
                failures++;
                State("health-failed", failures, 0);
                if (failures >= Settings.failureThreshold) {
                    Log("local-health-failed restarting-owned-worker");
                    StopOwnedWorker(Worker, WorkerStart);
                    if (Alive(Worker)) {
                        State("ownership-check-failed", failures, 0);
                        if (!Delay(Settings.pollSeconds)) break;
                    }
                    continue;
                }
            }
            if (!Delay(Settings.pollSeconds)) break;
        }
        StopOwnedWorker(Worker, WorkerStart);
        State("paused", 0, 0);
        Log("guardian-paused");
        return 0;
    }

    [STAThread]
    static int Main(string[] args)
    {
        try {
            LoadConfig();
            if (args.Length != 1 || (args[0] != "--run" && args[0] != "--stop")) return 2;
            if (args[0] == "--stop") {
                File.WriteAllText(PauseFile, DateTime.UtcNow.ToString("o"), Encoding.UTF8);
                foreach (Process process in FindOwnedWorkers()) {
                    using (process) StopOwnedWorker(process, process.StartTime.ToUniversalTime().Ticks);
                }
                return 0;
            }
            if (File.Exists(PauseFile)) return 0;
            FileStream exclusive;
            try { exclusive = new FileStream(Path.Combine(Root, "guardian.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException) { return 0; }
            using (exclusive) { return Supervise(); }
        } catch (Exception error) {
            Log("guardian-failed type=" + error.GetType().Name);
            return 1;
        }
    }
}
