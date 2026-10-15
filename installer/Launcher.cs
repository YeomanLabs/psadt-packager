// PSADT Packager launcher: starts PsadtPackager.ps1 (next to this exe) in 64-bit Windows PowerShell 5.1 without a
// console window. A single file or folder dropped on the exe or its shortcut is auto-packaged (-InstallerPath); any
// other arguments are passed through unchanged. Built by Build-Installer.ps1 with the .NET Framework C# compiler.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("PSADT Packager")]
[assembly: AssemblyProduct("PSADT Packager")]
[assembly: AssemblyCompany("YeomanLabs")]
[assembly: AssemblyCopyright("YeomanLabs")]
[assembly: AssemblyVersion("__VERSION__.0")]
[assembly: AssemblyFileVersion("__VERSION__.0")]
[assembly: AssemblyInformationalVersion("__VERSION__")]

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "PsadtPackager.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("PsadtPackager.ps1 was not found next to the launcher:\n" + dir + "\n\nReinstall PSADT Packager.", "PSADT Packager", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        // Always the 64-bit Windows PowerShell: registry views, Program Files and the sandbox tooling all expect it.
        string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string system = (Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess) ? "Sysnative" : "System32";
        string powershell = Path.Combine(windows, system, @"WindowsPowerShell\v1.0\powershell.exe");

        var command = new StringBuilder("-NoProfile -STA -ExecutionPolicy Bypass -File " + Quote(script));
        if (args.Length == 1 && !args[0].StartsWith("-") && (File.Exists(args[0]) || Directory.Exists(args[0])))
        {
            command.Append(" -InstallerPath ").Append(Quote(Path.GetFullPath(args[0])));
        }
        else
        {
            foreach (string a in args) { command.Append(' ').Append(Quote(a)); }
        }

        var start = new ProcessStartInfo(powershell, command.ToString())
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = dir
        };

        // Started from a PowerShell 7 session, PSModulePath carries PowerShell 7's module folders (including the Store
        // build's own, under WindowsApps). Windows PowerShell then loads PowerShell 7's Microsoft.PowerShell.Security
        // at startup and every module import fails ("Error in TypeData ... The member AuditToString is already
        // present"). Give it the value a process started from Explorer gets: the machine value plus the user value.
        var paths = new List<string>();
        foreach (EnvironmentVariableTarget target in new[] { EnvironmentVariableTarget.Machine, EnvironmentVariableTarget.User })
        {
            string value = Environment.GetEnvironmentVariable("PSModulePath", target);
            if (!string.IsNullOrEmpty(value)) paths.Add(Environment.ExpandEnvironmentVariables(value));
        }
        if (paths.Count > 0) start.EnvironmentVariables["PSModulePath"] = string.Join(";", paths.ToArray());
        try
        {
            Process.Start(start);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show("Could not start Windows PowerShell:\n" + ex.Message, "PSADT Packager", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    // Quotes one argument the way CommandLineToArgvW reads it back.
    static string Quote(string s)
    {
        if (s.Length > 0 && s.IndexOfAny(new[] { ' ', '\t', '"' }) < 0) return s;
        var sb = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in s)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { sb.Append('\\', slashes * 2 + 1).Append('"'); }
            else { sb.Append('\\', slashes).Append(c); }
            slashes = 0;
        }
        sb.Append('\\', slashes * 2).Append('"');
        return sb.ToString();
    }
}
