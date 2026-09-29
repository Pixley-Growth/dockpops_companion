/// The icon-recipe version the Poplet healer expects in each bundle's
/// `DockPopsIconRecipeVersion` Info.plist key.
///
/// MUST equal the value PopletKit's `PopletBundleWriter` stamps (16 in
/// PopletKit 0.1.x). Each side rebuilds any bundle whose stamp differs from
/// its own value, so a mismatch makes the generator and the healer rewrite
/// every Poplet back and forth forever (re-sign, setIcon, lsregister on every
/// launch / click / sync). `PopletIconRecipeVersionTests` generates a real
/// bundle through PopletKit and fails if the two drift — bump this only
/// alongside a PopletKit bump that changes the stamp.
///
/// Compiled into both the `DockPopsPoplet` target and the test target.
enum PopletIconRecipe {
    static let version = 16
}
