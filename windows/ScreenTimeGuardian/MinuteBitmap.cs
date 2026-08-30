namespace ScreenTimeGuardian;

internal sealed class MinuteBitmap
{
    public const int MinuteCount = 1440;
    public const int ByteCount = 180;
    public byte[] Data { get; }
    public MinuteBitmap() : this(new byte[ByteCount]) { }
    public MinuteBitmap(byte[] data) { if (data.Length != ByteCount) throw new ArgumentException("Bitmap must be 180 bytes"); Data = data.ToArray(); }
    public bool this[int minute] => minute is >= 0 and < MinuteCount && (Data[minute / 8] & (1 << minute % 8)) != 0;
    public bool Mark(int minute) { if (minute is < 0 or >= MinuteCount) throw new ArgumentOutOfRangeException(nameof(minute)); var changed = !this[minute]; Data[minute / 8] |= (byte)(1 << minute % 8); return changed; }
    public void Union(MinuteBitmap other) { for (var i = 0; i < Data.Length; i++) Data[i] |= other.Data[i]; }
    public int Count() => Data.Sum(value => System.Numerics.BitOperations.PopCount(value));
    public string ToBase64() => Convert.ToBase64String(Data);
    public static MinuteBitmap FromBase64(string value) => new(Convert.FromBase64String(value));
}

