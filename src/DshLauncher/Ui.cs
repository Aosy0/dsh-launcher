using System.IO;
using System.Threading;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Drawing = System.Drawing;
using WinForms = System.Windows.Forms;

namespace DshLauncher.Ui;

internal static class Theme
{
    public static readonly SolidColorBrush Page = Brush(0x14, 0x14, 0x15);
    public static readonly SolidColorBrush Deep = Brush(0x0f, 0x0f, 0x10);
    public static readonly SolidColorBrush Card = Brush(0x19, 0x19, 0x1b);
    public static readonly SolidColorBrush Raised = Brush(0x23, 0x23, 0x25);
    public static readonly SolidColorBrush Text = Brush(0xed, 0xed, 0xed);
    public static readonly SolidColorBrush Secondary = Brush(0xa1, 0xa1, 0xa6);
    public static readonly SolidColorBrush Muted = Brush(0x85, 0x85, 0x8b);
    public static readonly SolidColorBrush Line = Brush(0xed, 0xed, 0xed, 0x14);
    public static readonly SolidColorBrush Line2 = Brush(0xed, 0xed, 0xed, 0x24);
    public static readonly SolidColorBrush Positive = Brush(0x4c, 0xc3, 0x8a);
    public static readonly SolidColorBrush Attention = Brush(0xd9, 0xa4, 0x41);
    public static readonly SolidColorBrush Off = Brush(0x5a, 0x5a, 0x60);
    public static readonly SolidColorBrush Danger = Brush(0xc9, 0xa8, 0xa8);
    public static readonly SolidColorBrush Ink = Brush(0x14, 0x14, 0x15);

    public static readonly FontFamily Sans = new("Segoe UI Variable Text, Segoe UI, Yu Gothic UI, Meiryo");
    public static readonly FontFamily Mono = new("Cascadia Mono, Consolas, monospace");

    private static SolidColorBrush Brush(byte r, byte g, byte b, byte a = 255)
    {
        var brush = new SolidColorBrush(Color.FromArgb(a, r, g, b));
        brush.Freeze();
        return brush;
    }
}

internal static class UiKit
{
    public static TextBlock Text(string value, double size, Brush color, FontWeight? weight = null, FontFamily? family = null)
    {
        var block = new TextBlock
        {
            Text = value,
            FontSize = size,
            Foreground = color,
            FontFamily = family ?? Theme.Sans,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        if (weight is not null) block.FontWeight = weight.Value;
        return block;
    }

    public static Border Surface(UIElement child, double radius, Brush? background = null, Brush? border = null, Thickness? padding = null)
    {
        return new Border
        {
            Child = child,
            CornerRadius = new CornerRadius(radius),
            Background = background ?? Theme.Card,
            BorderBrush = border ?? Theme.Line,
            BorderThickness = new Thickness(1),
            Padding = padding ?? new Thickness(0),
        };
    }

    public static Button Button(string label, bool primary, Action click, double height = 28, double fontSize = 11.5)
    {
        var background = primary ? Theme.Text : Theme.Card;
        var borderBrush = primary ? Theme.Text : Theme.Line2;
        var button = new Button
        {
            Content = label,
            Height = height,
            FontSize = fontSize,
            FontFamily = Theme.Sans,
            FontWeight = primary ? FontWeights.Medium : FontWeights.Normal,
            Foreground = primary ? Theme.Ink : Theme.Text,
            Background = background,
            BorderBrush = borderBrush,
            BorderThickness = new Thickness(1),
            Padding = new Thickness(14, 0, 14, 0),
            MinWidth = 64,
            Cursor = Cursors.Hand,
            VerticalAlignment = VerticalAlignment.Center,
            Focusable = true,
            Template = ButtonTemplate(background, borderBrush),
        };
        button.Click += (_, _) => click();
        return button;
    }

    public static Border Selectable(string text, double size, Brush color, FontFamily? family = null, bool wrap = true)
    {
        var box = new TextBox
        {
            Text = text,
            FontSize = size,
            Foreground = color,
            FontFamily = family ?? Theme.Sans,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            IsReadOnly = true,
            IsReadOnlyCaretVisible = false,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            AcceptsReturn = true,
            Padding = new Thickness(0),
            Margin = new Thickness(0),
            Cursor = Cursors.IBeam,
        };
        return new Border { Child = box };
    }

    private static ControlTemplate ButtonTemplate(Brush background, Brush borderBrush)
    {
        var border = new FrameworkElementFactory(typeof(Border), "PART_Border");
        border.SetValue(Border.BackgroundProperty, background);
        border.SetValue(Border.BorderBrushProperty, borderBrush);
        border.SetValue(Border.BorderThicknessProperty, new Thickness(1));
        border.SetValue(Border.CornerRadiusProperty, new CornerRadius(6));
        border.SetValue(Border.SnapsToDevicePixelsProperty, true);
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(FrameworkElement.HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(FrameworkElement.VerticalAlignmentProperty, VerticalAlignment.Center);
        border.AppendChild(presenter);

        var template = new ControlTemplate(typeof(System.Windows.Controls.Button)) { VisualTree = border };
        var hover = new Trigger { Property = UIElement.IsMouseOverProperty, Value = true };
        hover.Setters.Add(new Setter(UIElement.OpacityProperty, 0.86, "PART_Border"));
        template.Triggers.Add(hover);
        var pressed = new Trigger { Property = System.Windows.Controls.Primitives.ButtonBase.IsPressedProperty, Value = true };
        pressed.Setters.Add(new Setter(UIElement.OpacityProperty, 0.72, "PART_Border"));
        template.Triggers.Add(pressed);
        return template;
    }

    public static Border Quiet(string label, Action click, double fontSize = 11)
    {
        var text = Text(label, fontSize, Theme.Muted);
        var border = new Border { Child = text, Padding = new Thickness(2, 0, 2, 0), Cursor = Cursors.Hand };
        border.MouseLeftButtonUp += (_, e) => { e.Handled = true; click(); };
        border.MouseEnter += (_, _) => text.Foreground = Theme.Text;
        border.MouseLeave += (_, _) => text.Foreground = Theme.Muted;
        return border;
    }

    public static Ellipse Lamp(MachineState state)
    {
        var brush = state switch
        {
            MachineState.Running => Theme.Positive,
            MachineState.NeedsSetup => Theme.Attention,
            MachineState.Unreachable => Theme.Attention,
            MachineState.Starting => Theme.Attention,
            _ => Theme.Off,
        };
        return new Ellipse { Width = 7, Height = 7, Fill = brush, VerticalAlignment = VerticalAlignment.Center };
    }

    /// <summary>Small indeterminate bar: motion that explains an ongoing operation.</summary>
    public static Canvas LoadingBar(double width = 56)
    {
        var canvas = new Canvas { Width = width, Height = 3, ClipToBounds = true, VerticalAlignment = VerticalAlignment.Center };
        var track = new Border { Width = width, Height = 3, CornerRadius = new CornerRadius(2), Background = Theme.Line };
        var bar = new System.Windows.Shapes.Rectangle
        {
            Width = Math.Max(14, width * 0.4),
            Height = 3,
            RadiusX = 1.5,
            RadiusY = 1.5,
            Fill = Theme.Secondary,
        };
        Canvas.SetLeft(bar, -width);
        canvas.Children.Add(track);
        canvas.Children.Add(bar);
        var animation = new System.Windows.Media.Animation.DoubleAnimation
        {
            From = -width,
            To = width,
            Duration = TimeSpan.FromSeconds(1.1),
            RepeatBehavior = System.Windows.Media.Animation.RepeatBehavior.Forever,
        };
        bar.BeginAnimation(Canvas.LeftProperty, animation);
        return canvas;
    }
}

/// <summary>Programmatic WPF application: one list window plus a tray icon.</summary>
internal sealed class DshApplication : Application
{
    private readonly string? _configPath;
    private MainWindow? _window;
    private TrayIcon? _tray;

    public DshApplication(string? configPath = null)
    {
        _configPath = configPath;
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
    }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var config = LauncherConfig.Load(_configPath);
        _window = new MainWindow(config, _configPath);
        _tray = new TrayIcon(_window);
        _window.Show();
        _window.BeginRefresh();
    }
}

internal sealed class MainWindow : Window
{
    private readonly LauncherConfig _config;
    private readonly string? _configPath;
    private readonly Dictionary<string, MachineStatus> _statuses = new();
    private readonly Dictionary<string, (string Label, DateTime Started)> _busy = new();
    private readonly Dictionary<string, TextBlock> _busyLabels = new();
    private readonly StackPanel _list = new() { Margin = new Thickness(0) };
    private readonly TextBox _filter = new();
    private readonly Border _filterRow;
    private readonly TextBlock _summary = UiKit.Text("", 10.5, Theme.Muted, family: Theme.Mono);
    private readonly Canvas _statusProgress = UiKit.LoadingBar(48);
    private readonly DispatcherTimer _timer;
    private string? _selectedId;
    private DateTime _lastRemoteRefresh = DateTime.MinValue;
    private DateTime _lastRefresh = DateTime.MinValue;
    private bool _refreshing;

    public event Action? Refreshed;

    public LauncherConfig Config => _config;

    public MainWindow(LauncherConfig config, string? configPath)
    {
        _config = config;
        _configPath = configPath;
        _selectedId = config.LocalMachine.Id;

        Title = "DSH Launcher";
        Width = 480;
        Height = 420;
        MinWidth = 420;
        MinHeight = 360;
        Background = Theme.Page;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = Theme.Sans;

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        _filterRow = BuildFilterRow();
        root.Children.Add(_filterRow);
        Grid.SetRow(_filterRow, 0);

        var scroll = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Padding = new Thickness(10, 6, 6, 0),
            Content = _list,
        };
        root.Children.Add(scroll);
        Grid.SetRow(scroll, 1);

        var bottom = BuildBottomBar();
        root.Children.Add(bottom);
        Grid.SetRow(bottom, 2);

        var statusBar = BuildStatusBar();
        root.Children.Add(statusBar);
        Grid.SetRow(statusBar, 3);

        Content = root;
        SourceInitialized += (_, _) => DarkTitleBar(this);

        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(600) };
        _timer.Tick += async (_, _) =>
        {
            if (_busy.Count > 0)
            {
                // Update only the elapsed text: rebuilding the list would restart
                // the indeterminate bar animation on every tick.
                UpdateBusyLabels();
                return;
            }
            if ((DateTime.UtcNow - _lastRefresh).TotalSeconds < 4) return;
            await RefreshAsync();
        };
        _timer.Start();

        Closed += (_, _) => _timer.Stop();
    }

    private Border BuildFilterRow()
    {
        _filter.FontSize = 11.5;
        _filter.FontFamily = Theme.Sans;
        _filter.Background = Theme.Deep;
        _filter.Foreground = Theme.Text;
        _filter.CaretBrush = Theme.Text;
        _filter.BorderBrush = Theme.Line;
        _filter.BorderThickness = new Thickness(1);
        _filter.Padding = new Thickness(8, 3, 8, 3);
        _filter.TextChanged += (_, _) => RebuildList();
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(_filter);
        var count = UiKit.Text("", 10.5, Theme.Muted, family: Theme.Mono);
        count.Margin = new Thickness(8, 0, 0, 0);
        count.Tag = "count";
        Grid.SetColumn(count, 1);
        grid.Children.Add(count);
        var border = new Border
        {
            Padding = new Thickness(10, 6, 10, 6),
            BorderBrush = Theme.Line,
            BorderThickness = new Thickness(0, 0, 0, 1),
            Child = grid,
        };
        return border;
    }

    private Border BuildBottomBar()
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var add = UiKit.Quiet("+ マシンを追加", AddMachine);
        grid.Children.Add(add);
        var right = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        // The PWA belongs to this PC, not to a machine row: keep it a single, always-visible action.
        right.Children.Add(UiKit.Button("PWA を開く", true, OpenPwa, 24, 11));
        right.Children.Add(new Border { Width = 14 });
        right.Children.Add(UiKit.Quiet("ログ", () => ShowLogs(Selected())));
        right.Children.Add(new Border { Width = 12 });
        right.Children.Add(UiKit.Quiet("設定", OpenConfig));
        Grid.SetColumn(right, 2);
        grid.Children.Add(right);
        return new Border
        {
            Padding = new Thickness(10, 7, 10, 7),
            BorderBrush = Theme.Line,
            BorderThickness = new Thickness(0, 1, 0, 0),
            Child = grid,
        };
    }

    private Border BuildStatusBar()
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(_summary);
        _statusProgress.Visibility = Visibility.Collapsed;
        _statusProgress.Margin = new Thickness(8, 0, 8, 0);
        var progressHost = new Grid { VerticalAlignment = VerticalAlignment.Center };
        progressHost.Children.Add(_statusProgress);
        Grid.SetColumn(progressHost, 1);
        grid.Children.Add(progressHost);
        var version = UiKit.Text(AppInfo.Version, 10.5, Theme.Muted, family: Theme.Mono);
        Grid.SetColumn(version, 2);
        grid.Children.Add(version);
        return new Border
        {
            Background = Theme.Deep,
            Padding = new Thickness(10, 5, 10, 5),
            BorderBrush = Theme.Line,
            BorderThickness = new Thickness(0, 1, 0, 0),
            Child = grid,
        };
    }

    private Machine Selected() => _config.Find(_selectedId ?? "") ?? _config.LocalMachine;

    public void BeginRefresh() => _ = RefreshAsync();

    private void SetStatusProgress(bool visible)
    {
        _statusProgress.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (visible) _summary.Text = "更新中…";
    }

    public async Task RefreshAsync()
    {
        if (_refreshing) return;
        _refreshing = true;
        SetStatusProgress(true);
        try
        {
            var refreshRemotes = (DateTime.UtcNow - _lastRemoteRefresh).TotalSeconds > 15;
            foreach (var machine in _config.Machines.ToList())
            {
                if (machine.Kind == MachineKind.Ssh && !refreshRemotes && _statuses.ContainsKey(machine.Id)) continue;
                if (_busy.ContainsKey(machine.Id)) continue;
                try
                {
                    _statuses[machine.Id] = await MachineOps.StatusAsync(machine);
                }
                catch (Exception error)
                {
                    _statuses[machine.Id] = new MachineStatus
                    {
                        State = MachineState.Unreachable,
                        Port = machine.Port,
                        Error = error.Message,
                        Url = machine.TargetUrl,
                        Command = MachineOps.DisplayCommand(machine, "status"),
                    };
                }
            }
            if (refreshRemotes) _lastRemoteRefresh = DateTime.UtcNow;
            _config.Save(_configPath);
            _lastRefresh = DateTime.UtcNow;
            RebuildList();
            Refreshed?.Invoke();
        }
        finally
        {
            _refreshing = false;
            SetStatusProgress(false);
        }
    }

    private void UpdateBusyLabels()
    {
        foreach (var (id, operation) in _busy)
        {
            if (_busyLabels.TryGetValue(id, out var label))
                label.Text = $"{operation.Label}中 {Math.Max(0, (DateTime.UtcNow - operation.Started).TotalSeconds):0}s";
        }
    }

    private void RebuildList()
    {
        _list.Children.Clear();
        _busyLabels.Clear();
        var query = _filter.Text.Trim();
        var machines = _config.Machines
            .Where(m => query.Length == 0 || m.DisplayName.Contains(query, StringComparison.OrdinalIgnoreCase))
            .ToList();

        _filterRow.Visibility = _config.Machines.Count > 8 ? Visibility.Visible : Visibility.Collapsed;
        if (_filterRow.Child is Grid grid)
        {
            foreach (var child in grid.Children.OfType<TextBlock>())
            {
                if (child.Tag as string == "count") child.Text = $"{machines.Count} / {_config.Machines.Count}";
            }
        }

        var groups = new (string Title, Func<MachineStatus, bool> Match)[]
        {
            ("稼働中", s => s.State == MachineState.Running || s.State == MachineState.Starting),
            ("要対応", s => s.State is MachineState.NeedsSetup or MachineState.Unreachable),
            ("停止", s => s.State is MachineState.Stopped or MachineState.Unknown),
        };

        foreach (var (title, match) in groups)
        {
            var members = machines.Where(m => match(Status(m))).ToList();
            if (members.Count == 0) continue;
            var label = UiKit.Text(title, 10.5, Theme.Muted);
            label.Margin = new Thickness(2, 8, 2, 5);
            _list.Children.Add(label);
            foreach (var machine in members)
            {
                _list.Children.Add(BuildRow(machine));
                if (machine.Id == _selectedId) _list.Children.Add(BuildDetail(machine));
            }
        }

        var running = _config.Machines.Count(m => Status(m).State == MachineState.Running);
        var attention = _config.Machines.Count(m => Status(m).State is MachineState.NeedsSetup or MachineState.Unreachable);
        _summary.Text = $"{_config.Machines.Count} 台中 {running} 台稼働 · {attention} 台要対応";
    }

    private MachineStatus Status(Machine machine) =>
        _statuses.TryGetValue(machine.Id, out var status) ? status : new MachineStatus { State = MachineState.Unknown, Port = machine.Port };

    public MachineStatus StatusOf(Machine machine) => Status(machine);

    private Border BuildRow(Machine machine)
    {
        var status = Status(machine);
        var selected = machine.Id == _selectedId;
        var grid = new Grid { Height = 38 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var lamp = UiKit.Lamp(status.State);
        lamp.Margin = new Thickness(0, 0, 8, 0);
        grid.Children.Add(lamp);

        var name = UiKit.Text(machine.DisplayName, 12.5, selected ? Theme.Text : Theme.Secondary);
        Grid.SetColumn(name, 1);
        grid.Children.Add(name);

        var busy = _busy.TryGetValue(machine.Id, out var operation);
        var stateText = busy
            ? $"{operation.Label}中 {Math.Max(0, (DateTime.UtcNow - operation.Started).TotalSeconds):0}s"
            : status.StateText;
        if (!busy && status.State == MachineState.Running && status.Uptime is not null)
            stateText += $" {status.Uptime.Value:h\\:mm\\:ss}";
        if (!busy && status.LatencyMs is not null && machine.Kind == MachineKind.Ssh) stateText += $" {status.LatencyMs} ms";
        var state = UiKit.Text(stateText, 11, Theme.Muted, family: Theme.Mono);
        if (busy) _busyLabels[machine.Id] = state;
        state.Margin = new Thickness(8, 0, 0, 0);
        Grid.SetColumn(state, 2);
        grid.Children.Add(state);

        if (busy)
        {
            var bar = UiKit.LoadingBar();
            bar.Margin = new Thickness(8, 0, 0, 0);
            Grid.SetColumn(bar, 3);
            grid.Children.Add(bar);
        }
        else if (selected)
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(12, 0, 2, 0) };
            if (status.State == MachineState.Running)
            {
                actions.Children.Add(UiKit.Button("再起動", true, () => Act(machine, "restart", true)));
                actions.Children.Add(new Border { Width = 8 });
                actions.Children.Add(UiKit.Button("停止", false, () => Act(machine, "stop", true)));
            }
            else if (status.State == MachineState.NeedsSetup && machine.Kind == MachineKind.Ssh)
            {
                actions.Children.Add(UiKit.Button("セットアップ", true, () => Setup(machine)));
                actions.Children.Add(new Border { Width = 8 });
                actions.Children.Add(UiKit.Button("再検出", false, () => _ = RefreshAsync()));
            }
            else
            {
                actions.Children.Add(UiKit.Button("起動", true, () => Act(machine, "start", false)));
            }
            Grid.SetColumn(actions, 3);
            grid.Children.Add(actions);
        }

        var border = new Border
        {
            Child = grid,
            Height = 38,
            CornerRadius = new CornerRadius(7),
            Padding = new Thickness(10, 0, 10, 0),
            Margin = new Thickness(0, 0, 0, 2),
            Background = selected ? Theme.Raised : Brushes.Transparent,
            BorderBrush = selected ? Theme.Line : Brushes.Transparent,
            BorderThickness = new Thickness(1),
            Cursor = Cursors.Hand,
        };
        border.MouseLeftButtonUp += (_, _) => { _selectedId = machine.Id; RebuildList(); };
        border.ContextMenu = BuildRowMenu(machine);
        return border;
    }

    private ContextMenu BuildRowMenu(Machine machine)
    {
        var menu = new ContextMenu
        {
            Background = Theme.Card,
            Foreground = Theme.Text,
            BorderBrush = Theme.Line2,
        };
        void Item(string header, Action action)
        {
            var item = new MenuItem { Header = header, Foreground = Theme.Text, Background = Theme.Card };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        Item("名前を変更…", () => Rename(machine));
        Item("ブラウザで開く", () => OpenUrl(machine));
        menu.Items.Add(new Separator());
        Item("起動", () => Act(machine, "start", false));
        Item("再起動", () => Act(machine, "restart", true));
        Item("停止", () => Act(machine, "stop", true));
        menu.Items.Add(new Separator());
        Item("ログを開く", () => ShowLogs(machine));
        if (machine.Kind == MachineKind.Ssh)
        {
            Item("DSH をセットアップ…", () => SetupFull(machine));
            Item("ヘルパーを配置", () => Setup(machine));
        }
        Item("設定ファイルを開く", OpenConfig);
        return menu;
    }

    private Border BuildDetail(Machine machine)
    {
        var status = Status(machine);
        var stack = new StackPanel();
        var url = UiKit.Text(machine.TargetUrl, 11, Theme.Secondary, family: Theme.Mono);
        var urlRow = new Grid();
        urlRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        urlRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        urlRow.Children.Add(url);
        var copy = UiKit.Quiet("コピー", () => Clipboard.SetText(machine.TargetUrl), 10.5);
        Grid.SetColumn(copy, 1);
        urlRow.Children.Add(copy);
        stack.Children.Add(urlRow);

        var facts = new List<string>();
        if (status.Pid is not null) facts.Add($"PID {status.Pid}");
        facts.Add($"ポート {machine.Port}");
        if (status.MemoryMb is not null) facts.Add($"メモリ {status.MemoryMb} MB");
        if (status.NodeVersion is not null) facts.Add($"Node {status.NodeVersion}");
        if (status.DshInstalled == false) facts.Add("dsh 未導入");
        if (status.DshHome is not null) facts.Add(status.DshHome == true ? "~/.dsh あり" : "~/.dsh なし");
        if (status.Error is not null) facts.Add(status.Error);
        var factsText = UiKit.Text(string.Join(" · ", facts), 10.5, Theme.Muted, family: Theme.Mono);
        factsText.Margin = new Thickness(0, 6, 0, 0);
        stack.Children.Add(factsText);

        var receiptGrid = new Grid { Margin = new Thickness(0, 7, 0, 0) };
        receiptGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        receiptGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        receiptGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var receiptLabel = UiKit.Text("実行されるコマンド", 10.5, Theme.Muted);
        receiptLabel.Margin = new Thickness(0, 0, 8, 0);
        receiptGrid.Children.Add(receiptLabel);
        var receipt = UiKit.Text(status.Command ?? MachineOps.DisplayCommand(machine, "restart"), 10.5, Theme.Text, family: Theme.Mono);
        Grid.SetColumn(receipt, 1);
        receiptGrid.Children.Add(receipt);
        var receiptCopy = UiKit.Quiet("コピー", () => Clipboard.SetText(receipt.Text), 10.5);
        Grid.SetColumn(receiptCopy, 2);
        receiptGrid.Children.Add(receiptCopy);
        stack.Children.Add(new Border
        {
            BorderBrush = Theme.Line,
            BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(0, 6, 0, 0),
            Margin = new Thickness(0, 6, 0, 0),
            Child = receiptGrid,
        });

        var detail = UiKit.Surface(stack, 7, Theme.Card, Theme.Line, new Thickness(10, 8, 10, 8));
        detail.Margin = new Thickness(15, 3, 0, 4);
        return detail;
    }

    private async void Act(Machine machine, string verb, bool confirm)
    {
        var status = Status(machine);
        if (confirm && status.State == MachineState.Running)
        {
            var ok = ConfirmWindow.Ask(this, $"{machine.DisplayName} を{(verb == "restart" ? "再起動" : "停止")}しますか",
                verb == "restart"
                    ? "実行中のセッションは中断され、ページは再接続します。停止と起動で最大 90 秒かかります。"
                    : "実行中のセッションは中断されます。",
                MachineOps.DisplayCommand(machine, verb), verb == "restart" ? "再起動" : "停止");
            if (!ok) return;
        }

        var label = verb == "start" ? "起動" : verb == "restart" ? "再起動" : "停止";
        _busy[machine.Id] = (label, DateTime.UtcNow);
        RebuildList();
        var (success, message) = await MachineOps.ActionAsync(machine, verb);
        _busy.Remove(machine.Id);
        _statuses[machine.Id] = await MachineOps.StatusAsync(machine);
        _lastRemoteRefresh = DateTime.MinValue;
        RebuildList();
        Refreshed?.Invoke();
        if (!success)
        {
            ConfirmWindow.Info(this, $"{machine.DisplayName}", message);
        }
    }

    private async void Setup(Machine machine)
    {
        var status = Status(machine);
        var needsInstall = machine.Kind == MachineKind.Ssh &&
                           (status.DshInstalled == false || !NodeIsSupported(status.NodeVersion));
        if (needsInstall)
        {
            var plan = string.Join("\n", RemoteSetup.Plan(machine));
            var proceed = ConfirmWindow.Ask(this, $"{machine.DisplayName} に DSH をセットアップしますか",
                "Node 24.9 以上（無ければ導入）と dsh を導入し、操作ヘルパーを配置します。変更は対象マシンのユーザー領域に限られます。",
                plan, "セットアップ", "キャンセル");
            if (!proceed) return;
            _busy[machine.Id] = ("セットアップ", DateTime.UtcNow);
            RebuildList();
            var progress = new Progress<string>(_ => { });
            var result = await MachineOps.SetupFullAsync(machine, progress);
            _busy.Remove(machine.Id);
            _lastRemoteRefresh = DateTime.MinValue;
            await RefreshAsync();
            LogsWindow.Show(this, machine, result.Transcript.Count == 0
                ? new[] { result.Message }
                : result.Transcript.Concat(new[] { "", result.Message }).ToArray());
            if (!result.Ok) ConfirmWindow.Info(this, machine.DisplayName, result.Message);
            return;
        }

        _busy[machine.Id] = ("配置", DateTime.UtcNow);
        RebuildList();
        var (ok, message) = await MachineOps.DeployAsync(machine);
        _busy.Remove(machine.Id);
        _lastRemoteRefresh = DateTime.MinValue;
        await RefreshAsync();
        if (!ok) ConfirmWindow.Info(this, machine.DisplayName, message);
    }

    private static bool NodeIsSupported(string? version)
    {
        if (version is null) return false;
        var text = version.TrimStart('v', 'V').Split('.');
        if (text.Length < 2) return false;
        if (!int.TryParse(text[0], out var major)) return false;
        var minor = int.TryParse(text[1], out var parsed) ? parsed : 0;
        return major > 24 || (major == 24 && minor >= 9);
    }

    private async void SetupFull(Machine machine)
    {
        var plan = string.Join("\n", RemoteSetup.Plan(machine));
        var proceed = ConfirmWindow.Ask(this, $"{machine.DisplayName} に DSH をセットアップしますか",
            "Node 24.9 以上（無ければ導入）と dsh を導入し、操作ヘルパーを配置します。",
            plan, "セットアップ", "キャンセル");
        if (!proceed) return;
        _busy[machine.Id] = ("セットアップ", DateTime.UtcNow);
        RebuildList();
        var result = await MachineOps.SetupFullAsync(machine, new Progress<string>(_ => { }));
        _busy.Remove(machine.Id);
        _lastRemoteRefresh = DateTime.MinValue;
        await RefreshAsync();
        LogsWindow.Show(this, machine, result.Transcript.Count == 0
            ? new[] { result.Message }
            : result.Transcript.Concat(new[] { "", result.Message }).ToArray());
        if (!result.Ok) ConfirmWindow.Info(this, machine.DisplayName, result.Message);
    }

    private void Rename(Machine machine)
    {
        var name = RenameWindow.Ask(this, machine);
        if (string.IsNullOrWhiteSpace(name)) return;
        machine.Name = name.Trim();
        _config.Save(_configPath);
        RebuildList();
        Refreshed?.Invoke();
    }

    private void OpenUrl(Machine machine)
    {
        try { Process.Start(new ProcessStartInfo(machine.TargetUrl) { UseShellExecute = true }); }
        catch (Exception error) { ConfirmWindow.Info(this, machine.DisplayName, error.Message); }
    }

    /// <summary>Open this PC's DSH as its installed Brave PWA; it is not tied to the selected machine.</summary>
    private void OpenPwa()
    {
        var local = _config.LocalMachine;
        var app = BraveApps.Find(local);
        if (app is null)
        {
            ExplainMissingPwa(local);
            return;
        }
        var (ok, message) = BraveApps.Launch(app);
        if (!ok) ConfirmWindow.Info(this, "PWA を開く", message);
    }

    /// <summary>Tell the user how to install the PWA, and open Brave so they can do it now.</summary>
    internal void ExplainMissingPwa(Machine local)
    {
        if (BraveApps.Installations().Count == 0)
        {
            ConfirmWindow.Info(this, "PWA を開く", "Brave が見つかりません。Brave をインストールし、DSH の画面からアプリとして追加してください。");
            return;
        }
        var proceed = ConfirmWindow.Ask(this, "PWA が見つかりません",
            "このPCの DSH は Brave の PWA としてインストールされていません。Brave でこの URL を開き、アドレスバー右のインストールアイコン（または ⋮ メニューの「アプリとしてインストール」）で追加すると、ここから直接開けます。",
            local.TargetUrl, "Brave で開く", "閉じる");
        if (!proceed) return;
        var (ok, message) = BraveApps.OpenInBrave(local.TargetUrl);
        if (!ok) ConfirmWindow.Info(this, "Brave", message);
    }

    private void OpenConfig()
    {
        _config.Save(_configPath);
        try { Process.Start(new ProcessStartInfo(LauncherConfig.DefaultPath) { UseShellExecute = true }); }
        catch (Exception error) { ConfirmWindow.Info(this, "設定", error.Message); }
    }

    private void AddMachine()
    {
        var machine = AddMachineWindow.Ask(this);
        if (machine is null) return;
        _config.Machines.Add(machine);
        _config.Save(_configPath);
        _selectedId = machine.Id;
        BeginRefresh();
    }

    private async void ShowLogs(Machine machine)
    {
        var lines = await MachineOps.TailAsync(machine, 200);
        LogsWindow.Show(this, machine, lines);
    }

    private static void DarkTitleBar(Window window)
    {
        try
        {
            var handle = new WindowInteropHelper(window).Handle;
            var value = 1;
            DwmSetWindowAttribute(handle, 20, ref value, sizeof(int));
        }
        catch
        {
            // Dark title bar is cosmetic.
        }
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
}

internal sealed class TrayIcon : IDisposable
{
    private readonly WinForms.NotifyIcon _icon;
    private readonly MainWindow _window;
    private readonly WinForms.ToolStripMenuItem _header = new() { Enabled = false };

    public TrayIcon(MainWindow window)
    {
        _window = window;
        _icon = new WinForms.NotifyIcon
        {
            Icon = BuildIcon(),
            Text = "DSH Launcher",
            Visible = true,
            ContextMenuStrip = new WinForms.ContextMenuStrip(),
        };
        _icon.DoubleClick += (_, _) => ShowWindow();
        _icon.ContextMenuStrip.Opening += (_, _) => BuildMenu();
        window.Refreshed += BuildMenu;
    }

    private void ShowWindow()
    {
        _window.Show();
        _window.WindowState = WindowState.Normal;
        _window.Activate();
    }

    private void BuildMenu()
    {
        var menu = _icon.ContextMenuStrip!;
        menu.Items.Clear();
        var machines = _window.Config.Machines;
        var statuses = machines.Select(m => (Machine: m, Status: _window.StatusOf(m))).ToList();
        var running = statuses.Count(x => x.Status.State == MachineState.Running);
        var attention = statuses.Count(x => x.Status.State is MachineState.NeedsSetup or MachineState.Unreachable);
        _header.Text = $"{machines.Count} 台中 {running} 台稼働 · {attention} 台要対応";
        menu.Items.Add(_header);
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("PWA を開く", null, (_, _) => OpenPwa());
        menu.Items.Add(new WinForms.ToolStripSeparator());

        var pinned = statuses
            .Where(x => x.Status.State == MachineState.Running)
            .Concat(statuses.Where(x => x.Status.State != MachineState.Running))
            .Take(3)
            .ToList();
        foreach (var (machine, status) in pinned)
        {
            var item = new WinForms.ToolStripMenuItem($"{machine.DisplayName}   {status.StateText}")
            {
                ForeColor = status.State == MachineState.Running ? Drawing.Color.FromArgb(0x4c, 0xc3, 0x8a)
                    : status.State is MachineState.NeedsSetup or MachineState.Unreachable ? Drawing.Color.FromArgb(0xd9, 0xa4, 0x41)
                    : Drawing.Color.FromArgb(0xa1, 0xa1, 0xa6),
            };
            item.DropDownItems.Add("ブラウザで開く", null, (_, _) => OpenUrl(machine));
            item.DropDownItems.Add("再起動", null, (_, _) => Run(machine, "restart"));
            item.DropDownItems.Add("停止", null, (_, _) => Run(machine, "stop"));
            item.DropDownItems.Add(new WinForms.ToolStripSeparator());
            item.DropDownItems.Add("ログを開く", null, (_, _) => ShowLogs(machine));
            item.DropDownItems.Add("詳細（一覧を開く）", null, (_, _) => ShowWindow());
            menu.Items.Add(item);
        }

        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("すべてのマシン…", null, (_, _) => ShowWindow());
        menu.Items.Add("稼働中をまとめて再起動…", null, (_, _) => RestartAll());
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("ログ", null, (_, _) => ShowLogs(_window.Config.LocalMachine));
        menu.Items.Add("設定", null, (_, _) => Process.Start(new ProcessStartInfo(LauncherConfig.DefaultPath) { UseShellExecute = true }));
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add("終了", null, (_, _) => { _icon.Visible = false; Application.Current.Shutdown(); });
    }

    private void OpenUrl(Machine machine)
    {
        try { Process.Start(new ProcessStartInfo(machine.TargetUrl) { UseShellExecute = true }); }
        catch { /* opening the browser is best-effort */ }
    }

    private void OpenPwa()
    {
        var local = _window.Config.LocalMachine;
        var app = BraveApps.Find(local);
        if (app is null)
        {
            _window.Dispatcher.Invoke(() => _window.ExplainMissingPwa(local));
            return;
        }
        var (ok, message) = BraveApps.Launch(app);
        if (!ok) _window.Dispatcher.Invoke(() => ConfirmWindow.Info(_window, "PWA を開く", message));
    }

    private void ShowLogs(Machine machine)
    {
        var lines = MachineOps.TailAsync(machine, 200).GetAwaiter().GetResult();
        _window.Dispatcher.Invoke(() => LogsWindow.Show(_window, machine, lines));
    }

    private void Run(Machine machine, string verb)
    {
        var status = _window.StatusOf(machine);
        if (status.State == MachineState.Running)
        {
            var confirmed = _window.Dispatcher.Invoke(() => ConfirmWindow.Ask(_window,
                $"{machine.DisplayName} を{(verb == "restart" ? "再起動" : "停止")}しますか",
                verb == "restart"
                    ? "実行中のセッションは中断され、ページは再接続します。停止と起動で最大 90 秒かかります。"
                    : "実行中のセッションは中断されます。",
                MachineOps.DisplayCommand(machine, verb), verb == "restart" ? "再起動" : "停止"));
            if (!confirmed) return;
        }
        _ = _window.Dispatcher.Invoke(async () =>
        {
            await MachineOps.ActionAsync(machine, verb);
            await _window.RefreshAsync();
        });
    }

    private void RestartAll()
    {
        var running = _window.Config.Machines.Where(m => _window.StatusOf(m).State == MachineState.Running).ToList();
        if (running.Count == 0) return;
        var confirmed = _window.Dispatcher.Invoke(() => ConfirmWindow.Ask(_window,
            $"稼働中の {running.Count} 台を再起動しますか",
            "対象のセッションは中断され、ページは再接続します。",
            string.Join("\n", running.Select(m => MachineOps.DisplayCommand(m, "restart"))), "再起動"));
        if (!confirmed) return;
        _ = Task.Run(async () =>
        {
            foreach (var machine in running) await MachineOps.ActionAsync(machine, "restart");
            await _window.Dispatcher.InvokeAsync(async () => await _window.RefreshAsync());
        });
    }

    private static Drawing.Icon BuildIcon()
    {
        using var bitmap = new Drawing.Bitmap(32, 32);
        using (var graphics = Drawing.Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = Drawing.Drawing2D.SmoothingMode.AntiAlias;
            graphics.Clear(Drawing.Color.Transparent);
            using var background = new Drawing.SolidBrush(Drawing.Color.FromArgb(0x23, 0x23, 0x25));
            graphics.FillRectangle(background, 1, 1, 30, 30);
            using var pen = new Drawing.Pen(Drawing.Color.FromArgb(0xed, 0xed, 0xed), 2);
            graphics.DrawRectangle(pen, 1, 1, 29, 29);
            using var font = new Drawing.Font("Consolas", 12, Drawing.FontStyle.Bold);
            using var text = new Drawing.SolidBrush(Drawing.Color.FromArgb(0xed, 0xed, 0xed));
            graphics.DrawString(">_", font, text, 2, 7);
            using var dot = new Drawing.SolidBrush(Drawing.Color.FromArgb(0x4c, 0xc3, 0x8a));
            graphics.FillEllipse(dot, 22, 22, 8, 8);
        }
        var handle = bitmap.GetHicon();
        return Drawing.Icon.FromHandle(handle);
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}















