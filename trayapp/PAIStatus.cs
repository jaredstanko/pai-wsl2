using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows.Forms;

// PAI-Status — System tray app for PAI-WSL2
// Compiled at install time with csc.exe (ships with .NET Framework on every Windows 10/11).
// Equivalent of PAI-LIMA's Swift menu bar app.
//
// Features:
//   - Tray icon with green/red/yellow dot (running/stopped/transitioning)
//   - Start/Stop distro
//   - New PAI Session (opens Windows Terminal)
//   - Resume Session
//   - Open PAI Web portal
//   - Open a Terminal (plain shell)
//   - Launch at Login (Start Menu startup folder)
//   - Health Check (runs doctor.ps1)

class PAIStatus
{
    // Instance configuration — replaced by build.ps1 via sed for named instances
    private static string DistroName = "pai";
    private static string PortalUrl = "http://localhost:8080";
    private static string AppName = "PAI-Status";
    private static string RepoDir = "";  // Set at runtime from exe location

    private static NotifyIcon trayIcon;
    private static Timer pollTimer;
    private static string currentState = "Unknown";

    private static ToolStripMenuItem statusItem;
    private static ToolStripMenuItem startItem;
    private static ToolStripMenuItem stopItem;
    private static ToolStripMenuItem newSessionItem;
    private static ToolStripMenuItem resumeItem;
    private static ToolStripMenuItem portalItem;
    private static ToolStripMenuItem terminalItem;

    [STAThread]
    static void Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        // Resolve repo directory from exe location
        string exePath = System.Reflection.Assembly.GetExecutingAssembly().Location;
        string exeDir = Path.GetDirectoryName(exePath);
        // Exe lives in trayapp/build/ — repo root is two levels up
        RepoDir = Path.GetFullPath(Path.Combine(exeDir, "..", ".."));

        // Build tray icon
        trayIcon = new NotifyIcon();
        trayIcon.Text = AppName;
        trayIcon.Visible = true;
        trayIcon.DoubleClick += (s, e) => NewSession();

        // Context menu
        var menu = new ContextMenuStrip();

        statusItem = new ToolStripMenuItem("Distro: Checking...");
        statusItem.Enabled = false;
        menu.Items.Add(statusItem);

        menu.Items.Add(new ToolStripSeparator());

        startItem = new ToolStripMenuItem("Start Distro", null, (s, e) => StartDistro());
        menu.Items.Add(startItem);

        stopItem = new ToolStripMenuItem("Stop Distro", null, (s, e) => StopDistro());
        menu.Items.Add(stopItem);

        menu.Items.Add(new ToolStripSeparator());

        newSessionItem = new ToolStripMenuItem("New PAI Session", null, (s, e) => NewSession());
        newSessionItem.Font = new Font(newSessionItem.Font, FontStyle.Bold);
        menu.Items.Add(newSessionItem);

        // Active Sessions submenu (populated by RefreshSessions)
        resumeItem = new ToolStripMenuItem("Active Sessions");
        resumeItem.DropDownItems.Add(new ToolStripMenuItem("(checking...)")); // placeholder
        menu.Items.Add(resumeItem);

        menu.Items.Add(new ToolStripSeparator());

        portalItem = new ToolStripMenuItem("Open PAI Web", null, (s, e) => OpenPortal());
        menu.Items.Add(portalItem);

        terminalItem = new ToolStripMenuItem("Open a Terminal", null, (s, e) => OpenTerminal());
        menu.Items.Add(terminalItem);

        menu.Items.Add(new ToolStripSeparator());

        var healthItem = new ToolStripMenuItem("Health Check", null, (s, e) => RunHealthCheck());
        menu.Items.Add(healthItem);

        menu.Items.Add(new ToolStripSeparator());

        var loginItem = new ToolStripMenuItem("Launch at Login");
        loginItem.Checked = IsLaunchAtLoginEnabled();
        loginItem.Click += (s, e) =>
        {
            var item = (ToolStripMenuItem)s;
            item.Checked = !item.Checked;
            SetLaunchAtLogin(item.Checked);
        };
        menu.Items.Add(loginItem);

        menu.Items.Add(new ToolStripSeparator());

        var quitItem = new ToolStripMenuItem("Quit " + AppName, null, (s, e) =>
        {
            trayIcon.Visible = false;
            Application.Exit();
        });
        menu.Items.Add(quitItem);

        trayIcon.ContextMenuStrip = menu;

        // Initial check + 5-second polling
        CheckDistroStatus();
        pollTimer = new Timer();
        pollTimer.Interval = 5000;
        pollTimer.Tick += (s, e) => CheckDistroStatus();
        pollTimer.Start();

        Application.Run();
    }

    // ─── Status Polling ─────────────────────────────────────────────────────

    static void CheckDistroStatus()
    {
        string output = RunCommand("wsl.exe", "--list --verbose", 10000);
        string newState = "Stopped";

        if (output != null)
        {
            // Parse wsl --list --verbose output
            // Format: "  NAME    STATE    VERSION"
            foreach (string line in output.Split('\n'))
            {
                string trimmed = line.Trim();
                // Remove BOM/null chars that wsl.exe outputs (UTF-16)
                trimmed = Regex.Replace(trimmed, @"[\x00]", "");
                if (trimmed.StartsWith(DistroName + " ", StringComparison.OrdinalIgnoreCase) ||
                    trimmed.StartsWith("* " + DistroName + " ", StringComparison.OrdinalIgnoreCase))
                {
                    if (trimmed.Contains("Running"))
                        newState = "Running";
                    else if (trimmed.Contains("Stopped"))
                        newState = "Stopped";
                    else
                        newState = "Unknown";
                    break;
                }
            }

            // Distro not found in list at all
            if (newState == "Stopped" && !output.Contains(DistroName))
                newState = "Not Found";
        }

        if (newState != currentState)
        {
            currentState = newState;
            UpdateUI();
        }
        RefreshSessions();
    }

    static void UpdateUI()
    {
        bool running = currentState == "Running";
        bool transitioning = currentState == "Starting" || currentState == "Stopping";

        statusItem.Text = "Distro: " + currentState;
        startItem.Enabled = !running && !transitioning && currentState != "Not Found";
        stopItem.Enabled = running && !transitioning;
        newSessionItem.Enabled = running;
        resumeItem.Enabled = running;
        portalItem.Enabled = running;
        terminalItem.Enabled = running;

        // Update tray icon color
        trayIcon.Icon = CreateDotIcon(running ? Color.LimeGreen :
            transitioning ? Color.Gold :
            currentState == "Not Found" ? Color.Gray : Color.Red);
    }

    // ─── Tray Icon Drawing ──────────────────────────────────────────────────

    static Icon CreateDotIcon(Color dotColor)
    {
        Bitmap bmp = new Bitmap(16, 16);
        using (Graphics g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);

            // Computer icon (simple rectangle)
            using (Pen pen = new Pen(Color.White, 1.2f))
            {
                g.DrawRectangle(pen, 2, 1, 11, 8);  // screen
                g.DrawLine(pen, 5, 10, 10, 10);      // stand
            }

            // Status dot
            using (SolidBrush brush = new SolidBrush(dotColor))
            {
                g.FillEllipse(brush, 10, 10, 5, 5);
            }
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    // ─── Distro Control ─────────────────────────────────────────────────────

    static void StartDistro()
    {
        currentState = "Starting";
        UpdateUI();
        RunCommandAsync("wsl.exe", "-d " + DistroName + " -- echo started", () => CheckDistroStatus());
    }

    static void StopDistro()
    {
        currentState = "Stopping";
        UpdateUI();
        RunCommandAsync("wsl.exe", "--terminate " + DistroName, () => CheckDistroStatus());
    }

    // ─── Session Management ─────────────────────────────────────────────────

    static void NewSession()
    {
        // Try Windows Terminal first, fall back to wsl.exe directly
        if (HasWindowsTerminal())
        {
            Process.Start("wt.exe", "-w 0 new-tab --title \"PAI\" -- wsl.exe -d " + DistroName +
                " -- bash -lc \"bun ~/.claude/PAI/Tools/pai.ts\"");
        }
        else
        {
            Process.Start("wsl.exe", "-d " + DistroName + " -- bash -lc \"bun ~/.claude/PAI/Tools/pai.ts\"");
        }
    }

    static void ResumeSession()
    {
        if (HasWindowsTerminal())
        {
            Process.Start("wt.exe", "-w 0 new-tab --title \"PAI Resume\" -- wsl.exe -d " + DistroName +
                " -- bash -lc \"claude -r\"");
        }
        else
        {
            Process.Start("wsl.exe", "-d " + DistroName + " -- bash -lc \"claude -r\"");
        }
    }

    // ─── Active Sessions ────────────────────────────────────────────────────

    static void RefreshSessions()
    {
        if (resumeItem == null) return;

        resumeItem.DropDownItems.Clear();

        if (currentState != "Running")
        {
            var item = new ToolStripMenuItem("(distro not running)");
            item.Enabled = false;
            resumeItem.DropDownItems.Add(item);
            return;
        }

        // Query tmux sessions inside the distro
        string output = RunCommand("wsl.exe", "-d " + DistroName + " -- tmux list-sessions -F #{session_name} 2>/dev/null", 5000);

        if (string.IsNullOrEmpty(output))
        {
            var resumeClaudeItem = new ToolStripMenuItem("Resume Session...", null, (s, e) => ResumeSession());
            resumeItem.DropDownItems.Add(resumeClaudeItem);
            return;
        }

        // Add "Resume Session" at the top (uses claude -r picker)
        var pickerItem = new ToolStripMenuItem("Resume Session...", null, (s, e) => ResumeSession());
        pickerItem.Font = new Font(pickerItem.Font, FontStyle.Bold);
        resumeItem.DropDownItems.Add(pickerItem);
        resumeItem.DropDownItems.Add(new ToolStripSeparator());

        // List individual tmux sessions
        foreach (string line in output.Split(new[] { '\n', '\r' }, StringSplitOptions.RemoveEmptyEntries))
        {
            string sessionName = line.Trim();
            if (string.IsNullOrEmpty(sessionName)) continue;
            string name = sessionName; // capture for closure
            var sessionItem = new ToolStripMenuItem(name, null, (s, e) => AttachSession(name));
            resumeItem.DropDownItems.Add(sessionItem);
        }
    }

    static void AttachSession(string sessionName)
    {
        string cmd = "tmux attach-session -t " + sessionName;
        if (HasWindowsTerminal())
        {
            Process.Start("wt.exe", "-w 0 new-tab --title \"" + sessionName + "\" -- wsl.exe -d " + DistroName +
                " -- bash -lc \"" + cmd + "\"");
        }
        else
        {
            Process.Start("wsl.exe", "-d " + DistroName + " -- bash -lc \"" + cmd + "\"");
        }
    }

    static void OpenTerminal()
    {
        if (HasWindowsTerminal())
        {
            Process.Start("wt.exe", "-w 0 new-tab --title \"PAI Shell\" -- wsl.exe -d " + DistroName +
                " -- bash -l");
        }
        else
        {
            Process.Start("wsl.exe", "-d " + DistroName);
        }
    }

    static void OpenPortal()
    {
        Process.Start(PortalUrl);
    }

    static void RunHealthCheck()
    {
        string doctorScript = Path.Combine(RepoDir, "scripts", "doctor.ps1");
        if (File.Exists(doctorScript))
        {
            Process.Start("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File \"" + doctorScript + "\"");
        }
        else
        {
            MessageBox.Show("doctor.ps1 not found at:\n" + doctorScript, AppName, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    // ─── Launch at Login ────────────────────────────────────────────────────

    static string StartupShortcutPath()
    {
        string startup = Environment.GetFolderPath(Environment.SpecialFolder.Startup);
        return Path.Combine(startup, AppName + ".lnk");
    }

    static bool IsLaunchAtLoginEnabled()
    {
        return File.Exists(StartupShortcutPath());
    }

    static void SetLaunchAtLogin(bool enabled)
    {
        string shortcutPath = StartupShortcutPath();
        if (enabled)
        {
            // Create shortcut via COM (WScript.Shell)
            string exePath = System.Reflection.Assembly.GetExecutingAssembly().Location;
            dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
            dynamic shortcut = shell.CreateShortcut(shortcutPath);
            shortcut.TargetPath = exePath;
            shortcut.WorkingDirectory = Path.GetDirectoryName(exePath);
            shortcut.Description = "Launch " + AppName + " at login";
            shortcut.Save();
        }
        else
        {
            if (File.Exists(shortcutPath))
                File.Delete(shortcutPath);
        }
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    static bool HasWindowsTerminal()
    {
        try
        {
            string output = RunCommand("where.exe", "wt.exe", 3000);
            return output != null && output.Contains("wt.exe");
        }
        catch { return false; }
    }

    static string RunCommand(string exe, string args, int timeoutMs)
    {
        try
        {
            var psi = new ProcessStartInfo(exe, args)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            var proc = Process.Start(psi);
            string output = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit(timeoutMs);
            if (!proc.HasExited) proc.Kill();
            return output;
        }
        catch { return null; }
    }

    static void RunCommandAsync(string exe, string args, Action onComplete)
    {
        System.Threading.ThreadPool.QueueUserWorkItem(_ =>
        {
            RunCommand(exe, args, 120000);
            if (onComplete != null)
            {
                // Marshal back to UI thread
                if (trayIcon != null && trayIcon.ContextMenuStrip != null)
                    trayIcon.ContextMenuStrip.Invoke(onComplete);
            }
        });
    }
}
