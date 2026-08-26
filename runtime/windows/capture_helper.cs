using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Threading.Tasks;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

[ComImport]
[Guid("3628e81b-3cac-4c60-b7f4-23ce0e0c3356")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IGraphicsCaptureItemInterop
{
    [PreserveSig]
    int CreateForWindow(IntPtr window, ref Guid iid, out IntPtr result);

    [PreserveSig]
    int CreateForMonitor(IntPtr monitor, ref Guid iid, out IntPtr result);
}

public sealed class OCUWindowsCaptureResult
{
    public byte[] PngBytes { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
}

public static class OCUWindowsGraphicsCapture
{
    private const uint D3D11CreateDeviceBgraSupport = 0x20;
    private const uint D3D11SdkVersion = 7;

    [DllImport("d3d11.dll", SetLastError = true)]
    private static extern int D3D11CreateDevice(
        IntPtr adapter,
        int driverType,
        IntPtr software,
        uint flags,
        IntPtr featureLevels,
        uint featureLevelCount,
        uint sdkVersion,
        out IntPtr device,
        out uint featureLevel,
        out IntPtr immediateContext);

    [DllImport("d3d11.dll", SetLastError = true)]
    private static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);

    public static bool IsSupported()
    {
        return GraphicsCaptureSession.IsSupported();
    }

    public static OCUWindowsCaptureResult CaptureWindow(long hwnd, int timeoutMilliseconds)
    {
        // Windows PowerShell invokes us from an STA thread. Start the complete
        // WinRT/D3D lifecycle on the thread pool's MTA so async continuations do
        // not use apartment-bound capture interfaces created on the caller STA.
        return Task.Run(() => CaptureWindowAsync(new IntPtr(hwnd), timeoutMilliseconds)).GetAwaiter().GetResult();
    }

    private static async Task<OCUWindowsCaptureResult> CaptureWindowAsync(IntPtr hwnd, int timeoutMilliseconds)
    {
        if (!GraphicsCaptureSession.IsSupported())
        {
            throw new PlatformNotSupportedException("Windows.Graphics.Capture is not supported by this Windows build.");
        }

        var item = CreateCaptureItem(hwnd);
        var device = CreateDirect3DDevice();
        Direct3D11CaptureFramePool framePool = null;
        GraphicsCaptureSession session = null;
        Direct3D11CaptureFrame frame = null;
        try
        {
            framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(
                device,
                DirectXPixelFormat.B8G8R8A8UIntNormalized,
                1,
                item.Size);
            session = framePool.CreateCaptureSession(item);

            var frameCompletion = new TaskCompletionSource<Direct3D11CaptureFrame>();
            framePool.FrameArrived += (sender, args) =>
            {
                try
                {
                    var next = sender.TryGetNextFrame();
                    if (next != null && !frameCompletion.TrySetResult(next))
                    {
                        next.Dispose();
                    }
                }
                catch (Exception error)
                {
                    frameCompletion.TrySetException(error);
                }
            };

            session.StartCapture();
            var completed = await Task.WhenAny(frameCompletion.Task, Task.Delay(timeoutMilliseconds)).ConfigureAwait(false);
            if (completed != frameCompletion.Task)
            {
                throw new TimeoutException("Windows.Graphics.Capture did not produce a frame within " + timeoutMilliseconds + " ms.");
            }

            frame = await frameCompletion.Task.ConfigureAwait(false);
            using (var softwareBitmap = await SoftwareBitmap.CreateCopyFromSurfaceAsync(frame.Surface).AsTask())
            using (var stream = new InMemoryRandomAccessStream())
            {
                var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream).AsTask();
                encoder.SetSoftwareBitmap(softwareBitmap);
                await encoder.FlushAsync().AsTask();

                var bytes = new byte[checked((int)stream.Size)];
                using (var reader = new DataReader(stream.GetInputStreamAt(0)))
                {
                    await reader.LoadAsync((uint)stream.Size).AsTask();
                    reader.ReadBytes(bytes);
                }
                return new OCUWindowsCaptureResult
                {
                    PngBytes = bytes,
                    Width = frame.ContentSize.Width,
                    Height = frame.ContentSize.Height,
                };
            }
        }
        finally
        {
            if (frame != null) frame.Dispose();
            if (session != null) session.Dispose();
            if (framePool != null) framePool.Dispose();
            if (device != null) device.Dispose();
        }
    }

    private static GraphicsCaptureItem CreateCaptureItem(IntPtr hwnd)
    {
        var factory = WindowsRuntimeMarshal.GetActivationFactory(typeof(GraphicsCaptureItem));
        var interop = (IGraphicsCaptureItemInterop)factory;
        var iid = new Guid("79c3f95b-31f7-4ec2-a464-632ef5d30760");
        IntPtr itemPointer;
        var result = interop.CreateForWindow(hwnd, ref iid, out itemPointer);
        Marshal.ThrowExceptionForHR(result);
        try
        {
            return (GraphicsCaptureItem)Marshal.GetObjectForIUnknown(itemPointer);
        }
        finally
        {
            if (itemPointer != IntPtr.Zero) Marshal.Release(itemPointer);
        }
    }

    private static IDirect3DDevice CreateDirect3DDevice()
    {
        IntPtr device = IntPtr.Zero;
        IntPtr context = IntPtr.Zero;
        IntPtr dxgiDevice = IntPtr.Zero;
        IntPtr graphicsDevice = IntPtr.Zero;
        try
        {
            uint featureLevel;
            var result = D3D11CreateDevice(
                IntPtr.Zero,
                1,
                IntPtr.Zero,
                D3D11CreateDeviceBgraSupport,
                IntPtr.Zero,
                0,
                D3D11SdkVersion,
                out device,
                out featureLevel,
                out context);
            if (result < 0)
            {
                result = D3D11CreateDevice(
                    IntPtr.Zero,
                    5,
                    IntPtr.Zero,
                    D3D11CreateDeviceBgraSupport,
                    IntPtr.Zero,
                    0,
                    D3D11SdkVersion,
                    out device,
                    out featureLevel,
                    out context);
            }
            Marshal.ThrowExceptionForHR(result);

            var iidDxgiDevice = new Guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
            result = Marshal.QueryInterface(device, ref iidDxgiDevice, out dxgiDevice);
            Marshal.ThrowExceptionForHR(result);
            result = CreateDirect3D11DeviceFromDXGIDevice(dxgiDevice, out graphicsDevice);
            Marshal.ThrowExceptionForHR(result);
            return (IDirect3DDevice)Marshal.GetObjectForIUnknown(graphicsDevice);
        }
        finally
        {
            if (graphicsDevice != IntPtr.Zero) Marshal.Release(graphicsDevice);
            if (dxgiDevice != IntPtr.Zero) Marshal.Release(dxgiDevice);
            if (context != IntPtr.Zero) Marshal.Release(context);
            if (device != IntPtr.Zero) Marshal.Release(device);
        }
    }
}
