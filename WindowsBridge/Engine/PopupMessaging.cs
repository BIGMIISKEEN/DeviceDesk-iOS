// Runs on the target through the existing WinRM worker; no UI is created in session 0.
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace DeviceDesk {
    public static class PopupMessaging {
        [StructLayout(LayoutKind.Sequential)]
        private struct SessionInfo { public int SessionId; public IntPtr StationName; public int State; }
        [DllImport("wtsapi32.dll", EntryPoint="WTSEnumerateSessionsW", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool Enumerate(IntPtr server, int reserved, int version, out IntPtr sessions, out int count);
        [DllImport("wtsapi32.dll", EntryPoint="WTSQuerySessionInformationW", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool Query(IntPtr server, int sessionId, int infoClass, out IntPtr buffer, out int bytes);
        [DllImport("wtsapi32.dll")]
        private static extern void WTSFreeMemory(IntPtr buffer);
        [DllImport("wtsapi32.dll", EntryPoint="WTSSendMessageW", CharSet=CharSet.Unicode, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SendNative(IntPtr server, int sessionId, string title, int titleBytes, string message, int messageBytes, uint style, uint timeout, out uint response, [MarshalAs(UnmanagedType.Bool)] bool wait);

        public static void Validate(string title, string message, int seconds) {
            if (String.IsNullOrWhiteSpace(title) || title.Length > 100 || title.IndexOf('\0') >= 0) throw new ArgumentException("Enter a title of 1 to 100 characters.");
            if (String.IsNullOrWhiteSpace(message) || message.Length > 2000 || message.IndexOf('\0') >= 0) throw new ArgumentException("Enter a message of 1 to 2,000 characters.");
            if (seconds < 10 || seconds > 300) throw new ArgumentException("Popup duration must be 10 to 300 seconds.");
        }
        private static string ReadUser(int sessionId) {
            IntPtr buffer=IntPtr.Zero; int bytes;
            try { if (!Query(IntPtr.Zero,sessionId,5,out buffer,out bytes)) throw new Win32Exception(Marshal.GetLastWin32Error()); return buffer == IntPtr.Zero ? "" : Marshal.PtrToStringUni(buffer); }
            finally { if (buffer != IntPtr.Zero) WTSFreeMemory(buffer); }
        }
        public static string Send(string title, string message, int seconds, string senderAccount) {
            Validate(title,message,seconds);
            string body=message+"\r\n\r\nSent by IT support: "+senderAccount;
            IntPtr memory=IntPtr.Zero; int total;
            if (!Enumerate(IntPtr.Zero,0,1,out memory,out total)) throw new Win32Exception(Marshal.GetLastWin32Error());
            int accepted=0, active=0; var outcomes=new List<string>();
            try {
                int size=Marshal.SizeOf(typeof(SessionInfo));
                for (int i=0;i<total;i++) {
                    SessionInfo info=(SessionInfo)Marshal.PtrToStructure(IntPtr.Add(memory,i*size),typeof(SessionInfo));
                    if (info.SessionId <= 0 || info.State != 0) continue; // WTSActive; never session 0 or disconnected sessions.
                    try {
                        string user=ReadUser(info.SessionId);
                        if (String.IsNullOrWhiteSpace(user)) continue;
                        active++;
                        uint response;
                        bool ok=SendNative(IntPtr.Zero,info.SessionId,title,Encoding.Unicode.GetByteCount(title),body,Encoding.Unicode.GetByteCount(body),0x40,(uint)seconds,out response,false);
                        if (ok) { accepted++; outcomes.Add("Submitted to "+user+" (session "+info.SessionId+")."); }
                        else { outcomes.Add("Session "+info.SessionId+": "+new Win32Exception(Marshal.GetLastWin32Error()).Message); }
                    } catch (Exception ex) { outcomes.Add("Session "+info.SessionId+": "+ex.Message); }
                }
            } finally { if (memory != IntPtr.Zero) WTSFreeMemory(memory); }
            if (accepted == 0) {
                if (active == 0 && outcomes.Count == 0) return "No active signed-in user session was found. No popup was sent.";
                throw new InvalidOperationException("No popup was submitted.\r\n"+String.Join("\r\n",outcomes));
            }
            return "Popup submitted to "+accepted+" active session(s). This does not confirm that the user read it.\r\n"+String.Join("\r\n",outcomes);
        }
    }
}
