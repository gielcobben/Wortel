import Foundation

/// Vellum is zero-config: all Ghostty settings are hardcoded here and fed
/// through a synthetic argv. `ghostty_init` stores argv process-wide and
/// `ghostty_config_load_cli_args` parses these entries as `--key=value`
/// config settings (see Ghostty's src/main_c.zig). No config file anywhere,
/// and we never call ghostty_config_load_default_files so the user's real
/// ~/.config/ghostty can't leak in.
enum GhosttyConfig {
    static let defaults: [String] = [
        "vellum", // argv[0], ignored
        // Font: omit font-family — Ghostty embeds JetBrains Mono as its default.
        "--font-size=13",
        // Built-in theme pair; switches automatically with system appearance
        // combined with ghostty_surface_set_color_scheme forwarding.
        "--theme=light:catppuccin-latte,dark:catppuccin-mocha",
        "--cursor-style=block",
        // Injects shell integration (zsh/bash/fish) so OSC 7 reports pwd on
        // every prompt -> GHOSTTY_ACTION_PWD -> session cwd restore.
        "--shell-integration=detect",
        "--confirm-close-surface=false",
        "--mouse-hide-while-typing=true",
        "--window-padding-x=8",
        "--window-padding-y=4",
        // Vellum owns macOS-shaped keybinds via its menu; drop Ghostty's
        // window/tab/split management bindings by not binding them here.
    ]
}
