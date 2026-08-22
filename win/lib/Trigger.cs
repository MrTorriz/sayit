// Trigger.cs - global push-to-talk trigger via low-level input hooks.
//
// Compiled at runtime by Add-Type from sayit-trigger.ps1. C# 5 syntax only.
//
// Low-level hooks rather than Raw Input or RegisterHotKey:
//   - RegisterHotKey delivers press only, has no mouse-button surface, and so
//     cannot express hold-to-talk at all.
//   - Raw Input can observe buttons in the background but cannot suppress them,
//     so a thumb-button binding would also navigate the focused app back or
//     forward on every dictation.
//   - Low-level hooks give down and up for both keyboards and mouse X buttons,
//     and can swallow the event. That combination is unique to this API.
//
// Two hazards are handled here:
//   1. A hook that takes longer than LowLevelHooksTimeout (1000 ms by default)
//      is removed by the OS silently, with no way to detect it. The callback
//      therefore only sets a flag and returns; all work happens on the pump
//      thread outside the callback, and Reinstall() lets the owner re-arm
//      periodically.
//   2. Injected input must not re-trigger us. Filtering on the generic INJECTED
//      bit would also discard input synthesised by mouse vendor software, which
//      is a legitimate trigger source, so we match our own signature in
//      dwExtraInfo instead.

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Sayit
{
    public class Trigger
    {
        // Stamped on every event this process injects, so the hook can ignore
        // its own text injection without discarding vendor-remapped input.
        public const int InjectionSignature = 0x5A17;

        private const int WH_KEYBOARD_LL = 13;
        private const int WH_MOUSE_LL = 14;

        private const int WM_KEYDOWN = 0x0100;
        private const int WM_KEYUP = 0x0101;
        private const int WM_SYSKEYDOWN = 0x0104;
        private const int WM_SYSKEYUP = 0x0105;

        private const int WM_XBUTTONDOWN = 0x020B;
        private const int WM_XBUTTONUP = 0x020C;
        private const int WM_MBUTTONDOWN = 0x0207;
        private const int WM_MBUTTONUP = 0x0208;
        private const int WM_MOUSEMOVE = 0x0200;
        private const int WM_MOUSEWHEEL = 0x020A;
        private const int WM_MOUSEHWHEEL = 0x020E;

        [StructLayout(LayoutKind.Sequential)]
        private struct KBDLLHOOKSTRUCT
        {
            public int vkCode;
            public int scanCode;
            public int flags;
            public int time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSLLHOOKSTRUCT
        {
            public int x;
            public int y;
            public int mouseData;
            public int flags;
            public int time;
            public IntPtr dwExtraInfo;
        }

        private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr SetWindowsHookExW(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool UnhookWindowsHookEx(IntPtr hhk);
        [DllImport("user32.dll")]
        private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetModuleHandleW(string lpModuleName);

        /// One observed input transition.
        public class TriggerEvent
        {
            public string Kind;     // "key" or "mouse"
            public string Button;   // "XBUTTON1", "XBUTTON2", "MIDDLE", or a VK number
            public bool Down;
            public bool Injected;   // generic injected bit, for diagnostics
            public int Raw;         // vkCode, or HIWORD(mouseData)
        }

        // Delegates are held in static fields so the garbage collector cannot
        // move or collect them; a collected hook callback crashes the process
        // with ExecutionEngineException.
        private static HookProc _keyboardProc;
        private static HookProc _mouseProc;
        private static IntPtr _keyboardHook = IntPtr.Zero;
        private static IntPtr _mouseHook = IntPtr.Zero;

        private static readonly object _lock = new object();
        private static readonly Queue<TriggerEvent> _queue = new Queue<TriggerEvent>();

        // The button this instance reacts to, and whether to swallow it.
        private static string _boundButton = "XBUTTON2";
        private static int _boundVk = 0;
        private static bool _suppress = true;
        private static bool _probeMode = false;

        public static void Configure(string button, bool suppress, bool probeMode)
        {
            lock (_lock)
            {
                _boundButton = (button == null) ? "" : button.ToUpperInvariant();
                _suppress = suppress;
                _probeMode = probeMode;
                _boundVk = 0;
                int vk;
                if (_boundButton.StartsWith("VK") && int.TryParse(_boundButton.Substring(2), out vk))
                {
                    _boundVk = vk;
                }
            }
        }

        public static void Install()
        {
            lock (_lock)
            {
                IntPtr hMod = GetModuleHandleW(null);
                if (_keyboardHook == IntPtr.Zero)
                {
                    _keyboardProc = new HookProc(KeyboardCallback);
                    _keyboardHook = SetWindowsHookExW(WH_KEYBOARD_LL, _keyboardProc, hMod, 0);
                }
                if (_mouseHook == IntPtr.Zero)
                {
                    _mouseProc = new HookProc(MouseCallback);
                    _mouseHook = SetWindowsHookExW(WH_MOUSE_LL, _mouseProc, hMod, 0);
                }
            }
        }

        /// Re-arm after a silent removal. The OS gives no notification when it
        /// drops a slow hook, so callers should invoke this on a timer.
        public static void Reinstall()
        {
            lock (_lock)
            {
                if (_keyboardHook != IntPtr.Zero) { UnhookWindowsHookEx(_keyboardHook); _keyboardHook = IntPtr.Zero; }
                if (_mouseHook != IntPtr.Zero) { UnhookWindowsHookEx(_mouseHook); _mouseHook = IntPtr.Zero; }
            }
            Install();
        }

        public static void Uninstall()
        {
            lock (_lock)
            {
                if (_keyboardHook != IntPtr.Zero) { UnhookWindowsHookEx(_keyboardHook); _keyboardHook = IntPtr.Zero; }
                if (_mouseHook != IntPtr.Zero) { UnhookWindowsHookEx(_mouseHook); _mouseHook = IntPtr.Zero; }
            }
        }

        /// Drain observed events. Called from the pump thread, never from a hook.
        public static TriggerEvent[] Drain()
        {
            lock (_lock)
            {
                TriggerEvent[] items = _queue.ToArray();
                _queue.Clear();
                return items;
            }
        }

        private static void Enqueue(TriggerEvent e)
        {
            // Bounded so a runaway producer cannot exhaust memory.
            if (_queue.Count < 256) { _queue.Enqueue(e); }
        }

        private static IntPtr KeyboardCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                try
                {
                    KBDLLHOOKSTRUCT data = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                    if (data.dwExtraInfo.ToInt64() != InjectionSignature)
                    {
                        int msg = wParam.ToInt32();
                        bool down = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN);
                        bool up = (msg == WM_KEYUP || msg == WM_SYSKEYUP);
                        if (down || up)
                        {
                            TriggerEvent e = new TriggerEvent();
                            e.Kind = "key";
                            e.Button = "VK" + data.vkCode;
                            e.Down = down;
                            e.Injected = (data.flags & 0x10) != 0;
                            e.Raw = data.vkCode;

                            bool mine;
                            lock (_lock) { mine = (_boundVk != 0 && data.vkCode == _boundVk); }
                            if (_probeMode || mine)
                            {
                                lock (_lock) { Enqueue(e); }
                            }
                            if (mine && _suppress && !_probeMode)
                            {
                                return new IntPtr(1);
                            }
                        }
                    }
                }
                catch { /* a throwing hook would be removed by the OS */ }
            }
            return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        }

        private static IntPtr MouseCallback(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0)
            {
                int msg = wParam.ToInt32();
                // Mouse movement dominates this hook's traffic; reject it before
                // doing any marshalling so the 1000 ms budget is never at risk.
                // Probe mode reports every other mouse message so an unknown
                // button can be identified rather than guessed at.
                bool interesting =
                    msg == WM_XBUTTONDOWN || msg == WM_XBUTTONUP ||
                    msg == WM_MBUTTONDOWN || msg == WM_MBUTTONUP ||
                    (_probeMode && msg != WM_MOUSEMOVE && msg != WM_MOUSEWHEEL && msg != WM_MOUSEHWHEEL);

                if (interesting)
                {
                    try
                    {
                        MSLLHOOKSTRUCT data = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                        if (data.dwExtraInfo.ToInt64() != InjectionSignature)
                        {
                            bool down = (msg == WM_XBUTTONDOWN || msg == WM_MBUTTONDOWN);
                            string name;
                            int raw;
                            if (msg == WM_MBUTTONDOWN || msg == WM_MBUTTONUP)
                            {
                                name = "MIDDLE";
                                raw = 0;
                            }
                            else if (msg == WM_XBUTTONDOWN || msg == WM_XBUTTONUP)
                            {
                                // Which X button is in the high word of mouseData.
                                raw = (data.mouseData >> 16) & 0xFFFF;
                                name = (raw == 1) ? "XBUTTON1" : (raw == 2) ? "XBUTTON2" : ("XBUTTON" + raw);
                            }
                            else
                            {
                                // Probe mode only: report the message verbatim so an
                                // unrecognised button can be identified.
                                raw = data.mouseData;
                                name = "MSG_0x" + msg.ToString("X4");
                                down = false;
                            }

                            TriggerEvent e = new TriggerEvent();
                            e.Kind = "mouse";
                            e.Button = name;
                            e.Down = down;
                            e.Injected = (data.flags & 0x01) != 0;
                            e.Raw = raw;

                            bool mine;
                            lock (_lock) { mine = (name == _boundButton); }
                            if (_probeMode || mine)
                            {
                                lock (_lock) { Enqueue(e); }
                            }
                            if (mine && _suppress && !_probeMode)
                            {
                                return new IntPtr(1);
                            }
                        }
                    }
                    catch { }
                }
            }
            return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
        }
    }
}
