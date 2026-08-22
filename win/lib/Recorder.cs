// Recorder.cs - microphone capture to 16 kHz mono 16-bit PCM.
//
// Compiled at runtime by Add-Type from sayit-record.ps1. Kept to C# 5 syntax
// because Add-Type on Windows PowerShell 5.1 uses the in-box csc.exe, which
// supports no later language version.
//
// waveIn rather than WASAPI: waveIn on Vista and later is a shim over the same
// shared-mode audio engine, so asking for 16 kHz mono 16-bit gets the engine's
// resampler for free (as long as WAVE_FORMAT_DIRECT is NOT passed). It needs no
// COM interop, and it is not affected by the Windows 11 24H2 defect where
// AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM can deliver silence on some USB capture
// endpoints.
//
// Device naming: WAVEINCAPS.szPname is capped at 31 usable characters, so the
// friendly name alone is not a reliable key. GetEndpointId maps a waveIn index
// to the MMDevice endpoint ID, which is what callers should persist.

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Sayit
{
    public class Recorder
    {
        public const int SampleRate = 16000;
        public const int Channels = 1;
        public const int BitsPerSample = 16;

        private const int CALLBACK_EVENT = 0x00050000;
        private const int WAVE_FORMAT_PCM = 1;
        private const int WHDR_DONE = 0x00000001;
        private const int MMSYSERR_NOERROR = 0;
        private const int BufferCount = 8;
        private const int BufferMilliseconds = 100;

        private const int DRV_RESERVED = 0x0800;
        private const int DRV_QUERYFUNCTIONINSTANCEIDSIZE = DRV_RESERVED + 17;
        private const int DRV_QUERYFUNCTIONINSTANCEID = DRV_RESERVED + 18;

        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        private struct WAVEFORMATEX
        {
            public short wFormatTag;
            public short nChannels;
            public int nSamplesPerSec;
            public int nAvgBytesPerSec;
            public short nBlockAlign;
            public short wBitsPerSample;
            public short cbSize;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct WAVEHDR
        {
            public IntPtr lpData;
            public int dwBufferLength;
            public int dwBytesRecorded;
            public IntPtr dwUser;
            public int dwFlags;
            public int dwLoops;
            public IntPtr lpNext;
            public IntPtr reserved;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WAVEINCAPS
        {
            public short wMid;
            public short wPid;
            public int vDriverVersion;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string szPname;
            public int dwFormats;
            public short wChannels;
            public short wReserved1;
        }

        [DllImport("winmm.dll")] private static extern int waveInGetNumDevs();
        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        private static extern int waveInGetDevCapsW(IntPtr deviceId, ref WAVEINCAPS caps, int size);
        [DllImport("winmm.dll")]
        private static extern int waveInOpen(out IntPtr hwi, int deviceId, ref WAVEFORMATEX fmt,
                                             IntPtr callback, IntPtr instance, int flags);
        [DllImport("winmm.dll")] private static extern int waveInClose(IntPtr hwi);
        [DllImport("winmm.dll")] private static extern int waveInPrepareHeader(IntPtr hwi, IntPtr hdr, int size);
        [DllImport("winmm.dll")] private static extern int waveInUnprepareHeader(IntPtr hwi, IntPtr hdr, int size);
        [DllImport("winmm.dll")] private static extern int waveInAddBuffer(IntPtr hwi, IntPtr hdr, int size);
        [DllImport("winmm.dll")] private static extern int waveInStart(IntPtr hwi);
        [DllImport("winmm.dll")] private static extern int waveInStop(IntPtr hwi);
        [DllImport("winmm.dll")] private static extern int waveInReset(IntPtr hwi);
        // dwParam1 is a DWORD_PTR, so it must be pointer-sized on x64.
        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        private static extern int waveInMessage(IntPtr hwi, int msg, ref UIntPtr param1, IntPtr param2);
        [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
        private static extern int waveInMessage(IntPtr hwi, int msg, IntPtr param1, IntPtr param2);

        public class DeviceInfo
        {
            public int Index;
            public string Name;        // truncated to 31 chars by the API
            public string EndpointId;  // MMDevice endpoint ID, or null
        }

        /// Enumerate capture devices. EndpointId is the stable key; Name is for display.
        public static List<DeviceInfo> ListDevices()
        {
            List<DeviceInfo> devices = new List<DeviceInfo>();
            int n = waveInGetNumDevs();
            for (int i = 0; i < n; i++)
            {
                WAVEINCAPS caps = new WAVEINCAPS();
                if (waveInGetDevCapsW(new IntPtr(i), ref caps, Marshal.SizeOf(typeof(WAVEINCAPS))) != MMSYSERR_NOERROR)
                {
                    continue;
                }
                DeviceInfo info = new DeviceInfo();
                info.Index = i;
                info.Name = caps.szPname;
                info.EndpointId = GetEndpointId(i);
                devices.Add(info);
            }
            return devices;
        }

        /// Map a waveIn device index to its MMDevice endpoint ID. Vista and later.
        public static string GetEndpointId(int deviceIndex)
        {
            try
            {
                UIntPtr sizePtr = UIntPtr.Zero;
                IntPtr h = new IntPtr(deviceIndex);
                if (waveInMessage(h, DRV_QUERYFUNCTIONINSTANCEIDSIZE, ref sizePtr, IntPtr.Zero) != MMSYSERR_NOERROR)
                {
                    return null;
                }
                int size = (int)sizePtr.ToUInt64();
                if (size <= 0) { return null; }

                IntPtr buffer = Marshal.AllocHGlobal(size);
                try
                {
                    if (waveInMessage(h, DRV_QUERYFUNCTIONINSTANCEID, buffer, new IntPtr(size)) != MMSYSERR_NOERROR)
                    {
                        return null;
                    }
                    return Marshal.PtrToStringUni(buffer);
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            catch
            {
                return null;
            }
        }

        /// Resolve a user-supplied device selector to a waveIn index.
        /// Accepts an endpoint ID, a full or partial friendly name, or "" for the
        /// system default. Returns -1 (WAVE_MAPPER) when nothing matches.
        public static int ResolveDevice(string selector)
        {
            if (string.IsNullOrEmpty(selector)) { return -1; }

            List<DeviceInfo> devices = ListDevices();

            foreach (DeviceInfo d in devices)
            {
                if (d.EndpointId != null &&
                    string.Equals(d.EndpointId, selector, StringComparison.OrdinalIgnoreCase))
                {
                    return d.Index;
                }
            }
            foreach (DeviceInfo d in devices)
            {
                if (d.Name != null &&
                    string.Equals(d.Name, selector, StringComparison.OrdinalIgnoreCase))
                {
                    return d.Index;
                }
            }
            // Substring match last: the API truncates names at 31 characters, so an
            // exact match on a longer configured name would otherwise never fire.
            foreach (DeviceInfo d in devices)
            {
                if (d.Name != null && d.Name.Length > 0 &&
                    (selector.IndexOf(d.Name, StringComparison.OrdinalIgnoreCase) >= 0 ||
                     d.Name.IndexOf(selector, StringComparison.OrdinalIgnoreCase) >= 0))
                {
                    return d.Index;
                }
            }
            return -2; // caller reports "configured device not found"
        }

        /// Where the live level is published while recording, or null to skip it.
        /// The recording indicator reads this rather than opening a second capture
        /// stream: the microphone is already open here, and the level has already
        /// been computed for the silence check.
        public static string LevelFile = null;

        private static void PublishLevel(int peakInBuffer)
        {
            if (LevelFile == null) { return; }
            try
            {
                // 0..7, matching the eight level frames of the sayit mark.
                int level = 0;
                if (peakInBuffer > 0)
                {
                    double norm = peakInBuffer / 32767.0;
                    level = (int)Math.Floor(Math.Sqrt(norm) * 8.0);
                    if (level > 7) { level = 7; }
                }
                File.WriteAllText(LevelFile, level.ToString());
            }
            catch { /* the indicator is cosmetic; never fail a recording for it */ }
        }

        /// Capture until stopEvent is signalled or maxSeconds elapses.
        /// Writes a complete RIFF/WAVE file. Returns the number of sample frames.
        /// peakAmplitude reports the loudest absolute sample seen (0..32767) so the
        /// caller can detect a silent capture path.
        public static int CaptureToWav(string path, int deviceIndex, WaitHandle stopEvent,
                                       int maxSeconds, out int peakAmplitude)
        {
            peakAmplitude = 0;

            WAVEFORMATEX fmt = new WAVEFORMATEX();
            fmt.wFormatTag = WAVE_FORMAT_PCM;
            fmt.nChannels = (short)Channels;
            fmt.nSamplesPerSec = SampleRate;
            fmt.wBitsPerSample = (short)BitsPerSample;
            fmt.nBlockAlign = (short)(Channels * BitsPerSample / 8);
            fmt.nAvgBytesPerSec = SampleRate * fmt.nBlockAlign;
            fmt.cbSize = 0;

            int bufferBytes = (fmt.nAvgBytesPerSec * BufferMilliseconds) / 1000;
            bufferBytes -= bufferBytes % fmt.nBlockAlign;

            using (AutoResetEvent dataReady = new AutoResetEvent(false))
            {
                IntPtr hwi;
                // NOTE: WAVE_FORMAT_DIRECT is deliberately not passed - without it the
                // audio engine performs rate and channel conversion for us.
                int rc = waveInOpen(out hwi, deviceIndex, ref fmt, dataReady.SafeWaitHandle.DangerousGetHandle(),
                                    IntPtr.Zero, CALLBACK_EVENT);
                if (rc != MMSYSERR_NOERROR)
                {
                    throw new InvalidOperationException("waveInOpen failed with MMSYSERR " + rc);
                }

                int hdrSize = Marshal.SizeOf(typeof(WAVEHDR));
                IntPtr[] headers = new IntPtr[BufferCount];
                IntPtr[] buffers = new IntPtr[BufferCount];

                FileStream fs = null;
                int totalBytes = 0;

                try
                {
                    fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
                    WriteWavHeader(fs, 0, fmt.nSamplesPerSec, fmt.nChannels, fmt.wBitsPerSample);

                    for (int i = 0; i < BufferCount; i++)
                    {
                        buffers[i] = Marshal.AllocHGlobal(bufferBytes);
                        WAVEHDR hdr = new WAVEHDR();
                        hdr.lpData = buffers[i];
                        hdr.dwBufferLength = bufferBytes;
                        headers[i] = Marshal.AllocHGlobal(hdrSize);
                        Marshal.StructureToPtr(hdr, headers[i], false);

                        waveInPrepareHeader(hwi, headers[i], hdrSize);
                        waveInAddBuffer(hwi, headers[i], hdrSize);
                    }

                    waveInStart(hwi);

                    byte[] scratch = new byte[bufferBytes];
                    DateTime deadline = DateTime.UtcNow.AddSeconds(maxSeconds);
                    WaitHandle[] waits = new WaitHandle[] { stopEvent, dataReady };
                    bool stopping = false;

                    // A buffer that is drained but not handed back keeps WHDR_DONE
                    // and its byte count, and waveInReset clears neither. The
                    // post-stop drain below would otherwise write those buffers a
                    // second time, repeating the last word or two of every
                    // recording; this records the ones already accounted for.
                    bool[] drained = new bool[BufferCount];

                    // waveIn completes buffers in the order they were queued, and
                    // this loop hands each one straight back, so following the
                    // queue means following this cursor. Scanning by array index
                    // instead writes the two sides of the ring's wrap the wrong way
                    // round whenever more than one buffer completes between passes
                    // - buffer 7 before buffer 0 in the queue, but 0 before 7 in an
                    // index scan - which swaps 100 ms of audio inside the recording.
                    int next = 0;

                    while (true)
                    {
                        int signalled = WaitHandle.WaitAny(waits, 250);
                        if (signalled == 0) { stopping = true; }
                        if (DateTime.UtcNow > deadline) { stopping = true; }

                        // Drain every completed buffer, whether woken by data or by
                        // stop, in queue order and never more than one pass round.
                        for (int scanned = 0; scanned < BufferCount; scanned++)
                        {
                            WAVEHDR hdr = (WAVEHDR)Marshal.PtrToStructure(headers[next], typeof(WAVEHDR));
                            if ((hdr.dwFlags & WHDR_DONE) == 0) { break; }
                            if (hdr.dwBytesRecorded > 0)
                            {
                                Marshal.Copy(hdr.lpData, scratch, 0, hdr.dwBytesRecorded);
                                fs.Write(scratch, 0, hdr.dwBytesRecorded);
                                totalBytes += hdr.dwBytesRecorded;
                                TrackPeak(scratch, hdr.dwBytesRecorded, ref peakAmplitude);

                                int bufferPeak = 0;
                                TrackPeak(scratch, hdr.dwBytesRecorded, ref bufferPeak);
                                PublishLevel(bufferPeak);
                            }
                            if (stopping)
                            {
                                drained[next] = true;
                            }
                            else
                            {
                                waveInAddBuffer(hwi, headers[next], hdrSize);
                            }
                            next = (next + 1) % BufferCount;
                        }

                        if (stopping) { break; }
                    }

                    // waveInReset marks every pending buffer done; drain them too so the
                    // tail of the recording is not lost.
                    waveInStop(hwi);
                    waveInReset(hwi);

                    // Queue order again: the buffers still held by the driver start
                    // at the cursor, so the tail is written in the order it was
                    // captured rather than in array order.
                    for (int scanned = 0; scanned < BufferCount; scanned++)
                    {
                        int i = (next + scanned) % BufferCount;
                        if (drained[i]) { continue; }
                        WAVEHDR hdr = (WAVEHDR)Marshal.PtrToStructure(headers[i], typeof(WAVEHDR));
                        if ((hdr.dwFlags & WHDR_DONE) != 0 && hdr.dwBytesRecorded > 0)
                        {
                            Marshal.Copy(hdr.lpData, scratch, 0, hdr.dwBytesRecorded);
                            fs.Write(scratch, 0, hdr.dwBytesRecorded);
                            totalBytes += hdr.dwBytesRecorded;
                            TrackPeak(scratch, hdr.dwBytesRecorded, ref peakAmplitude);
                        }
                    }

                    fs.Flush();
                    fs.Seek(0, SeekOrigin.Begin);
                    WriteWavHeader(fs, totalBytes, fmt.nSamplesPerSec, fmt.nChannels, fmt.wBitsPerSample);
                    fs.Flush();
                }
                finally
                {
                    if (fs != null) { fs.Dispose(); }
                    for (int i = 0; i < BufferCount; i++)
                    {
                        if (headers[i] != IntPtr.Zero)
                        {
                            waveInUnprepareHeader(hwi, headers[i], hdrSize);
                            Marshal.FreeHGlobal(headers[i]);
                        }
                        if (buffers[i] != IntPtr.Zero) { Marshal.FreeHGlobal(buffers[i]); }
                    }
                    waveInClose(hwi);
                }

                return totalBytes / fmt.nBlockAlign;
            }
        }

        private static void TrackPeak(byte[] data, int count, ref int peak)
        {
            for (int i = 0; i + 1 < count; i += 2)
            {
                int sample = (short)(data[i] | (data[i + 1] << 8));
                if (sample < 0) { sample = -sample; }
                // -32768 has no positive counterpart; without this the reported
                // peak can exceed the 32767 the callers scale against.
                if (sample > 32767) { sample = 32767; }
                if (sample > peak) { peak = sample; }
            }
        }

        private static void WriteWavHeader(Stream s, int dataBytes, int rate, int channels, int bits)
        {
            BinaryWriter w = new BinaryWriter(s, Encoding.ASCII, true);
            int blockAlign = channels * bits / 8;
            w.Write(Encoding.ASCII.GetBytes("RIFF"));
            w.Write(36 + dataBytes);
            w.Write(Encoding.ASCII.GetBytes("WAVE"));
            w.Write(Encoding.ASCII.GetBytes("fmt "));
            w.Write(16);
            w.Write((short)WAVE_FORMAT_PCM);
            w.Write((short)channels);
            w.Write(rate);
            w.Write(rate * blockAlign);
            w.Write((short)blockAlign);
            w.Write((short)bits);
            w.Write(Encoding.ASCII.GetBytes("data"));
            w.Write(dataBytes);
            w.Flush();
        }
    }
}
