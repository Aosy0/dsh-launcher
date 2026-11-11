using System.IO;
using System.Threading;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace DshLauncher.Ui;

internal abstract class DialogBase : Window
{
    protected DialogBase(string title, double width)
    {
        Title = title;
        Width = width;
        SizeToContent = SizeToContent.Height;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Theme.Card;
        FontFamily = Theme.Sans;
        ShowInTaskbar = false;
        AllowsTransparency = false;
        // Drag only from non-interactive space: DragMove() captures the mouse and
        // would swallow the click that a button needs to fire.
        MouseLeftButtonDown += (_, e) =>
        {
            if (e.ButtonState != MouseButtonState.Pressed) return;
            if (IsInteractive(e.OriginalSource as DependencyObject)) return;
            try { DragMove(); } catch { /* a drag that ends off-window throws */ }
        };
    }

    private static bool IsInteractive(DependencyObject? source)
    {
        while (source is not null)
        {
            if (source is Button or TextBox or ComboBox or System.Windows.Controls.Primitives.ButtonBase) return true;
            if (source is Border { Cursor: not null } border && border.Cursor == Cursors.Hand) return true;
            source = source is Visual or System.Windows.Media.Media3D.Visual3D
                ? VisualTreeHelper.GetParent(source)
                : LogicalTreeHelper.GetParent(source);
        }
        return false;
    }

    protected Border Frame(UIElement child) => new()
    {
        Child = child,
        BorderBrush = Theme.Line2,
        BorderThickness = new Thickness(1),
        Background = Theme.Card,
    };
}

internal sealed class ConfirmWindow : DialogBase
{
    private bool _accepted;

    private ConfirmWindow(string title, string body, string? receipt, string okLabel, string? cancelLabel)
        : base(title, 404)
    {
        var stack = new StackPanel { Margin = new Thickness(16, 14, 16, 14) };
        stack.Children.Add(UiKit.Text(title, 13.5, Theme.Text, FontWeights.Medium));

        var bodyText = UiKit.Selectable(body, 12, Theme.Secondary);
        bodyText.Margin = new Thickness(0, 7, 0, 0);
        stack.Children.Add(bodyText);

        if (!string.IsNullOrWhiteSpace(receipt))
        {
            var receiptText = UiKit.Selectable(receipt!, 10.5, Theme.Text, Theme.Mono);
            var receiptBox = UiKit.Surface(receiptText, 7, Theme.Page, Theme.Line, new Thickness(10, 8, 10, 8));
            receiptBox.Margin = new Thickness(0, 12, 0, 0);
            stack.Children.Add(receiptBox);
        }

        var footer = new Grid { Margin = new Thickness(0, 14, 0, 0) };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var copy = UiKit.Quiet("コピー", () => CopyText(title, body, receipt), 11);
        copy.HorizontalAlignment = HorizontalAlignment.Left;
        copy.VerticalAlignment = VerticalAlignment.Center;
        footer.Children.Add(copy);

        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(UiKit.Button(cancelLabel ?? "キャンセル", false, Close, 28, 12));
        buttons.Children.Add(new Border { Width = 6 });
        buttons.Children.Add(UiKit.Button(okLabel, true, () => { _accepted = true; Close(); }, 28, 12));
        Grid.SetColumn(buttons, 1);
        footer.Children.Add(buttons);
        stack.Children.Add(footer);

        Content = Frame(stack);
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
    }

    private static void CopyText(string title, string body, string? receipt)
    {
        try
        {
            var text = receipt is null ? title + "\n\n" + body : title + "\n\n" + body + "\n\n" + receipt;
            Clipboard.SetText(text);
        }
        catch
        {
            // Clipboard access is best-effort.
        }
    }

    public static bool Ask(Window owner, string title, string body, string? receipt, string okLabel, string? cancelLabel = null)
    {
        var dialog = new ConfirmWindow(title, body, receipt, okLabel, cancelLabel) { Owner = owner };
        dialog.ShowDialog();
        return dialog._accepted;
    }

    public static void Info(Window owner, string title, string body)
    {
        var dialog = new ConfirmWindow(title, body, null, "閉じる", null) { Owner = owner };
        dialog.ShowDialog();
    }
}

internal sealed class RenameWindow : DialogBase
{
    private string? _result;
    private readonly TextBox _input = new();

    private RenameWindow(Machine machine) : base("名前を変更", 380)
    {
        var stack = new StackPanel { Margin = new Thickness(16, 14, 16, 14) };
        stack.Children.Add(UiKit.Text($"{machine.Id} の名前", 13, Theme.Text, FontWeights.Medium));

        _input.Text = machine.Name;
        _input.FontSize = 12.5;
        _input.FontFamily = Theme.Sans;
        _input.Background = Theme.Deep;
        _input.Foreground = Theme.Text;
        _input.CaretBrush = Theme.Text;
        _input.BorderBrush = Theme.Line2;
        _input.BorderThickness = new Thickness(1);
        _input.Padding = new Thickness(8, 5, 8, 5);
        _input.Margin = new Thickness(0, 10, 0, 0);
        _input.SelectAll();
        stack.Children.Add(_input);

        var preview = UiKit.Text(machine.Kind == MachineKind.Local ? $"表示: {machine.Name}(local)" : $"表示: {machine.Name}", 10.5, Theme.Muted, family: Theme.Mono);
        preview.Margin = new Thickness(0, 6, 0, 0);
        stack.Children.Add(preview);
        _input.TextChanged += (_, _) =>
        {
            var name = _input.Text.Trim();
            preview.Text = machine.Kind == MachineKind.Local ? $"表示: {name}(local)" : $"表示: {name}";
        };

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 14, 0, 0),
        };
        buttons.Children.Add(UiKit.Button("キャンセル", false, Close, 28, 12));
        buttons.Children.Add(new Border { Width = 6 });
        buttons.Children.Add(UiKit.Button("保存", true, () => { _result = _input.Text.Trim(); Close(); }, 28, 12));
        stack.Children.Add(buttons);

        Content = Frame(stack);
        Loaded += (_, _) => _input.Focus();
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) Close();
            if (e.Key == Key.Enter) { _result = _input.Text.Trim(); Close(); }
        };
    }

    public static string? Ask(Window owner, Machine machine)
    {
        var dialog = new RenameWindow(machine) { Owner = owner };
        dialog.ShowDialog();
        return dialog._result;
    }
}

internal sealed class AddMachineWindow : DialogBase
{
    private Machine? _result;
    private readonly TextBox _name = new();
    private readonly TextBox _alias = new();
    private readonly TextBox _port = new();
    private readonly TextBox _profile = new();
    private readonly ComboBox _platform = new();

    private AddMachineWindow() : base("マシンを追加", 404)
    {
        var stack = new StackPanel { Margin = new Thickness(16, 14, 16, 14) };
        stack.Children.Add(UiKit.Text("SSH で接続するマシン", 13, Theme.Text, FontWeights.Medium));

        TextBox Field(string label, string value, double top)
        {
            var box = new TextBox
            {
                Text = value,
                FontSize = 12,
                FontFamily = Theme.Sans,
                Background = Theme.Deep,
                Foreground = Theme.Text,
                CaretBrush = Theme.Text,
                BorderBrush = Theme.Line,
                BorderThickness = new Thickness(1),
                Padding = new Thickness(8, 4, 8, 4),
                Margin = new Thickness(0, top, 0, 0),
            };
            var caption = UiKit.Text(label, 10.5, Theme.Muted);
            caption.Margin = new Thickness(0, top, 0, 3);
            stack.Children.Add(caption);
            stack.Children.Add(box);
            return box;
        }

        _name = Field("名前", "", 10);
        _alias = Field("SSH エイリアス（~/.ssh/config の Host）", "", 10);
        _port = Field("ポート", "3080", 10);
        _profile = Field("プロファイル", "web", 10);

        var platformCaption = UiKit.Text("プラットフォーム", 10.5, Theme.Muted);
        platformCaption.Margin = new Thickness(0, 10, 0, 3);
        stack.Children.Add(platformCaption);
        _platform.Items.Add("auto");
        _platform.Items.Add("linux");
        _platform.Items.Add("windows");
        _platform.SelectedIndex = 0;
        _platform.FontSize = 12;
        _platform.Background = Theme.Deep;
        _platform.Foreground = Theme.Text;
        _platform.BorderBrush = Theme.Line;
        _platform.Margin = new Thickness(0, 0, 0, 0);
        stack.Children.Add(_platform);

        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 14, 0, 0),
        };
        buttons.Children.Add(UiKit.Button("キャンセル", false, Close, 28, 12));
        buttons.Children.Add(new Border { Width = 6 });
        buttons.Children.Add(UiKit.Button("追加", true, Accept, 28, 12));
        stack.Children.Add(buttons);

        Content = Frame(stack);
        Loaded += (_, _) => _name.Focus();
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
    }

    private void Accept()
    {
        var name = _name.Text.Trim();
        var alias = _alias.Text.Trim();
        if (name.Length == 0 || alias.Length == 0) return;
        _result = new Machine
        {
            Id = name,
            Kind = MachineKind.Ssh,
            Name = name,
            SshAlias = alias,
            Platform = (_platform.SelectedItem as string ?? "auto").ToLowerInvariant(),
            Port = int.TryParse(_port.Text.Trim(), out var port) ? port : 3080,
            Profile = _profile.Text.Trim().Length > 0 ? _profile.Text.Trim() : "web",
        };
        Close();
    }

    public static Machine? Ask(Window owner)
    {
        var dialog = new AddMachineWindow { Owner = owner };
        dialog.ShowDialog();
        return dialog._result;
    }
}

internal sealed class LogsWindow : Window
{
    private readonly string _allText;

    private LogsWindow(Machine machine, string[] lines)
    {
        Title = $"{machine.DisplayName} のログ";
        Width = 640;
        Height = 420;
        Background = Theme.Page;
        FontFamily = Theme.Sans;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _allText = lines.Length == 0 ? "まだログはありません" : string.Join("\n", lines);
        var box = new TextBox
        {
            Text = _allText,
            IsReadOnly = true,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.NoWrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            Background = Theme.Page,
            Foreground = Theme.Secondary,
            BorderThickness = new Thickness(0),
            FontFamily = Theme.Mono,
            FontSize = 11.5,
            Padding = new Thickness(12),
        };

        var header = new Grid { Margin = new Thickness(12, 8, 12, 0) };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var caption = UiKit.Text("内容は選択してコピーできます（Ctrl+C）", 10.5, Theme.Muted);
        header.Children.Add(caption);
        var copy = UiKit.Quiet("すべてコピー", CopyAll, 11);
        Grid.SetColumn(copy, 1);
        header.Children.Add(copy);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.Children.Add(header);
        Grid.SetRow(box, 1);
        root.Children.Add(box);
        Content = root;
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
    }

    private void CopyAll()
    {
        try { Clipboard.SetText(_allText); } catch { /* best-effort */ }
    }

    public static void Show(Window owner, Machine machine, string[] lines)
    {
        new LogsWindow(machine, lines) { Owner = owner }.Show();
    }
}




