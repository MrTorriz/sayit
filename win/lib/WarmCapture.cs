// One capture thread in the already-running trigger host; no per-press process.
using System;
using System.Threading;

namespace Sayit
{
    public sealed class WarmCapture : IDisposable
    {
        public readonly EventWaitHandle Stop;
        public readonly EventWaitHandle Done;
        public readonly EventWaitHandle Ready;
        public Exception Failure;
        public int Frames;
        public int Peak;
        private readonly Thread worker;

        public WarmCapture(string path, int device, string eventName, int seconds)
        {
            Stop = new EventWaitHandle(false, EventResetMode.ManualReset, eventName);
            Done = new EventWaitHandle(false, EventResetMode.ManualReset, eventName + "-done");
            Ready = new EventWaitHandle(false, EventResetMode.ManualReset);
            worker = new Thread(delegate() {
                try { Frames = Recorder.CaptureToWav(path, device, Stop, seconds, out Peak, Ready); }
                catch (Exception error) { Failure = error; }
                finally { Done.Set(); }
            });
            worker.IsBackground = true;
            worker.Name = "sayit-capture";
            worker.Start();
        }

        public void RequestStop() { Stop.Set(); }

        public void Dispose()
        {
            Stop.Set();
            if (!worker.Join(5000)) { throw new TimeoutException("Capture did not stop."); }
            Stop.Dispose(); Done.Dispose(); Ready.Dispose();
        }
    }
}
