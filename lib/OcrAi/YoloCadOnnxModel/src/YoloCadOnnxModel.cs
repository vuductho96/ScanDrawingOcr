using System.Reflection;
using System.Security.Cryptography;

namespace RapidOcrPro.Ai;

public static class YoloCadOnnxModel
{
    private const string ResourceName = "RapidOcrPro.Ai.Models.best.onnx";
    private const string FileName = "best.onnx";

    public static string GetModelPath(string appRoot)
    {
        if (string.IsNullOrWhiteSpace(appRoot))
        {
            appRoot = AppContext.BaseDirectory;
        }

        var modelDir = Path.Combine(appRoot, "lib", "OcrAi", "YoloCadOnnxModel", "cache");
        Directory.CreateDirectory(modelDir);

        var modelPath = Path.Combine(modelDir, FileName);
        using var stream = OpenModelStream();
        WriteIfChanged(stream, modelPath);
        return modelPath;
    }

    public static string GetModelSha256()
    {
        using var stream = OpenModelStream();
        using var sha = SHA256.Create();
        var hash = sha.ComputeHash(stream);
        return Convert.ToHexString(hash);
    }

    private static Stream OpenModelStream()
    {
        var assembly = Assembly.GetExecutingAssembly();
        var stream = assembly.GetManifestResourceStream(ResourceName);
        if (stream is null)
        {
            throw new FileNotFoundException($"Embedded YOLO model resource not found: {ResourceName}");
        }

        return stream;
    }

    private static void WriteIfChanged(Stream source, string destinationPath)
    {
        if (File.Exists(destinationPath))
        {
            using var existing = File.OpenRead(destinationPath);
            if (StreamsEqual(source, existing))
            {
                return;
            }

            source.Position = 0;
        }

        var tempPath = destinationPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var output = File.Create(tempPath))
            {
                source.CopyTo(output);
            }

            if (File.Exists(destinationPath))
            {
                File.Replace(tempPath, destinationPath, null);
            }
            else
            {
                File.Move(tempPath, destinationPath);
            }
        }
        finally
        {
            if (File.Exists(tempPath))
            {
                File.Delete(tempPath);
            }
        }
    }

    private static bool StreamsEqual(Stream left, Stream right)
    {
        if (left.Length != right.Length)
        {
            left.Position = 0;
            return false;
        }

        left.Position = 0;
        right.Position = 0;

        var leftBuffer = new byte[1024 * 128];
        var rightBuffer = new byte[1024 * 128];

        while (true)
        {
            var leftRead = left.Read(leftBuffer, 0, leftBuffer.Length);
            var rightRead = right.Read(rightBuffer, 0, rightBuffer.Length);
            if (leftRead != rightRead)
            {
                left.Position = 0;
                return false;
            }

            if (leftRead == 0)
            {
                left.Position = 0;
                return true;
            }

            for (var i = 0; i < leftRead; i++)
            {
                if (leftBuffer[i] != rightBuffer[i])
                {
                    left.Position = 0;
                    return false;
                }
            }
        }
    }
}
