// RawInput.cs - device-level input observation for the push-to-talk trigger.
//
// Compiled at runtime by Add-Type. C# 5 syntax only.
//
// Why this exists alongside Trigger.cs: a low-level mouse hook only sees the
// messages Windows synthesises for a *mouse*. Several pointing devices - notably
// Logitech mice paired over Bluetooth LE and driven by the in-box HID driver -
// report their thumb buttons as HID Consumer Control usages (AC Back, AC Forward)
// rather than as mouse buttons. Windows turns those into WM_APPCOMMAND, which is
// delivered to the foreground window and is not visible to WH_MOUSE_LL at all.
//
// Raw Input observes the HID usages themselves, so it sees those buttons. The
// trade-off is that Raw Input cannot suppress an event; a button observed only
// this way will still perform its normal action.
//
// RIDEV_INPUTSINK requires a target window, so a message-only window is created
// and pumped by the caller.

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Sayit
{
    public class RawInput
    {
        private const int RIDEV_INPUTSINK = 0x00000100;
        private const int RID_INPUT = 0x10000003;
        private const int RIM_TYPEMOUSE = 0;
        private const int RIM_TYPEHID = 2;
        private const int WM_INPUT = 0x00FF;

        private const ushort USAGE_PAGE_GENERIC = 0x01;
        private const ushort USAGE_PAGE_CONSUMER = 0x0C;
        private const ushort USAGE_MOUSE = 0x02;
        private const ushort USAGE_CONSUMER_CONTROL = 0x01;

        private const ushort RI_MOUSE_BUTTON_4_DOWN = 0x0040;
        private const ushort RI_MOUSE_BUTTON_4_UP = 0x0080;
        private const ushort RI_MOUSE_BUTTON_5_DOWN = 0x0100;
        private const ushort RI_MOUSE_BUTTON_5_UP = 0x0200;

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWINPUTDEVICE
        {
            public ushort usUsagePage;
            public ushort usUsage;
            public int dwFlags;
            public IntPtr hwndTarget;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct RAWINPUTHEADER
        {
            public int dwType;
            public int dwSize;
            public IntPtr hDevice;
            public IntPtr wParam;
        }

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] devices, int num, int size);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern int GetRawInputData(IntPtr hRawInput, int cmd, IntPtr data, ref int size, int headerSize);

        public class RawEvent
        {
            public string Source;   // "mouse" or "hid"
            public string Button;   // MOUSE4 / MOUSE5, or a consumer usage in hex
            public bool Down;
            public string DeviceId; // hDevice as hex, so two mice can be told apart
            public string RawBytes; // hex payload, for identifying unknown reports
        }

        private static readonly object _lock = new object();
        private static readonly Queue<RawEvent> _queue = new Queue<RawEvent>();
        private static bool _probeMode = false;

        public static void Register(IntPtr hwnd, bool probeMode)
        {
            _probeMode = probeMode;
            RAWINPUTDEVICE[] rid = new RAWINPUTDEVICE[2];
            rid[0].usUsagePage = USAGE_PAGE_GENERIC;
            rid[0].usUsage = USAGE_MOUSE;
            rid[0].dwFlags = RIDEV_INPUTSINK;
            rid[0].hwndTarget = hwnd;
            rid[1].usUsagePage = USAGE_PAGE_CONSUMER;
            rid[1].usUsage = USAGE_CONSUMER_CONTROL;
            rid[1].dwFlags = RIDEV_INPUTSINK;
            rid[1].hwndTarget = hwnd;

            if (!RegisterRawInputDevices(rid, rid.Length, Marshal.SizeOf(typeof(RAWINPUTDEVICE))))
            {
                throw new InvalidOperationException(
                    "RegisterRawInputDevices failed: " + Marshal.GetLastWin32Error());
            }
        }

        /// Handle one WM_INPUT. Safe to call from a window procedure.
        public static void Process(IntPtr lParam)
        {
            int size = 0;
            if (GetRawInputData(lParam, RID_INPUT, IntPtr.Zero, ref size, Marshal.SizeOf(typeof(RAWINPUTHEADER))) != 0)
            {
                return;
            }
            if (size <= 0) { return; }

            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                int got = GetRawInputData(lParam, RID_INPUT, buffer, ref size,
                                          Marshal.SizeOf(typeof(RAWINPUTHEADER)));
                if (got != size) { return; }

                RAWINPUTHEADER header = (RAWINPUTHEADER)Marshal.PtrToStructure(buffer, typeof(RAWINPUTHEADER));
                int headerSize = Marshal.SizeOf(typeof(RAWINPUTHEADER));

                if (header.dwType == RIM_TYPEMOUSE)
                {
                    // RAWMOUSE: usFlags(2) pad(2) ulButtons(4) where the low word is
                    // usButtonFlags and the high word usButtonData.
                    ushort buttonFlags = (ushort)Marshal.ReadInt16(buffer, headerSize + 4);
                    EmitMouse(buttonFlags, header.hDevice);
                }
                else if (header.dwType == RIM_TYPEHID)
                {
                    int sizeHid = Marshal.ReadInt32(buffer, headerSize);
                    int count = Marshal.ReadInt32(buffer, headerSize + 4);
                    int offset = headerSize + 8;

                    for (int i = 0; i < count && sizeHid > 0; i++)
                    {
                        byte[] report = new byte[sizeHid];
                        Marshal.Copy(new IntPtr(buffer.ToInt64() + offset + i * sizeHid), report, 0, sizeHid);
                        EmitHid(report, header.hDevice);
                    }
                }
            }
            catch { }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        private static void EmitMouse(ushort flags, IntPtr device)
        {
            if ((flags & RI_MOUSE_BUTTON_4_DOWN) != 0) { Enqueue("mouse", "MOUSE4", true, device, null); }
            if ((flags & RI_MOUSE_BUTTON_4_UP) != 0) { Enqueue("mouse", "MOUSE4", false, device, null); }
            if ((flags & RI_MOUSE_BUTTON_5_DOWN) != 0) { Enqueue("mouse", "MOUSE5", true, device, null); }
            if ((flags & RI_MOUSE_BUTTON_5_UP) != 0) { Enqueue("mouse", "MOUSE5", false, device, null); }

            // Probe mode also reports the ordinary buttons, so an empty log can be
            // told apart from a raw-input pipeline that is not delivering at all.
            if (_probeMode)
            {
                if ((flags & 0x0001) != 0) { Enqueue("mouse", "LEFT", true, device, null); }
                if ((flags & 0x0002) != 0) { Enqueue("mouse", "LEFT", false, device, null); }
                if ((flags & 0x0004) != 0) { Enqueue("mouse", "RIGHT", true, device, null); }
                if ((flags & 0x0008) != 0) { Enqueue("mouse", "RIGHT", false, device, null); }
                if ((flags & 0x0010) != 0) { Enqueue("mouse", "MIDDLE", true, device, null); }
                if ((flags & 0x0020) != 0) { Enqueue("mouse", "MIDDLE", false, device, null); }
            }
        }

        private static void EmitHid(byte[] report, IntPtr device)
        {
            // Consumer-control reports are small: a report id followed by a usage
            // code, and an all-zero payload means release. The exact layout is
            // device specific, which is why probe mode reports the raw bytes.
            bool anySet = false;
            for (int i = 1; i < report.Length; i++)
            {
                if (report[i] != 0) { anySet = true; break; }
            }

            string hex = BitConverter.ToString(report).Replace("-", " ");
            string usage = "HID";
            if (report.Length >= 3)
            {
                int code = report[1] | (report[2] << 8);
                if (code != 0) { usage = "USAGE_0x" + code.ToString("X4"); }
            }

            if (_probeMode || anySet)
            {
                Enqueue("hid", usage, anySet, device, hex);
            }
        }

        private static void Enqueue(string source, string button, bool down, IntPtr device, string hex)
        {
            RawEvent e = new RawEvent();
            e.Source = source;
            e.Button = button;
            e.Down = down;
            e.DeviceId = "0x" + device.ToInt64().ToString("X");
            e.RawBytes = hex;
            lock (_lock)
            {
                if (_queue.Count < 256) { _queue.Enqueue(e); }
            }
        }

        public static RawEvent[] Drain()
        {
            lock (_lock)
            {
                RawEvent[] items = _queue.ToArray();
                _queue.Clear();
                return items;
            }
        }
    }

    /// Message-only window that forwards WM_INPUT into RawInput.Process.
    public class RawInputWindow : System.Windows.Forms.NativeWindow
    {
        private const int WM_INPUT = 0x00FF;

        public RawInputWindow()
        {
            System.Windows.Forms.CreateParams cp = new System.Windows.Forms.CreateParams();
            cp.Caption = "sayit-rawinput";
            // HWND_MESSAGE. Microsoft's current Raw Input sample pairs a
            // message-only window with RIDEV_INPUTSINK, contrary to older folklore.
            cp.Parent = new IntPtr(-3);
            CreateHandle(cp);
        }

        protected override void WndProc(ref System.Windows.Forms.Message m)
        {
            if (m.Msg == WM_INPUT)
            {
                RawInput.Process(m.LParam);
            }
            base.WndProc(ref m);
        }
    }
}
