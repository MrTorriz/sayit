// Injector.cs - deliver transcribed text to the focused window.
//
// Compiled at runtime by Add-Type from sayit-inject.ps1. C# 5 syntax only.
//
// Two delivery paths, chosen by length:
//
//   SendInput with KEYEVENTF_UNICODE - sends the character itself rather than a
//   scan code, so it is layout independent and correct for Swedish text by
//   construction. This is why the Linux side's clipboard workaround for non-ASCII
//   is unnecessary here. It is used for short text.
//
//   Clipboard plus Ctrl+V - used above ClipboardThreshold characters, because
//   SendInput is capped by the OS at roughly 5000 characters and loses its
//   atomicity guarantee whenever any other process has a low-level keyboard hook
//   installed. sayit itself installs one for the trigger, so that condition is
//   always true here.
//
// Everything this class injects is stamped with Trigger.InjectionSignature in
// dwExtraInfo so sayit's own trigger hook ignores it.
//
// UIPI: SendInput into a higher integrity level fails, and neither the return
// value nor GetLastError reports it. IsForegroundElevated lets the caller detect
// that case up front and fall back to leaving the text on the clipboard, which
// UIPI does not block.

using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace Sayit
{
    public class Injector
    {
        public const int ClipboardThreshold = 100;

        private const int INPUT_KEYBOARD = 1;
        private const uint KEYEVENTF_KEYUP = 0x0002;
        private const uint KEYEVENTF_UNICODE = 0x0004;
        private const ushort VK_CONTROL = 0x11;
        private const ushort VK_V = 0x56;   // raw VK, never a layout-resolved 'v'

        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT
        {
            public int type;
            public InputUnion u;
        }

        [StructLayout(LayoutKind.Explicit)]
        private struct InputUnion
        {
            [FieldOffset(0)] public KEYBDINPUT ki;
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public HARDWAREINPUT hi;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT
        {
            public ushort wVk;
            public ushort wScan;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MOUSEINPUT
        {
            public int dx, dy;
            public uint mouseData, dwFlags, time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct HARDWAREINPUT
        {
            public uint uMsg;
            public ushort wParamL, wParamH;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("user32.dll")]
        private static extern short GetAsyncKeyState(int vKey);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr info, int len, out int ret);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr h);

        private static IntPtr Sig { get { return new IntPtr(Trigger.InjectionSignature); } }

        // --- Unicode typing -------------------------------------------------

        /// Type text as Unicode key events. Returns false if any chunk was
        /// rejected outright. A UIPI block cannot be detected here.
        public static bool TypeUnicode(string text, int chunkSize, int chunkDelayMs)
        {
            if (string.IsNullOrEmpty(text)) { return true; }

            ReleaseHeldModifiers();

            int i = 0;
            bool ok = true;
            while (i < text.Length)
            {
                int take = Math.Min(chunkSize, text.Length - i);

                // Never split a surrogate pair across two SendInput calls: the
                // ordering guarantee only holds within one call.
                if (i + take < text.Length && char.IsHighSurrogate(text[i + take - 1])) { take--; }
                if (take <= 0) { take = 1; }

                string chunk = text.Substring(i, take);
                INPUT[] inputs = new INPUT[chunk.Length * 2];
                int n = 0;
                for (int c = 0; c < chunk.Length; c++)
                {
                    inputs[n++] = MakeUnicode(chunk[c], false);
                    inputs[n++] = MakeUnicode(chunk[c], true);
                }

                uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
                if (sent != (uint)inputs.Length) { ok = false; }

                i += take;
                if (i < text.Length && chunkDelayMs > 0) { Thread.Sleep(chunkDelayMs); }
            }
            return ok;
        }

        private static INPUT MakeUnicode(char ch, bool up)
        {
            INPUT input = new INPUT();
            input.type = INPUT_KEYBOARD;
            input.u.ki.wVk = 0;                 // must be 0 for KEYEVENTF_UNICODE
            input.u.ki.wScan = ch;
            input.u.ki.dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0);
            input.u.ki.time = 0;
            input.u.ki.dwExtraInfo = Sig;
            return input;
        }

        /// The push-to-talk button may still be physically held when injection
        /// starts; a held Ctrl or Alt would turn typed text into shortcuts.
        private static void ReleaseHeldModifiers()
        {
            int[] mods = new int[] { 0x11, 0x12, 0x10, 0x5B, 0x5C }; // Ctrl Alt Shift LWin RWin
            foreach (int vk in mods)
            {
                if ((GetAsyncKeyState(vk) & 0x8000) != 0)
                {
                    INPUT[] up = new INPUT[1];
                    up[0].type = INPUT_KEYBOARD;
                    up[0].u.ki.wVk = (ushort)vk;
                    up[0].u.ki.dwFlags = KEYEVENTF_KEYUP;
                    up[0].u.ki.dwExtraInfo = Sig;
                    SendInput(1, up, Marshal.SizeOf(typeof(INPUT)));
                }
            }
        }

        // --- Clipboard ------------------------------------------------------

        /// Put text on the clipboard, marked so it stays out of clipboard history
        /// and out of cloud sync. Returns false if the clipboard stayed locked.
        public static bool SetClipboard(string text, int attempts)
        {
            for (int i = 0; i < attempts; i++)
            {
                try
                {
                    DataObject data = new DataObject();
                    data.SetText(text, TextDataFormat.UnicodeText);

                    // Keep dictated text out of Win+V history and off the user's
                    // other devices. Without these every dictation is retained
                    // and synced, which a local-only tool must not do.
                    data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStreamOfZero());
                    data.SetData("CanIncludeInClipboardHistory", new MemoryStreamOfZero());
                    data.SetData("CanUploadToCloudClipboard", new MemoryStreamOfZero());

                    Clipboard.SetDataObject(data, true, 5, 50);
                    return true;
                }
                catch
                {
                    Thread.Sleep(30);
                }
            }
            return false;
        }

        public static string GetClipboardText()
        {
            try
            {
                if (Clipboard.ContainsText(TextDataFormat.UnicodeText))
                {
                    return Clipboard.GetText(TextDataFormat.UnicodeText);
                }
            }
            catch { }
            return null;
        }

        /// A one-byte zero payload; the clipboard-history opt-out formats are read
        /// as a serialized DWORD and any zero value means "no".
        private class MemoryStreamOfZero : System.IO.MemoryStream
        {
            public MemoryStreamOfZero() : base(new byte[] { 0, 0, 0, 0 }) { }
        }

        public static bool SendPasteChord()
        {
            ReleaseHeldModifiers();
            INPUT[] inputs = new INPUT[4];
            inputs[0] = MakeVk(VK_CONTROL, false);
            inputs[1] = MakeVk(VK_V, false);
            inputs[2] = MakeVk(VK_V, true);
            inputs[3] = MakeVk(VK_CONTROL, true);
            uint sent = SendInput(4, inputs, Marshal.SizeOf(typeof(INPUT)));
            return sent == 4;
        }

        private static INPUT MakeVk(ushort vk, bool up)
        {
            INPUT input = new INPUT();
            input.type = INPUT_KEYBOARD;
            input.u.ki.wVk = vk;
            input.u.ki.wScan = 0;
            input.u.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
            input.u.ki.dwExtraInfo = Sig;
            return input;
        }

        // --- Integrity level ------------------------------------------------

        /// True when the focused window belongs to a process at a higher integrity
        /// level than ours, in which case no synthetic input can reach it.
        public static bool IsForegroundElevated()
        {
            try
            {
                uint pid;
                GetWindowThreadProcessId(GetForegroundWindow(), out pid);
                if (pid == 0) { return false; }

                int other = GetIntegrityLevel(pid);
                int self = GetIntegrityLevel((uint)System.Diagnostics.Process.GetCurrentProcess().Id);
                if (other < 0 || self < 0) { return false; }
                return other > self;
            }
            catch
            {
                return false;
            }
        }

        private static int GetIntegrityLevel(uint pid)
        {
            // PROCESS_QUERY_LIMITED_INFORMATION, not PROCESS_QUERY_INFORMATION.
            // The wider right is refused across an integrity boundary, which is
            // exactly the case this function exists to detect: with 0x0400 the
            // open fails, the caller reads that as "not elevated", and the text is
            // handed to a SendInput that UIPI discards without a word.
            // OpenProcessToken accepts the limited right from Vista onwards.
            IntPtr proc = OpenProcess(0x1000, false, pid);
            if (proc == IntPtr.Zero) { return -1; }
            IntPtr token = IntPtr.Zero;
            IntPtr buffer = IntPtr.Zero;
            try
            {
                if (!OpenProcessToken(proc, 0x0008, out token)) { return -1; } // TOKEN_QUERY
                int need;
                GetTokenInformation(token, 25, IntPtr.Zero, 0, out need); // TokenIntegrityLevel
                if (need <= 0) { return -1; }
                buffer = Marshal.AllocHGlobal(need);
                if (!GetTokenInformation(token, 25, buffer, need, out need)) { return -1; }

                IntPtr sid = Marshal.ReadIntPtr(buffer);
                // Last sub-authority of the integrity SID is the RID.
                byte count = Marshal.ReadByte(sid, 1);
                return Marshal.ReadInt32(sid, 8 + 4 * (count - 1));
            }
            catch
            {
                return -1;
            }
            finally
            {
                if (buffer != IntPtr.Zero) { Marshal.FreeHGlobal(buffer); }
                if (token != IntPtr.Zero) { CloseHandle(token); }
                CloseHandle(proc);
            }
        }
    }
}
