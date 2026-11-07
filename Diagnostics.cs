using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace KakaoAdDiagnostics
{
    internal static class Util
    {
        internal static Dictionary<string, object> Map(params object[] pairs)
        {
            Dictionary<string, object> map = new Dictionary<string, object>(StringComparer.Ordinal);
            for (int i = 0; i + 1 < pairs.Length; i += 2) map[(string)pairs[i]] = pairs[i + 1];
            return map;
        }
    }

    // Append-only JSONL journal. Serialization, rotation and append happen under one lock.
    // Failures are counted (LogWriteFailures / DroppedRecords) and never thrown to callers.
    public sealed class Journal
    {
        public const int MaxRecordBytes = 16384;
        private const int KeepPrior = 3;
        internal static readonly Regex SafeName = new Regex("^[a-z][a-z0-9_]{0,47}$", RegexOptions.CultureInvariant);

        private readonly object _gate = new object();
        private readonly string _directory;
        private readonly int _maxBytes;
        private readonly Stopwatch _clock = Stopwatch.StartNew();
        private readonly JavaScriptSerializer _serializer = new JavaScriptSerializer();
        private readonly UTF8Encoding _utf8 = new UTF8Encoding(false);
        private readonly string _runId = Guid.NewGuid().ToString("N");
        private long _sequence;
        private int _logWriteFailures;
        private int _droppedRecords;
        private string _lastEventUtc = string.Empty;

        public Journal(string directory, int maxBytes = 1048576)
        {
            if (string.IsNullOrEmpty(directory)) throw new ArgumentNullException("directory");
            if (maxBytes < 4096) throw new ArgumentOutOfRangeException("maxBytes");
            _directory = directory;
            _maxBytes = maxBytes;
            _serializer.RecursionLimit = 16;
            _serializer.MaxJsonLength = MaxRecordBytes * 2;
        }

        public string RunId { get { return _runId; } }
        public string CurrentPath { get { return Path.Combine(_directory, "events.jsonl"); } }
        public long ElapsedMs { get { return _clock.ElapsedMilliseconds; } }
        public int LogWriteFailures { get { lock (_gate) { return _logWriteFailures; } } }
        public int DroppedRecords { get { lock (_gate) { return _droppedRecords; } } }
        public string LastEventUtc { get { lock (_gate) { return _lastEventUtc; } } }

        // Returns true only when the original record was written unchanged.
        public bool Write(string eventName, object data)
        {
            return Write(eventName, data, "diagnostics");
        }

        internal bool Write(string eventName, object data, string origin)
        {
            lock (_gate)
            {
                long seq = ++_sequence;
                string ts = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
                long mono = _clock.ElapsedMilliseconds;
                string dropReason = null;
                byte[] bytes = null;
                if (eventName == null || !SafeName.IsMatch(eventName))
                {
                    dropReason = "invalid_event_name";
                }
                else
                {
                    try { bytes = Encode(seq, ts, mono, origin, eventName, data); }
                    catch (InvalidOperationException) { dropReason = "unserializable"; }
                    catch (ArgumentException) { dropReason = "unserializable"; }
                    if (dropReason == null && bytes.Length > MaxRecordBytes) dropReason = "oversized";
                }
                if (dropReason != null)
                {
                    _droppedRecords++;
                    Dictionary<string, object> d = Util.Map("reason", dropReason);
                    if (dropReason != "invalid_event_name") d["originalEvent"] = eventName;
                    bytes = Encode(seq, ts, mono, origin, "record_dropped", d);
                }
                if (!Append(bytes))
                {
                    _logWriteFailures++;
                    return false;
                }
                _lastEventUtc = ts;
                return dropReason == null;
            }
        }

        private byte[] Encode(long seq, string ts, long mono, string origin, string eventName, object data)
        {
            Dictionary<string, object> rec = Util.Map(
                "schema", 1, "seq", seq, "timestampUtc", ts, "monotonicMs", mono,
                "runId", _runId, "origin", origin, "event", eventName, "data", data);
            return _utf8.GetBytes(_serializer.Serialize(rec) + "\n");
        }

        private bool Append(byte[] bytes)
        {
            try
            {
                Directory.CreateDirectory(_directory);
                string path = CurrentPath;
                FileInfo info = new FileInfo(path);
                if (info.Exists && info.Length + bytes.Length > _maxBytes) Rotate(path);
                using (FileStream fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read))
                {
                    fs.Write(bytes, 0, bytes.Length);
                }
                return true;
            }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
            catch (SecurityException) { return false; }
            catch (NotSupportedException) { return false; }
        }

        // events.jsonl -> events.1.jsonl -> events.2.jsonl -> events.3.jsonl (oldest deleted).
        private void Rotate(string path)
        {
            for (int i = KeepPrior; i >= 1; i--)
            {
                string dst = Prior(i);
                string src = i == 1 ? path : Prior(i - 1);
                if (i == KeepPrior && File.Exists(dst)) File.Delete(dst);
                if (File.Exists(src)) File.Move(src, dst);
            }
        }

        private string Prior(int n)
        {
            return Path.Combine(_directory, "events." + n.ToString(CultureInfo.InvariantCulture) + ".jsonl");
        }
    }

    // Structural observation of one root window. Intentionally has no title or path fields.
    public sealed class Snapshot
    {
        public long Handle;
        public int Pid;
        public long StartedTicks;
        public string Version;
        public string Kind;
        public bool Visible;
        public bool StrongEvidence;
        public int Width;
        public int Height;
        public int WebChildren;
    }

    // Deterministic state machine over snapshots; callers supply monotonic milliseconds.
    // Events record what was observed and when. They never assert creation time, who changed
    // visibility, or that a restart caused a later observation (temporal order only).
    public sealed class Tracker
    {
        public const int MaxTracked = 256;
        public const long PersistMs = 1000;
        public const long CooldownMs = 60000;
        public const long RateWindowMs = 600000;
        public const int MaxRequestsPerRateWindow = 3;
        public const int MaxAttemptsPerInstance = 3;
        public const long PendingTimeoutMs = 120000;
        public const long ObservationDelayMs = 2000;

        private static readonly Regex VersionShape = new Regex(@"^\d{1,6}(\.\d{1,6}){0,3}$", RegexOptions.CultureInvariant);
        internal static readonly Regex RequestShape = new Regex("^r[0-9a-f]{8}-[0-9]{1,9}$", RegexOptions.CultureInvariant);
        private static readonly string[] ObserveReasons = { "enum", "create", "show", "hide", "structure", "refresh" };
        private static readonly string[] RemoveReasons = { "destroy", "missing", "not_candidate", "process_exit", "identity_replaced", "monitor_stopped", "evicted" };

        private sealed class Entry
        {
            public string WindowId; public long Handle; public int Pid; public long StartedTicks;
            public string Version; public string Kind; public bool Visible; public bool Strong; public bool WasHidden;
            public int Width; public int Height; public int WebChildren;
            public long StrongVisibleSinceMs; public long LastSeenMs; public int Attempts;
            public string AwaitRequestId; public long AwaitSinceMs;
            public bool ExhaustionLogged;
        }

        private sealed class Pending
        {
            public string RequestId; public string WindowId; public long Handle; public long RequestedMs;
        }

        internal struct Identity
        {
            public long Handle; public int Pid; public long StartedTicks;
        }

        private readonly object _gate = new object();
        private readonly Journal _journal;
        private readonly Dictionary<long, Entry> _entries = new Dictionary<long, Entry>();
        private readonly Queue<long> _requestTimes = new Queue<long>();
        private long _nextWindowId;
        private long _nextRequestId;
        private bool _hasLastRequest;
        private long _lastRequestMs;
        private Pending _pending;
        private int _rejected;

        public Tracker(Journal journal)
        {
            if (journal == null) throw new ArgumentNullException("journal");
            _journal = journal;
        }

        public int TrackedCount { get { lock (_gate) { return _entries.Count; } } }
        public int RejectedSnapshots { get { lock (_gate) { return _rejected; } } }
        public string PendingRequestId { get { lock (_gate) { return _pending == null ? null : _pending.RequestId; } } }

        public void Observe(Snapshot snapshot, string reason, long nowMs)
        {
            lock (_gate)
            {
                string rejection = Validate(snapshot, reason);
                if (rejection != null)
                {
                    _rejected++;
                    if (_rejected <= 16) _journal.Write("snapshot_rejected", Util.Map("reason", rejection, "count", _rejected));
                    return;
                }
                Entry e;
                if (_entries.TryGetValue(snapshot.Handle, out e) && (e.Pid != snapshot.Pid || e.StartedTicks != snapshot.StartedTicks))
                {
                    // Handle reused by another process instance: old evidence is discarded.
                    Drop(e, "identity_replaced", nowMs);
                    e = null;
                }
                if (e == null) Add(snapshot, reason, nowMs);
                else Update(e, snapshot, reason, nowMs);
            }
        }

        public bool Remove(long handle, int pid, long startedTicks, string reason, long nowMs)
        {
            lock (_gate)
            {
                Entry e;
                if (!_entries.TryGetValue(handle, out e)) return false;
                string safeReason = Array.IndexOf(RemoveReasons, reason) >= 0 ? reason : "other";
                if (e.Pid != pid || e.StartedTicks != startedTicks)
                {
                    _journal.Write("stale_remove_ignored", Util.Map("windowId", e.WindowId, "reason", safeReason));
                    return false;
                }
                Drop(e, safeReason, nowMs);
                return true;
            }
        }

        public string TryRequestRepair(long nowMs)
        {
            lock (_gate)
            {
                if (_pending != null)
                {
                    if (nowMs - _pending.RequestedMs < PendingTimeoutMs) return null;
                    _journal.Write("repair_request_expired", Util.Map("requestId", _pending.RequestId, "windowId", _pending.WindowId));
                    _pending = null;
                }
                while (_requestTimes.Count > 0 && nowMs - _requestTimes.Peek() >= RateWindowMs) _requestTimes.Dequeue();
                if (_requestTimes.Count >= MaxRequestsPerRateWindow) return null;
                if (_hasLastRequest && nowMs - _lastRequestMs < CooldownMs) return null;

                Entry best = null;
                foreach (Entry e in _entries.Values)
                {
                    // Only strict popup roots with exact marker evidence, visible long enough, qualify.
                    if (e.Kind != "popup" || !e.Visible || !e.Strong || e.StrongVisibleSinceMs < 0) continue;
                    if (nowMs - e.StrongVisibleSinceMs < PersistMs) continue;
                    if (e.Attempts >= MaxAttemptsPerInstance) {
                        if (!e.ExhaustionLogged) { e.ExhaustionLogged=true; _journal.Write("repair_exhausted", Util.Map("windowId",e.WindowId,"attempts",e.Attempts)); }
                        continue;
                    }
                    if (e.AwaitRequestId != null) continue;
                    if (best == null || e.StrongVisibleSinceMs < best.StrongVisibleSinceMs) best = e;
                }
                if (best == null) return null;

                _nextRequestId++;
                Pending p = new Pending();
                p.RequestId = "r" + _journal.RunId.Substring(0, 8) + "-" + _nextRequestId.ToString(CultureInfo.InvariantCulture);
                p.WindowId = best.WindowId;
                p.Handle = best.Handle;
                p.RequestedMs = nowMs;
                _pending = p;
                best.Attempts++;
                _requestTimes.Enqueue(nowMs);
                _hasLastRequest = true;
                _lastRequestMs = nowMs;
                _journal.Write("repair_requested", Util.Map(
                    "requestId", p.RequestId, "windowId", best.WindowId, "attempt", best.Attempts,
                    "visibleForMs", nowMs - best.StrongVisibleSinceMs, "basis", "strong_popup_visible"));
                return p.RequestId;
            }
        }

        public void CompleteRepair(string requestId, bool restarted, long nowMs)
        {
            lock (_gate)
            {
                if (requestId == null || _pending == null || !string.Equals(requestId, _pending.RequestId, StringComparison.Ordinal))
                {
                    bool shaped = requestId != null && RequestShape.IsMatch(requestId);
                    _journal.Write("repair_result_unmatched", Util.Map("requestId", shaped ? requestId : null, "restarted", restarted));
                    return;
                }
                Pending p = _pending;
                _pending = null;
                _journal.Write("repair_restart_result", Util.Map(
                    "requestId", p.RequestId, "windowId", p.WindowId, "restarted", restarted, "elapsedMs", nowMs - p.RequestedMs));
                Entry e;
                if (_entries.TryGetValue(p.Handle, out e) && e.WindowId == p.WindowId)
                {
                    e.AwaitRequestId = p.RequestId;
                    e.AwaitSinceMs = nowMs;
                }
            }
        }

        internal bool Contains(long handle)
        {
            lock (_gate) { return _entries.ContainsKey(handle); }
        }

        internal bool TryGetIdentity(long handle, out int pid, out long startedTicks)
        {
            lock (_gate)
            {
                Entry e;
                pid = 0;
                startedTicks = 0;
                if (!_entries.TryGetValue(handle, out e)) return false;
                pid = e.Pid;
                startedTicks = e.StartedTicks;
                return true;
            }
        }

        internal List<Identity> GetTrackedIdentities()
        {
            lock (_gate)
            {
                List<Identity> list = new List<Identity>(_entries.Count);
                foreach (Entry e in _entries.Values)
                {
                    Identity id = new Identity();
                    id.Handle = e.Handle; id.Pid = e.Pid; id.StartedTicks = e.StartedTicks;
                    list.Add(id);
                }
                return list;
            }
        }

        private static string Validate(Snapshot s, string reason)
        {
            if (s == null) return "null_snapshot";
            if (Array.IndexOf(ObserveReasons, reason) < 0) return "invalid_reason";
            if (s.Handle == 0 || s.Pid <= 0 || s.StartedTicks <= 0) return "invalid_identity";
            if (s.Version == null || !VersionShape.IsMatch(s.Version)) return "invalid_version";
            if (s.Kind != "popup" && s.Kind != "banner") return "invalid_kind";
            if (s.Width < 0 || s.Height < 0 || s.Width > 20000 || s.Height > 20000) return "invalid_shape";
            if (s.WebChildren < 0 || s.WebChildren > 256) return "invalid_shape";
            if (s.StrongEvidence && s.Kind != "popup") return "invalid_evidence";
            return null;
        }

        private static string Source(string reason)
        {
            if (reason == "enum" || reason == "refresh") return reason;
            return "event";
        }

        private static void Apply(Entry e, Snapshot s)
        {
            e.Version = s.Version; e.Kind = s.Kind; e.Visible = s.Visible; e.Strong = s.StrongEvidence;
            e.Width = s.Width; e.Height = s.Height; e.WebChildren = s.WebChildren;
        }

        private static Dictionary<string, object> Describe(Entry e, string reason)
        {
            return Util.Map(
                "windowId", e.WindowId, "pid", e.Pid, "version", e.Version, "kind", e.Kind,
                "visible", e.Visible, "strongEvidence", e.Strong, "width", e.Width, "height", e.Height,
                "webChildren", e.WebChildren, "source", Source(reason), "notification", reason);
        }

        private void Add(Snapshot s, string reason, long nowMs)
        {
            if (_entries.Count >= MaxTracked) EvictOldest(nowMs);
            Entry e = new Entry();
            e.WindowId = "w" + (++_nextWindowId).ToString(CultureInfo.InvariantCulture);
            e.Handle = s.Handle; e.Pid = s.Pid; e.StartedTicks = s.StartedTicks;
            Apply(e, s);
            // Visible-since starts at first observation; earlier visibility is unknown.
            e.StrongVisibleSinceMs = (s.Visible && s.StrongEvidence) ? nowMs : -1;
            e.LastSeenMs = nowMs;
            _entries[s.Handle] = e;
            _journal.Write("window_first_observed", Describe(e, reason));
        }

        private void Update(Entry e, Snapshot s, string reason, long nowMs)
        {
            bool wasVisible = e.Visible;
            bool changed = e.Strong != s.StrongEvidence || e.Kind != s.Kind || e.Version != s.Version
                || e.Width != s.Width || e.Height != s.Height || e.WebChildren != s.WebChildren;
            Dictionary<string, object> prev = null;
            if (changed)
            {
                prev = Util.Map("previousKind", e.Kind, "previousStrongEvidence", e.Strong, "previousWidth", e.Width,
                    "previousHeight", e.Height, "previousWebChildren", e.WebChildren, "previousVersion", e.Version);
            }
            Apply(e, s);
            if (changed)
            {
                Dictionary<string, object> d = Describe(e, reason);
                foreach (KeyValuePair<string, object> kv in prev) d[kv.Key] = kv.Value;
                _journal.Write("window_structure_changed", d);
            }
            Dictionary<string, object> v = Util.Map("windowId", e.WindowId, "notification", reason, "source", Source(reason));
            if (wasVisible && !e.Visible)
            {
                e.WasHidden = true;
                _journal.Write("window_hidden_observed", v);
            }
            else if (!wasVisible && e.Visible)
            {
                _journal.Write(e.WasHidden ? "window_reappeared" : "window_shown_observed", v);
            }
            else if (reason == "create" || reason == "show" || reason == "hide")
            {
                v["visible"] = e.Visible;
                _journal.Write("window_notification", v);
            }
            if (e.Visible && e.Strong)
            {
                if (e.StrongVisibleSinceMs < 0) e.StrongVisibleSinceMs = nowMs;
            }
            else
            {
                e.StrongVisibleSinceMs = -1;
            }
            e.LastSeenMs = nowMs;
            CheckAwait(e, nowMs);
        }

        private void CheckAwait(Entry e, long nowMs)
        {
            if (e.AwaitRequestId == null) return;
            if (!e.Visible) Observation(e, "hidden", nowMs);
            else if (nowMs - e.AwaitSinceMs >= ObservationDelayMs) Observation(e, "visible", nowMs);
        }

        private void Observation(Entry e, string state, long nowMs)
        {
            _journal.Write("repair_observation", Util.Map(
                "requestId", e.AwaitRequestId, "windowId", e.WindowId, "state", state,
                "msAfterRestartResult", nowMs - e.AwaitSinceMs, "relation", "temporal_order_only"));
            e.AwaitRequestId = null;
        }

        private void Drop(Entry e, string reason, long nowMs)
        {
            _entries.Remove(e.Handle);
            string state = "unobserved";
            if (reason == "destroy" || reason == "missing" || reason == "process_exit" || reason == "identity_replaced") state = "destroyed";
            else if (reason == "not_candidate") state = "no_longer_candidate";
            if (e.AwaitRequestId != null) Observation(e, state, nowMs);
            if (_pending != null && _pending.WindowId == e.WindowId)
            {
                _journal.Write("repair_observation", Util.Map(
                    "requestId", _pending.RequestId, "windowId", e.WindowId, "state", state,
                    "phase", "before_restart_result", "relation", "temporal_order_only"));
            }
            _journal.Write(reason == "evicted" ? "window_evicted" : "window_removed_observed",
                Util.Map("windowId", e.WindowId, "reason", reason));
        }

        private void EvictOldest(long nowMs)
        {
            Entry oldest = null;
            foreach (Entry e in _entries.Values)
            {
                if (oldest == null || e.LastSeenMs < oldest.LastSeenMs) oldest = e;
            }
            if (oldest != null) Drop(oldest, "evicted", nowMs);
        }
    }

    internal static class NativeMethods
    {
        internal const uint PM_NOREMOVE = 0, PM_REMOVE = 1, WM_QUIT = 0x0012, QS_ALLINPUT = 0x04FF;
        internal const uint WINEVENT_OUTOFCONTEXT = 0, WINEVENT_SKIPOWNPROCESS = 2;
        internal const uint GA_ROOT = 2, GW_OWNER = 4, PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

        internal delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint threadId, uint timeMs);
        internal delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        internal struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }

        [StructLayout(LayoutKind.Sequential)]
        internal struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        [DllImport("user32.dll")] internal static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmod, WinEventProc proc, uint pid, uint tid, uint flags);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool UnhookWinEvent(IntPtr hook);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool PeekMessage(out MSG msg, IntPtr hwnd, uint min, uint max, uint remove);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool TranslateMessage(ref MSG msg);
        [DllImport("user32.dll")] internal static extern IntPtr DispatchMessage(ref MSG msg);
        [DllImport("user32.dll")] internal static extern uint MsgWaitForMultipleObjects(uint count, IntPtr handles, [MarshalAs(UnmanagedType.Bool)] bool waitAll, uint ms, uint mask);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool EnumChildWindows(IntPtr parent, EnumProc proc, IntPtr lParam);
        [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] internal static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
        [DllImport("user32.dll")] internal static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] internal static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
        [DllImport("dwmapi.dll")] internal static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);
        [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetClassName(IntPtr hwnd, StringBuilder buffer, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowTextLength(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowText(IntPtr hwnd, StringBuilder buffer, int max);
        [DllImport("kernel32.dll")] internal static extern IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, int pid);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool ProcessIdToSessionId(int pid, out int sessionId);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] internal static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder buffer, ref int size);
    }

    // Read-only observer of KakaoTalk window structure. It never hides, closes, moves or writes to
    // any window, never touches hosts, and only reports a repair request for the caller to act on.
    // Process ownership of a window says nothing about who changed its visibility.
    public sealed class Session : IDisposable
    {
        private const int MaxQueue = 2048, MaxDirty = 256, MaxDescendants = 256, MaxPollRoots = 1024;
#if DIAGNOSTICS_TESTS
        // Test binaries observe only their own explicitly selected off-screen fixture process.
        private static readonly string[] ProcessNames = { "Diagnostics.Tests" };
        internal static int TestTargetPid;
#else
        private static readonly string[] ProcessNames = { "KakaoTalk", "KakaoTalkUI" };
#endif
        private static readonly HashSet<string> Markers = new HashSet<string>(StringComparer.Ordinal)
        {
            "MOMENT \uAD11\uACE0", "AdFit NAS Advertisement"
        };

        private sealed class Target { public int Pid; public long StartTicks; public string Version; public string Name; public long HookAttemptMs; public List<IntPtr> Hooks = new List<IntPtr>(); }
        private struct RawEvent { public IntPtr Hook; public uint Type; public IntPtr Hwnd; }

        private readonly Journal _journal;
        private readonly Tracker _tracker;
        private readonly object _scanGate = new object();
        private readonly object _lifeGate = new object();
        private readonly Dictionary<int, Target> _targets = new Dictionary<int, Target>();
        private readonly Dictionary<IntPtr, Target> _hookOwners = new Dictionary<IntPtr, Target>();
        private readonly Queue<RawEvent> _queue = new Queue<RawEvent>();
        private readonly Dictionary<long, string> _dirty = new Dictionary<long, string>();
        private readonly Dictionary<int, bool> _verified = new Dictionary<int, bool>();
        private readonly List<KeyValuePair<IntPtr, int>> _pollRoots = new List<KeyValuePair<IntPtr, int>>();
        private readonly StringBuilder _classBuffer = new StringBuilder(256);
        private readonly StringBuilder _textBuffer = new StringBuilder(64);
        private readonly NativeMethods.WinEventProc _hookProc;
        private readonly NativeMethods.EnumProc _enumTop;
        private readonly NativeMethods.EnumProc _enumChild;
        private readonly int _sessionId;
        private Thread _thread;
        private ManualResetEvent _ready;
        private volatile bool _stop;
        private volatile bool _running;
        private volatile int _hookCount;
        private volatile int _targetCount;
        private volatile int _failures;
        private int _droppedEvents;
        private long _retryAtMs;
        private bool _overflow;
        private bool _fullRescan;
        private bool _disposed;
        private int _childCount;
        private int _webChildren;
        private bool _marker;
        private int _scanPid;

        public Session(string runtimeDirectory)
        {
            _journal = new Journal(runtimeDirectory);
            _tracker = new Tracker(_journal);
            _hookProc = OnWinEvent;
            _enumTop = OnTopWindow;
            _enumChild = OnChildWindow;
            using (Process current = Process.GetCurrentProcess()) _sessionId = current.SessionId;
            _journal.Write("session_created", null);
        }

        public void Start()
        {
            lock (_lifeGate)
            {
                if (_disposed) throw new ObjectDisposedException("Session");
                if (_thread != null && _thread.IsAlive) return;
                if (_failures > 0 && _journal.ElapsedMs < Interlocked.Read(ref _retryAtMs)) return;
                if (_ready != null) _ready.Close();
                _ready = new ManualResetEvent(false);
                _stop = false;
                _thread = new Thread(Run);
                _thread.IsBackground = true;
                _thread.Name = "KakaoAdDiagnostics";
                _thread.Start(_ready);
                if (!_ready.WaitOne(5000)) _journal.Write("worker_start_timeout", null);
            }
        }

        public void Record(string eventName, string detailsJson)
        {
            if (eventName == null || !Journal.SafeName.IsMatch(eventName)) { Reject("invalid_event_name"); return; }
            object data = null;
            if (!string.IsNullOrEmpty(detailsJson))
            {
                if (detailsJson.Length > Journal.MaxRecordBytes) { Reject("too_large"); return; }
                JavaScriptSerializer js = new JavaScriptSerializer();
                js.RecursionLimit = 16;
                js.MaxJsonLength = Journal.MaxRecordBytes * 2;
                try { data = js.DeserializeObject(detailsJson); }
                catch (ArgumentException) { Reject("invalid_json"); return; }
                catch (InvalidOperationException) { Reject("invalid_json"); return; }
                if (!(data is IDictionary<string, object>)) { Reject("not_object"); return; }
            }
            _journal.Write(eventName, data, "caller");
        }

        public string GetHealthJson()
        {
            Dictionary<string, object> h = Util.Map(
                "schema", 1, "runId", _journal.RunId, "running", _running, "targetCount", _targetCount,
                "hookCount", _hookCount, "trackedWindows", _tracker.TrackedCount,
                "observationMode", _targetCount == 0 ? "waiting_for_kakao" : _hookCount == _targetCount * 2 ? "events_and_poll" : "partial_hooks_and_poll",
                "droppedEvents", Thread.VolatileRead(ref _droppedEvents), "logWriteFailures", _journal.LogWriteFailures,
                "droppedRecords", _journal.DroppedRecords,
                "lastEventUtc", _journal.LastEventUtc, "repairPending", _tracker.PendingRequestId != null,
                "workerFailures", _failures);
            return new JavaScriptSerializer().Serialize(h);
        }

        // Re-validates every tracked root against live process identity before asking the tracker.
        public string TryRequestRepair()
        {
            if (!_running) return null;
            lock (_scanGate)
            {
                if (!_running) return null;
                _verified.Clear();
                long now = _journal.ElapsedMs;
                foreach (Tracker.Identity id in _tracker.GetTrackedIdentities()) RescanRoot(new IntPtr(id.Handle), "refresh", now);
                return _tracker.TryRequestRepair(_journal.ElapsedMs);
            }
        }

        public void CompleteRepair(string requestId, bool restarted)
        {
            _tracker.CompleteRepair(requestId, restarted, _journal.ElapsedMs);
        }

        public void Dispose()
        {
            lock (_lifeGate)
            {
                if (_disposed) return;
                _disposed = true;
                _stop = true;
                bool joined = _thread == null || _thread.Join(3000);
                if (!joined) _journal.Write("worker_join_timeout", null);
                else if (_ready != null) _ready.Close();
                _journal.Write("session_disposed", null);
            }
        }

        private void Reject(string reason)
        {
            _journal.Write("record_rejected", Util.Map("reason", reason));
        }

        private void Run(object state)
        {
            ManualResetEvent ready = (ManualResetEvent)state;
            string failure = null;
            try
            {
                NativeMethods.MSG msg;
                NativeMethods.PeekMessage(out msg, IntPtr.Zero, 0, 0, NativeMethods.PM_NOREMOVE);
                long start = _journal.ElapsedMs;
                lock (_scanGate) { RefreshTargets(start); _verified.Clear(); Poll(start); }
                _running = true;
                _journal.Write("worker_started", Util.Map("targetCount", _targetCount, "hookCount", _hookCount));
                ready.Set();
                long nextIdentity = start + 1000, nextPoll = start + 500;
                while (!_stop)
                {
                    while (NativeMethods.PeekMessage(out msg, IntPtr.Zero, 0, 0, NativeMethods.PM_REMOVE))
                    {
                        if (msg.message == NativeMethods.WM_QUIT) { _stop = true; break; }
                        NativeMethods.TranslateMessage(ref msg);
                        NativeMethods.DispatchMessage(ref msg);
                    }
                    lock (_scanGate)
                    {
                        long now = _journal.ElapsedMs;
                        if (now >= nextIdentity) { RefreshTargets(now); nextIdentity = now + 1000; }
                        _verified.Clear();
                        DrainEvents(now);
                        if (_fullRescan || now >= nextPoll) { _fullRescan = false; Poll(now); nextPoll = now + 500; }
                    }
                    NativeMethods.MsgWaitForMultipleObjects(0, IntPtr.Zero, false, 50, NativeMethods.QS_ALLINPUT);
                }
            }
            catch (Win32Exception) { failure = "win32"; }
            catch (ExternalException) { failure = "native"; }
            catch (InvalidOperationException) { failure = "invalid_operation"; }
            catch (Exception) { failure = "unexpected"; } // Reported via health; an escaping exception would kill the host.
            finally
            {
                _running = false;
                lock (_scanGate)
                {
                    long now = _journal.ElapsedMs;
                    foreach (Target t in new List<Target>(_targets.Values)) Unhook(t);
                    _targets.Clear();
                    _targetCount = 0;
                    _queue.Clear();
                    _dirty.Clear();
                    foreach (Tracker.Identity id in _tracker.GetTrackedIdentities()) _tracker.Remove(id.Handle, id.Pid, id.StartedTicks, "monitor_stopped", now);
                }
                if (failure != null)
                {
                    int count = ++_failures;
                    long delay = Math.Min(300000L, 5000L << Math.Min(count - 1, 6));
                    Interlocked.Exchange(ref _retryAtMs, _journal.ElapsedMs + delay);
                    _journal.Write("worker_failed", Util.Map("category", failure, "failures", count, "retryAfterMs", delay));
                }
                else
                {
                    _journal.Write("worker_stopped", null);
                }
                ready.Set();
            }
        }

        // Runs on the worker thread during message dispatch. Enqueue only: no scans, no I/O.
        private void OnWinEvent(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint threadId, uint timeMs)
        {
            if (idObject != 0 || idChild != 0 || hwnd == IntPtr.Zero) return;
            if (!((eventType >= 0x8000 && eventType <= 0x8003) || eventType == 0x800B || eventType == 0x800C)) return;
            if (_queue.Count >= MaxQueue)
            {
                Interlocked.Increment(ref _droppedEvents);
                _overflow = true;
                return;
            }
            RawEvent ev = new RawEvent();
            ev.Hook = hook; ev.Type = eventType; ev.Hwnd = hwnd;
            _queue.Enqueue(ev);
        }

        private void DrainEvents(long now)
        {
            if (_overflow)
            {
                _overflow = false;
                _fullRescan = true;
                _journal.Write("event_queue_overflow", Util.Map("droppedEvents", Thread.VolatileRead(ref _droppedEvents)));
            }
            while (_queue.Count > 0)
            {
                RawEvent ev = _queue.Dequeue();
                Target t;
                if (!_hookOwners.TryGetValue(ev.Hook, out t) || !Verified(t)) continue;
                HandleEvent(ev, t, now);
            }
            foreach (KeyValuePair<long, string> d in new List<KeyValuePair<long, string>>(_dirty)) RescanRoot(new IntPtr(d.Key), d.Value, now);
            _dirty.Clear();
        }

        private void HandleEvent(RawEvent ev, Target t, long now)
        {
            string kind = ev.Type == 0x8000 ? "create" : ev.Type == 0x8001 ? "destroy" : ev.Type == 0x8002 ? "show" : ev.Type == 0x8003 ? "hide" : "structure";
            long h = ev.Hwnd.ToInt64();
            bool alive = NativeMethods.IsWindow(ev.Hwnd) && PidOf(ev.Hwnd) == t.Pid;
            if (!alive)
            {
                // Gone window: use hook-owner identity so a reused handle is never removed by a stale destroy.
                if (_tracker.Contains(h))
                {
                    if (kind == "destroy") _tracker.Remove(h, t.Pid, t.StartTicks, "destroy", now);
                    else MarkDirty(h, "structure");
                }
                else
                {
                    MarkPidDirty(t.Pid);
                }
                return;
            }
            IntPtr root = NativeMethods.GetAncestor(ev.Hwnd, NativeMethods.GA_ROOT);
            if (root == IntPtr.Zero) return;
            // Child events and live-handle destroy notifications only trigger a structural rescan.
            bool rootNotification = root == ev.Hwnd && kind != "destroy" && kind != "structure";
            // Preserve root notification order even when show/hide arrive in the same pump.
            // The snapshot is current state, not reconstructed visibility at event generation.
            if (rootNotification) RescanRoot(root, kind, now);
            else MarkDirty(root.ToInt64(), "structure");
        }

        private void MarkDirty(long root, string reason)
        {
            string existing;
            if (_dirty.TryGetValue(root, out existing))
            {
                if (reason != "structure") _dirty[root] = reason;
                return;
            }
            if (_dirty.Count >= MaxDirty) { _fullRescan = true; return; }
            _dirty[root] = reason;
        }

        private void MarkPidDirty(int pid)
        {
            foreach (Tracker.Identity id in _tracker.GetTrackedIdentities())
            {
                if (id.Pid == pid) MarkDirty(id.Handle, "structure");
            }
        }

        private void RescanRoot(IntPtr root, string reason, long now)
        {
            long h = root.ToInt64();
            int trackedPid;
            long trackedTicks;
            bool tracked = _tracker.TryGetIdentity(h, out trackedPid, out trackedTicks);
            bool exists = NativeMethods.IsWindow(root);
            int pid = exists ? PidOf(root) : 0;
            Target t;
            if (exists && _targets.TryGetValue(pid, out t))
            {
                if (!Verified(t)) return; // Process identity changed; RefreshTargets will report it.
                Snapshot s = Classify(root, t);
                if (s != null) { _tracker.Observe(s, reason, now); return; }
            }
            if (tracked)
            {
                string why = exists && pid == trackedPid ? "not_candidate" : "missing";
                _tracker.Remove(h, trackedPid, trackedTicks, why, now);
            }
        }

        private void Poll(long now)
        {
            _pollRoots.Clear();
            NativeMethods.EnumWindows(_enumTop, IntPtr.Zero);
            HashSet<long> seen = new HashSet<long>();
            foreach (KeyValuePair<IntPtr, int> root in _pollRoots)
            {
                Target t;
                if (!_targets.TryGetValue(root.Value, out t)) continue;
                long h = root.Key.ToInt64();
                seen.Add(h);
                if (!Verified(t)) continue;
                Snapshot s = Classify(root.Key, t);
                if (s != null) { _tracker.Observe(s, "enum", now); continue; }
                int pid;
                long ticks;
                if (_tracker.TryGetIdentity(h, out pid, out ticks))
                {
                    _tracker.Remove(h, pid, ticks, pid == t.Pid && ticks == t.StartTicks ? "not_candidate" : "missing", now);
                }
            }
            foreach (Tracker.Identity id in _tracker.GetTrackedIdentities())
            {
                if (!seen.Contains(id.Handle)) RescanRoot(new IntPtr(id.Handle), "enum", now);
            }
        }

        // PID filter happens before any class/caption access.
        private bool OnTopWindow(IntPtr hwnd, IntPtr lParam)
        {
            int pid = PidOf(hwnd);
            if (pid > 0 && _targets.ContainsKey(pid) && _pollRoots.Count < MaxPollRoots)
            {
                _pollRoots.Add(new KeyValuePair<IntPtr, int>(hwnd, pid));
            }
            return _pollRoots.Count < MaxPollRoots;
        }

        // Structural classification. Root caption is only length-checked, never read.
        private Snapshot Classify(IntPtr root, Target t)
        {
            if (!NativeMethods.IsWindow(root) || PidOf(root) != t.Pid || !Verified(t)) return null;
            string cls = ClassOf(root);
            bool popup = string.Equals(cls, "EVA_Window", StringComparison.Ordinal);
            bool banner = string.Equals(cls, "EVA_Window_Dblclk", StringComparison.Ordinal);
            if (!popup && !banner) return null;
            bool owned = NativeMethods.GetWindow(root, NativeMethods.GW_OWNER) != IntPtr.Zero;
            if (popup == owned) return null;
            if (NativeMethods.GetWindowTextLength(root) != 0) return null;
            NativeMethods.RECT r;
            if (!NativeMethods.GetWindowRect(root, out r)) return null;
            int w = r.Right - r.Left, hgt = r.Bottom - r.Top;
            if (w < 0 || hgt < 0) return null;
            if (popup && (w < 200 || w > 1000 || hgt < 100 || hgt > 800)) return null;
            _childCount = 0;
            _webChildren = 0;
            _marker = false;
            _scanPid = t.Pid;
            NativeMethods.EnumChildWindows(root, _enumChild, IntPtr.Zero);
            if (banner && _webChildren == 0) return null;
            if (PidOf(root) != t.Pid || QueryStartTicks(t.Pid) != t.StartTicks) return null;
            Snapshot s = new Snapshot();
            s.Handle = root.ToInt64(); s.Pid = t.Pid; s.StartedTicks = t.StartTicks; s.Version = t.Version;
            s.Kind = popup ? "popup" : "banner";
            bool onScreen = NativeMethods.MonitorFromWindow(root, 0) != IntPtr.Zero;
            int cloaked;
            bool cloakKnown = NativeMethods.DwmGetWindowAttribute(root, 14, out cloaked, 4) == 0;
#if DIAGNOSTICS_TESTS
            // The native fixture deliberately stays off screen; this bypass is not installed.
            onScreen = true; cloakKnown = true; cloaked = 0;
#endif
            s.Visible = NativeMethods.IsWindowVisible(root) && w > 0 && hgt > 0 && onScreen && cloakKnown && cloaked == 0;
            s.StrongEvidence = popup && _marker;
            s.Width = w; s.Height = hgt; s.WebChildren = _webChildren;
            return s;
        }

        // Captions of specific Chromium child classes are compared to exact markers and discarded.
        private bool OnChildWindow(IntPtr hwnd, IntPtr lParam)
        {
            if (++_childCount > MaxDescendants) return false;
            if (PidOf(hwnd) != _scanPid) return true;
            string cls = ClassOf(hwnd);
            if (!cls.StartsWith("Chrome_", StringComparison.Ordinal)) return true;
            _webChildren++;
            if (!_marker && (cls == "Chrome_WidgetWin_0" || cls == "Chrome_WidgetWin_1" || cls == "Chrome_RenderWidgetHostHWND"))
            {
                _textBuffer.Length = 0;
                int n = NativeMethods.GetWindowText(hwnd, _textBuffer, _textBuffer.Capacity);
                if (n > 0 && n < _textBuffer.Capacity - 1 && Markers.Contains(_textBuffer.ToString())) _marker = true;
                _textBuffer.Length = 0;
            }
            return true;
        }

        private string ClassOf(IntPtr hwnd)
        {
            _classBuffer.Length = 0;
            int n = NativeMethods.GetClassName(hwnd, _classBuffer, _classBuffer.Capacity);
            string value = n > 0 ? _classBuffer.ToString() : string.Empty;
            _classBuffer.Length = 0;
            return value;
        }

        private static int PidOf(IntPtr hwnd)
        {
            uint pid;
            NativeMethods.GetWindowThreadProcessId(hwnd, out pid);
            return (int)pid;
        }

        private bool Verified(Target t)
        {
            bool ok;
            if (!_verified.TryGetValue(t.Pid, out ok))
            {
                ok = QueryStartTicks(t.Pid) == t.StartTicks;
                _verified[t.Pid] = ok;
            }
            return ok;
        }

        private void RefreshTargets(long now)
        {
            HashSet<int> live = new HashSet<int>();
            foreach (string name in ProcessNames)
            {
                foreach (Process p in Process.GetProcessesByName(name))
                {
                    using (p)
                    {
                        int pid = p.Id;
#if DIAGNOSTICS_TESTS
                        if (pid != TestTargetPid) continue;
#endif
                        int sid;
                        if (pid <= 0 || !NativeMethods.ProcessIdToSessionId(pid, out sid) || sid != _sessionId) continue;
                        long ticks = QueryStartTicks(pid);
                        if (ticks <= 0) continue;
                        live.Add(pid);
                        Target t;
                        if (_targets.TryGetValue(pid, out t))
                        {
                            if (t.StartTicks == ticks) {
                                if (t.Hooks.Count < 2 && now - t.HookAttemptMs >= 30000) { Unhook(t); InstallHooks(t); }
                                continue;
                            }
                            DropTarget(t, "identity_changed", now);
                        }
                        t = new Target();
                        t.Pid = pid; t.StartTicks = ticks; t.Version = QueryVersion(pid); t.Name = name.ToLowerInvariant();
                        _targets[pid] = t;
                        _journal.Write("process_discovered", Util.Map("pid", pid, "process", t.Name, "version", t.Version));
                        InstallHooks(t);
                    }
                }
            }
            foreach (Target t in new List<Target>(_targets.Values))
            {
                if (!live.Contains(t.Pid)) DropTarget(t, "exited", now);
            }
            _targetCount = _targets.Count;
        }

        private void InstallHooks(Target t)
        {
            t.HookAttemptMs = _journal.ElapsedMs;
            uint flags = NativeMethods.WINEVENT_OUTOFCONTEXT | NativeMethods.WINEVENT_SKIPOWNPROCESS;
            IntPtr lifecycle = NativeMethods.SetWinEventHook(0x8000, 0x8003, IntPtr.Zero, _hookProc, (uint)t.Pid, 0, flags);
            IntPtr structure = NativeMethods.SetWinEventHook(0x800B, 0x800C, IntPtr.Zero, _hookProc, (uint)t.Pid, 0, flags);
            foreach (IntPtr h in new IntPtr[] { lifecycle, structure })
            {
                if (h == IntPtr.Zero) continue;
                t.Hooks.Add(h);
                _hookOwners[h] = t;
            }
            if (t.Hooks.Count < 2) _journal.Write("hook_install_incomplete", Util.Map("pid", t.Pid, "installed", t.Hooks.Count));
            _hookCount = _hookOwners.Count;
        }

        private void Unhook(Target t)
        {
            foreach (IntPtr h in t.Hooks)
            {
                NativeMethods.UnhookWinEvent(h);
                _hookOwners.Remove(h);
            }
            t.Hooks.Clear();
            _hookCount = _hookOwners.Count;
        }

        private void DropTarget(Target t, string reason, long now)
        {
            Unhook(t);
            _targets.Remove(t.Pid);
            _verified.Clear();
            _journal.Write("process_exited", Util.Map("pid", t.Pid, "process", t.Name, "reason", reason));
            foreach (Tracker.Identity id in _tracker.GetTrackedIdentities())
            {
                if (id.Pid == t.Pid && id.StartedTicks == t.StartTicks) _tracker.Remove(id.Handle, id.Pid, id.StartedTicks, "process_exit", now);
            }
        }

        private static long QueryStartTicks(int pid)
        {
            IntPtr hp = NativeMethods.OpenProcess(NativeMethods.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (hp == IntPtr.Zero) return 0;
            try
            {
                long creation, exit, kernel, user;
                return NativeMethods.GetProcessTimes(hp, out creation, out exit, out kernel, out user) ? creation : 0;
            }
            finally
            {
                NativeMethods.CloseHandle(hp);
            }
        }

        // The image path is used transiently for version lookup and never stored or logged.
        private static string QueryVersion(int pid)
        {
            IntPtr hp = NativeMethods.OpenProcess(NativeMethods.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (hp == IntPtr.Zero) return "0";
            try
            {
                StringBuilder sb = new StringBuilder(1024);
                int size = sb.Capacity;
                if (!NativeMethods.QueryFullProcessImageName(hp, 0, sb, ref size)) return "0";
                FileVersionInfo info = FileVersionInfo.GetVersionInfo(sb.ToString());
                return string.Format(CultureInfo.InvariantCulture, "{0}.{1}.{2}.{3}",
                    info.FileMajorPart, info.FileMinorPart, info.FileBuildPart, info.FilePrivatePart);
            }
            catch (IOException) { return "0"; }
            catch (ArgumentException) { return "0"; }
            catch (SecurityException) { return "0"; }
            finally
            {
                NativeMethods.CloseHandle(hp);
            }
        }
    }
}
