using System.Runtime.InteropServices;
using System.Text;

namespace ScreenTimeGuardian;

internal static class CredentialStore
{
    private const int Generic = 1, LocalMachine = 2;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential { public uint Flags; public uint Type; public string TargetName; public string? Comment; public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten; public uint CredentialBlobSize; public IntPtr CredentialBlob; public uint Persist; public uint AttributeCount; public IntPtr Attributes; public string? TargetAlias; public string? UserName; }
    [DllImport("advapi32", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool WriteNative(ref Credential credential, uint flags);
    [DllImport("advapi32", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool ReadNative(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool DeleteNative(string target, uint type, uint flags);
    [DllImport("advapi32", EntryPoint = "CredFree", SetLastError = true)] private static extern void FreeNative(IntPtr credential);
    public static void Write(string target, string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value); var pointer = Marshal.AllocCoTaskMem(bytes.Length);
        try { Marshal.Copy(bytes, 0, pointer, bytes.Length); var credential = new Credential { Type = Generic, TargetName = target, CredentialBlobSize = (uint)bytes.Length, CredentialBlob = pointer, Persist = LocalMachine, UserName = Environment.UserName }; if (!WriteNative(ref credential, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
        finally { Marshal.Copy(new byte[bytes.Length], 0, pointer, bytes.Length); Marshal.FreeCoTaskMem(pointer); }
    }
    public static string Read(string target)
    {
        if (!ReadNative(target, Generic, 0, out var pointer)) return "";
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(pointer);
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            var utf8 = Encoding.UTF8.GetString(bytes);
            return utf8.Contains('\0') ? Encoding.Unicode.GetString(bytes).TrimEnd('\0') : utf8;
        }
        finally { FreeNative(pointer); }
    }
    public static void Delete(string target) => DeleteNative(target, Generic, 0);
}
