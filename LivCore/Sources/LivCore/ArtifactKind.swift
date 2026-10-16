import Darwin
import Foundation

/// One kind of build output or dependency folder that a tool recreates, and the file that proves it can.
public struct ArtifactKind: Sendable, Identifiable, Hashable {
    public let id: String
    /// Folder names of the artifact, compared exactly (case-sensitive, like the tools that create them).
    public let folderNames: [String]
    /// File names (or `*.ext` globs) next to the artifact that prove it can be rebuilt. Any one is enough.
    public let markers: [String]
    public let defaultSelected: Bool
    /// One line for the UI: how to get it back.
    public let rebuildHint: String
    /// A file the folder itself must hold, for names too common to trust (`env`). Checked by the finder.
    public let requiredInside: String?

    public init(
        id: String,
        folderNames: [String],
        markers: [String],
        defaultSelected: Bool,
        rebuildHint: String,
        requiredInside: String? = nil
    ) {
        self.id = id
        self.folderNames = folderNames
        self.markers = markers
        self.defaultSelected = defaultSelected
        self.rebuildHint = rebuildHint
        self.requiredInside = requiredInside
    }

    /// True when one of the marker names is among `siblings`, the entries of the artifact's parent folder.
    func isProven(by siblings: [String]) -> Bool {
        markers.contains { marker in
            marker.contains("*")
                ? siblings.contains { fnmatch(marker, $0, 0) == 0 }
                : siblings.contains(marker)
        }
    }
}

extension ArtifactKind {
    /// The built-in catalog. Order matters: when a folder fits two kinds the first one wins.
    ///
    /// Every entry is something a tool rebuilds from the files next to it, and carries a line on why it is
    /// safe. Kinds that can hold hand-made or slow-to-restore content start unchecked.
    public static let builtIn: [ArtifactKind] = [
        // `npm`, `pnpm` or `yarn install` recreates it from package.json and the lockfile.
        ArtifactKind(
            id: "node-modules", folderNames: ["node_modules"], markers: ["package.json"], defaultSelected: true,
            rebuildHint: "Run npm install (or pnpm/yarn) to restore it."
        ),
        // Output and cache of `next build` / `next dev`.
        ArtifactKind(
            id: "next", folderNames: [".next"], markers: ["package.json"], defaultSelected: true,
            rebuildHint: "Run next build (or next dev) to restore it."
        ),
        // Output of Nuxt's build and dev server.
        ArtifactKind(
            id: "nuxt", folderNames: [".nuxt"], markers: ["package.json"], defaultSelected: true,
            rebuildHint: "Run nuxt build (or nuxt dev) to restore it."
        ),
        // Turborepo's cache is filled again by the next run of a task.
        ArtifactKind(
            id: "turbo", folderNames: [".turbo"], markers: ["package.json"], defaultSelected: true,
            rebuildHint: "Turborepo fills it again on the next run."
        ),
        // SvelteKit generates it on `dev` and `build`.
        ArtifactKind(
            id: "svelte-kit", folderNames: [".svelte-kit"], markers: ["package.json"], defaultSelected: true,
            rebuildHint: "Run vite dev (or build) to restore it."
        ),
        // Parcel's cache is rebuilt by the next build.
        ArtifactKind(
            id: "parcel-cache", folderNames: [".parcel-cache"], markers: ["package.json"], defaultSelected: true,
            rebuildHint: "Parcel fills it again on the next build."
        ),
        // Build output. If a project keeps it under version control, the git check drops it.
        ArtifactKind(
            id: "js-dist", folderNames: ["dist"], markers: ["package.json"], defaultSelected: true,
            rebuildHint: "Run the project's build script to restore it."
        ),
        // Sometimes published or versioned by hand, so it is offered but not preselected.
        ArtifactKind(
            id: "js-build", folderNames: ["build"], markers: ["package.json"], defaultSelected: false,
            rebuildHint: "Run the project's build script to restore it."
        ),
        // `cargo build` recreates it from Cargo.toml.
        ArtifactKind(
            id: "cargo-target", folderNames: ["target"], markers: ["Cargo.toml"], defaultSelected: true,
            rebuildHint: "Run cargo build to restore it."
        ),
        // `mvn package` recreates it from pom.xml.
        ArtifactKind(
            id: "maven-target", folderNames: ["target"], markers: ["pom.xml"], defaultSelected: true,
            rebuildHint: "Run mvn package to restore it."
        ),
        // `swift build` recreates it from Package.swift.
        ArtifactKind(
            id: "swiftpm-build", folderNames: [".build"], markers: ["Package.swift"], defaultSelected: true,
            rebuildHint: "Run swift build to restore it."
        ),
        // `gradle build` recreates it from the build script.
        ArtifactKind(
            id: "gradle-build", folderNames: ["build"], markers: ["build.gradle", "build.gradle.kts"], defaultSelected: true,
            rebuildHint: "Run gradle build to restore it."
        ),
        // Gradle's local cache next to a Gradle project is downloaded again on demand.
        ArtifactKind(
            id: "gradle-cache", folderNames: [".gradle"],
            markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], defaultSelected: true,
            rebuildHint: "Gradle fills it again on the next build."
        ),
        // Xcode build products; a Makefile or script may also install into it, so it starts unchecked.
        ArtifactKind(
            id: "xcode-build", folderNames: ["build"], markers: ["*.xcodeproj"], defaultSelected: false,
            rebuildHint: "Build the project in Xcode (or xcodebuild) to restore it."
        ),
        // `pod install` needs the network and the right pod versions, so it starts unchecked.
        ArtifactKind(
            id: "cocoapods", folderNames: ["Pods"], markers: ["Podfile"], defaultSelected: false,
            rebuildHint: "Run pod install to restore it."
        ),
        // `composer install` recreates it, but vendored patches would be lost, so it starts unchecked.
        ArtifactKind(
            id: "composer-vendor", folderNames: ["vendor"], markers: ["composer.json"], defaultSelected: false,
            rebuildHint: "Run composer install to restore it."
        ),
        // Recreating an environment may need a specific Python, so it starts unchecked. `pyvenv.cfg` is what
        // venv, virtualenv and uv write into every environment, so a folder without it is not one (a `.env`
        // folder, say) and is never offered.
        ArtifactKind(
            id: "python-venv", folderNames: [".venv", "venv", ".env", "env"],
            markers: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile", "uv.lock", "poetry.lock"],
            defaultSelected: false,
            rebuildHint: "Create the environment again and reinstall the requirements.",
            requiredInside: "pyvenv.cfg"
        ),
    ]
}
