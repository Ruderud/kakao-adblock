using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using KakaoAdDiagnostics;

internal static class DiagnosticsTests
{
    private static int count;
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static void Check(bool condition, string description)
    {
        if (!condition) throw new Exception("FAIL: " + description);
        count++; Console.WriteLine("PASS: " + description);
    }
    private static Snapshot Popup(long handle, bool strong, bool visible)
    {
        return new Snapshot { Handle=handle, Pid=1234, StartedTicks=100, Version="26.9.2.5342",
            Kind="popup", Visible=visible, StrongEvidence=strong, Width=450, Height=300, WebChildren=strong ? 2 : 0 };
    }
    private static string Folder(string root, string name)
    {
        string path=Path.Combine(root,name); Directory.CreateDirectory(path); return path;
    }
    private static string[] Events(string root)
    {
        string path=Path.Combine(root,"events.jsonl");
        if (!File.Exists(path)) return new string[0];
        return File.ReadAllLines(path).Select(line => (string)((Dictionary<string,object>)Json.DeserializeObject(line))["event"]).ToArray();
    }
    private static void Main(string[] args)
    {
        try { if(args.Length==1 && args[0]=="--fixture") { NativeFixture.Run(); return; } RunTests(args); }
        catch(Exception error) { Console.Error.WriteLine(error.Message); Environment.ExitCode=1; }
    }
    private static void RunTests(string[] args)
    {
        string root=args.Length==1 ? args[0] : Path.Combine(Path.GetTempPath(),"kakao-diagnostic-tests-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        string lifecycle=Folder(root,"lifecycle");
        var journal=new Journal(lifecycle);
        var tracker=new Tracker(journal);
        var p=Popup(10,false,true);
        tracker.Observe(p,"enum",0);
        Check(tracker.TryRequestRepair(5000)==null,"An unconfirmed web candidate cannot request repair");
        p.StrongEvidence=true; p.WebChildren=2;
        tracker.Observe(p,"structure",5000);
        Check(tracker.TryRequestRepair(5500)==null,"Late web children must establish persistent strong evidence first");
        string request=tracker.TryRequestRepair(6100);
        Check(!String.IsNullOrEmpty(request),"A persistent upstream popup pattern can request repair");
        tracker.CompleteRepair(request,true,6200);
        p.Visible=false; tracker.Observe(p,"hide",6300);
        p.Visible=true; tracker.Observe(p,"show",6400);
        Check(Events(lifecycle).Contains("window_reappeared"),"A hidden window becoming visible is logged as reappearance");
        Check(Events(lifecycle).Contains("repair_requested") && Events(lifecycle).Contains("repair_restart_result"),"Requests and restart outcomes are journaled");
        Check(tracker.TryRequestRepair(20000)==null,"A returning popup cannot bypass the global repair cooldown");
        tracker.Remove(10,1234,100,"destroy",21000);
        Check(tracker.TrackedCount==0,"Destroyed windows are removed from live evidence");
        Check(tracker.TryRequestRepair(100000)==null,"Destroyed windows cannot trigger later repair");
        Check(Events(lifecycle).Contains("window_removed_observed"),"Destruction has its own event");

        string reuse=Folder(root,"reuse");
        var reused=new Tracker(new Journal(reuse));
        reused.Observe(Popup(20,true,true),"enum",0);
        var replacement=Popup(20,false,true); replacement.Pid=2345; replacement.StartedTicks=200;
        reused.Observe(replacement,"enum",2000);
        Check(reused.TryRequestRepair(10000)==null,"Reused HWNDs cannot inherit another process's ad evidence");
        reused.Remove(20,1234,100,"destroy",11000);
        Check(reused.TrackedCount==1,"A stale destroy does not remove a reused handle's current identity");
        replacement.Kind="banner"; replacement.StrongEvidence=false;
        reused.Observe(replacement,"enum",12000);
        Check(reused.TryRequestRepair(20000)==null,"Banner candidates are observed without popup-triggered restart");

        string limit=Folder(root,"limits");
        var limited=new Tracker(new Journal(limit));
        limited.Observe(Popup(30,true,true),"enum",0);
        string first=limited.TryRequestRepair(1100); Check(first!=null,"First eligible automatic request is allowed");
        limited.CompleteRepair(first,false,1200);
        limited.Observe(Popup(30,true,true),"enum",61000);
        string second=limited.TryRequestRepair(62000); Check(second!=null && second!=first,"A surviving popup can retry after cooldown with a new request ID");
        limited.CompleteRepair(second,false,62100);
        limited.Observe(Popup(30,true,true),"enum",122000);
        string third=limited.TryRequestRepair(123000); Check(third!=null,"Third bounded recovery request is allowed");
        limited.CompleteRepair(third,false,123100);
        limited.Observe(Popup(32,true,true),"enum",182000);
        Check(limited.TryRequestRepair(184000)==null,"A fourth request in ten minutes is refused");
        limited.Observe(Popup(31,true,true),"enum",700000); Check(limited.TryRequestRepair(702000)!=null,"The rate-limit window eventually expires for a new instance");

        string capacity=Folder(root,"capacity");
        var capped=new Tracker(new Journal(capacity));
        for(int i=1;i<=400;i++) capped.Observe(Popup(i,false,false),"enum",i);
        Check(capped.TrackedCount<=256,"Window tracking stays bounded under churn");
        var invalid=Popup(999,true,true); invalid.Pid=0;
        capped.Observe(invalid,"enum",5000);
        Check(capped.TryRequestRepair(10000)==null,"Invalid process identity cannot request recovery");

        string privacy=Folder(root,"privacy");
        var privateTracker=new Tracker(new Journal(privacy));
        var suspicious=Popup(40,false,true); suspicious.Version="PRIVATE_VALUE_DO_NOT_LOG";
        privateTracker.Observe(suspicious,"enum",0);
        string privateText=File.Exists(Path.Combine(privacy,"events.jsonl")) ? File.ReadAllText(Path.Combine(privacy,"events.jsonl")) : "";
        Check(!privateText.Contains("PRIVATE_VALUE_DO_NOT_LOG"),"Unexpected version text is omitted or sanitized");
        string data=File.ReadAllText(Path.Combine(lifecycle,"events.jsonl"));
        Check(!data.Contains(lifecycle),"Journal records omit the local directory path");
        foreach(string line in File.ReadAllLines(Path.Combine(lifecycle,"events.jsonl")))
        {
            var entry=(Dictionary<string,object>)Json.DeserializeObject(line);
            Check(entry.ContainsKey("timestampUtc") && entry.ContainsKey("monotonicMs") && entry.ContainsKey("runId"),"Each record carries UTC time, monotonic order and run identity");
        }

        string rotation=Folder(root,"rotation"); var rotating=new Journal(rotation,4096);
        for(int i=0;i<120;i++) rotating.Write("rotation_test",new { index=i, padding=new string('x',300) });
        var logs=Directory.GetFiles(rotation,"events*.jsonl");
        Check(logs.Length<=4 && logs.Length>1,"Journal rotation retains at most current plus three archives");
        foreach(string file in logs) foreach(string line in File.ReadAllLines(file)) Json.DeserializeObject(line);
        Check(true,"Rotated files contain complete parseable JSON records");
        int failures=rotating.LogWriteFailures;
        rotating.Write("oversize_test",new { padding=new string('x',40000) });
        Check(rotating.LogWriteFailures>failures || Events(rotation).Any(e=>e.Contains("drop")),"Oversized records are rejected with observable loss");
        string blocked=Path.Combine(root,"not-a-directory"); File.WriteAllText(blocked,"fixture");
        var brokenJournal=new Journal(blocked); brokenJournal.Write("sink_test",new { value=1 });
        Check(brokenJournal.LogWriteFailures>0,"A broken journal sink reports failure without throwing into protection");
        RunNativeFixture(Folder(root,"native"));
        Console.WriteLine("Diagnostics tests passed: "+count);
    }

    private static void RunNativeFixture(string directory)
    {
        var info=new ProcessStartInfo(Assembly.GetExecutingAssembly().Location,"--fixture") {
            UseShellExecute=false,CreateNoWindow=true,WindowStyle=ProcessWindowStyle.Hidden,
            RedirectStandardInput=true,RedirectStandardOutput=true,RedirectStandardError=true };
        using(var child=Process.Start(info))
        {
            try {
                var ready=child.StandardOutput.ReadLineAsync();
                if(!ready.Wait(5000) || ready.Result!="ready") throw new Exception("Native fixture did not start");
                Session.TestTargetPid=child.Id;
                using(var observer=new Session(directory))
                {
                    observer.Start();
                    var health=(Dictionary<string,object>)Json.DeserializeObject(observer.GetHealthJson());
                    Check((bool)health["running"] && Convert.ToInt32(health["hookCount"])==2,"Native hooks attach only to the selected fixture process");
                    child.StandardInput.WriteLine("go"); child.StandardInput.Flush();
                    string request=null;
                    long requestedAt=0;
                    var timeout=Stopwatch.StartNew();
                    while(!child.HasExited && timeout.ElapsedMilliseconds<12000) {
                        if(request==null) { request=observer.TryRequestRepair(); if(request!=null) { requestedAt=timeout.ElapsedMilliseconds; observer.CompleteRepair(request,false); } }
                        Thread.Sleep(50);
                    }
                    if(!child.HasExited || child.ExitCode!=0) throw new Exception("Native fixture failed or timed out");
                    Thread.Sleep(200);
                    var events=Events(directory);
                    Check(events.Contains("window_first_observed"),"Native creation/show events discover the off-screen fixture");
                    Check(events.Contains("window_structure_changed"),"Native delayed Chrome child creation updates evidence");
                    Check(request!=null,"Live identity/visibility revalidation allows a synthetic persistent-popup request");
                    Check(requestedAt>=2600,"Generic Chromium captions do not trigger automatic recovery");
                    Check(events.Contains("window_hidden_observed") && events.Contains("window_reappeared"),"Native hide and show preserve recurrence history");
                    var records=File.ReadAllLines(Path.Combine(directory,"events.jsonl")).Select(line=>(Dictionary<string,object>)Json.DeserializeObject(line)).ToList();
                    int firstReappearance=records.FindIndex(row=>(string)row["event"]=="window_reappeared");
                    var burst=records.Skip(firstReappearance+1).Where(row=>row["data"] is Dictionary<string,object>).Select(row=>(Dictionary<string,object>)row["data"]).Where(dataRow=>dataRow.ContainsKey("source") && (string)dataRow["source"]=="event").ToList();
                    Check(burst.Any(dataRow=>dataRow.ContainsKey("notification") && (string)dataRow["notification"]=="hide") && burst.Any(dataRow=>dataRow.ContainsKey("notification") && (string)dataRow["notification"]=="show"),"A rapid hide/show burst is journaled even between fallback polls");
                    Check(events.Contains("window_removed_observed"),"Native destroy is observed without dereferencing a stale window");
                    Check(events.Contains("repair_observation"),"A later native observation is correlated with the synthetic repair result");
                }
                Check(Events(directory).Contains("worker_stopped"),"Observer shutdown releases native hooks cleanly");
            } finally { if(!child.HasExited) { child.Kill(); child.WaitForExit(3000); } }
        }
    }
}

internal static class NativeFixture
{
    private delegate IntPtr WndProc(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam);
    private static readonly WndProc Callback=DefWindowProc;
    [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
    private struct WndClass { public uint style; public WndProc proc; public int clsExtra,wndExtra; public IntPtr instance,icon,cursor,background; public string menuName,className; }
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern ushort RegisterClass(ref WndClass wc);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern IntPtr CreateWindowEx(uint ex,string cls,string title,uint style,int x,int y,int w,int h,IntPtr parent,IntPtr menu,IntPtr instance,IntPtr data);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern IntPtr DefWindowProc(IntPtr hwnd,uint message,IntPtr wParam,IntPtr lParam);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hwnd,int command);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] private static extern bool SetWindowText(IntPtr hwnd,string text);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] private static extern IntPtr GetModuleHandle(string name);
    private static void Register(string name) { var wc=new WndClass { proc=Callback,instance=GetModuleHandle(null),className=name }; if(RegisterClass(ref wc)==0) throw new Exception("Fixture class registration failed"); }
    private static void Pump(int milliseconds) {
        var clock=Stopwatch.StartNew(); NativeMethods.MSG message;
        while(clock.ElapsedMilliseconds<milliseconds) {
            while(NativeMethods.PeekMessage(out message,IntPtr.Zero,0,0,NativeMethods.PM_REMOVE)) { NativeMethods.TranslateMessage(ref message); NativeMethods.DispatchMessage(ref message); }
            Thread.Sleep(10);
        }
    }
    internal static void Run() {
        Console.WriteLine("ready"); Console.Out.Flush();
        if(Console.ReadLine()!="go") return;
        Register("EVA_Window"); Register("Chrome_WidgetWin_1");
        IntPtr root=CreateWindowEx(0x08000080,"EVA_Window","",0x80000000,-30000,-30000,450,300,IntPtr.Zero,IntPtr.Zero,GetModuleHandle(null),IntPtr.Zero);
        if(root==IntPtr.Zero) throw new Exception("Fixture creation failed");
        ShowWindow(root,4); Pump(400);
        IntPtr web=CreateWindowEx(0,"Chrome_WidgetWin_1","Chrome Legacy Window",0x50000000,0,0,440,280,root,IntPtr.Zero,GetModuleHandle(null),IntPtr.Zero);
        if(web==IntPtr.Zero) throw new Exception("Fixture child creation failed");
        Pump(1500); SetWindowText(web,"AdFit NAS Advertisement");
        Pump(2200); ShowWindow(root,0); Pump(500); ShowWindow(root,4); Pump(500);
        ShowWindow(root,0); ShowWindow(root,4); Pump(300);
        DestroyWindow(root); Pump(400);
    }
}
