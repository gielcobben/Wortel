import Foundation

/// The name the app shows: "Wortel", or "Wortel Beta" on a beta build.
///
/// macOS draws it in the menu bar, the Dock and Finder from the bundle
/// (scripts/display-name.sh); this is the same name for the places Wortel
/// writes it itself, like "Quit Wortel Beta". Only where a string names the
/// app that is running. Prose about what Wortel does says "Wortel", and so
/// does anything that goes by the app rather than shows it: the data folder,
/// the bundle, the executable and the `wortel` command keep their names on a
/// beta.
enum AppName {
    /// Localized, so a beta's InfoPlist.strings wins over Info.plist's "Wortel".
    static let shown: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Wortel"
}
