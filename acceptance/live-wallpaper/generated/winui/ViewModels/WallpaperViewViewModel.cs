using System;
using System.Windows.Input;

namespace CircuitGenerated;

public sealed class WallpaperViewViewModel
{
    public string Gate { get; set; }

}

public sealed class WallpaperViewRelayCommand : ICommand
{
    private readonly Action action;
    public WallpaperViewRelayCommand(Action action) => this.action = action;
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => action();
    public event EventHandler? CanExecuteChanged;
}
