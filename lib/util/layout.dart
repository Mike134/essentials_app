/// Shared wide/narrow breakpoint -- Windows desktop vs. Android. One
/// `LayoutBuilder` switch reused everywhere a screen needs the same
/// responsive split, rather than each screen picking its own number:
/// [HomeShell]'s nav rail/drawer switch and
/// [OrderSplitPaneScreen]'s Row/push-navigation switch both key off this.
const double wideLayoutBreakpoint = 600;
