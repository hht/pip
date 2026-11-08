/// Answers: Built-in plugin IDs. External plugin IDs are directory names under `plugins/<id>/` and cannot use these (settings toggles and ordering stored by ID, avoiding collision)
public enum PluginID {
    public static let exitGuard = "guard"
    public static let claudeCode = "claude"
    public static let builtIn: Set<String> = [exitGuard, claudeCode]
    /// Bundled terminal plugin: treated as external (uses inbox), but `plugins/terminal/` is managed by App and updated on launch
    public static let terminal = "terminal"
}
