// swift-tools-version: 6.0
//
// One manifest for every Folio module. Each module keeps its own folder under
// Packages/, and the iOS app (Apps/FolioiOS) links the products it needs from
// this package. Everything here builds on macOS, Linux and Windows; code that
// needs Apple frameworks sits behind `#if canImport(...)`.

import PackageDescription

let sqliteSettings: [CSetting] = [
    // Multi-thread mode: a connection is only ever used by one thread at a
    // time (FolioStorage serialises access through an actor).
    .define("SQLITE_THREADSAFE", to: "2"),
    .define("SQLITE_DQS", to: "0"),
    .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
    .define("SQLITE_DEFAULT_WAL_SYNCHRONOUS", to: "1"),
    .define("SQLITE_LIKE_DOESNT_MATCH_BLOBS"),
    .define("SQLITE_OMIT_DEPRECATED"),
    .define("SQLITE_OMIT_LOAD_EXTENSION"),
    .define("SQLITE_OMIT_SHARED_CACHE"),
    .define("SQLITE_ENABLE_FTS5"),
]

let package = Package(
    name: "FolioKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "FolioCore", targets: ["FolioCore"]),
        .library(name: "FolioFreshRSS", targets: ["FolioFreshRSS"]),
        .library(name: "FolioReader", targets: ["FolioReader"]),
        .library(name: "FolioAudio", targets: ["FolioAudio"]),
        .library(name: "FolioStorage", targets: ["FolioStorage"]),
        .library(name: "FolioSync", targets: ["FolioSync"]),
        .library(name: "FolioFeeds", targets: ["FolioFeeds"]),
        .executable(name: "folio-dev", targets: ["FolioDev"]),
    ],
    targets: [
        .target(
            name: "FolioCore",
            path: "Packages/FolioCore/Sources/FolioCore"
        ),
        .target(
            name: "FolioFreshRSS",
            dependencies: ["FolioCore"],
            path: "Packages/FolioFreshRSS/Sources/FolioFreshRSS"
        ),
        .target(
            name: "FolioReader",
            dependencies: ["FolioCore"],
            path: "Packages/FolioReader/Sources/FolioReader"
        ),
        .target(
            name: "FolioAudio",
            dependencies: ["FolioCore", "FolioReader"],
            path: "Packages/FolioAudio/Sources/FolioAudio"
        ),
        .target(
            name: "CSQLite",
            path: "Packages/FolioStorage/Sources/CSQLite",
            cSettings: sqliteSettings
        ),
        .target(
            name: "FolioStorage",
            dependencies: ["FolioCore", "CSQLite"],
            path: "Packages/FolioStorage/Sources/FolioStorage"
        ),
        .target(
            name: "FolioSync",
            dependencies: ["FolioCore", "FolioFreshRSS", "FolioReader", "FolioStorage"],
            path: "Packages/FolioSync/Sources/FolioSync"
        ),
        .target(
            name: "FolioFeeds",
            dependencies: ["FolioCore", "FolioFreshRSS"],
            path: "Packages/FolioFeeds/Sources/FolioFeeds"
        ),
        .executableTarget(
            name: "FolioDev",
            dependencies: ["FolioCore", "FolioFreshRSS", "FolioReader", "FolioAudio", "FolioStorage", "FolioSync"],
            path: "Tools/FolioDev"
        ),

        .testTarget(
            name: "FolioCoreTests",
            dependencies: ["FolioCore"],
            path: "Packages/FolioCore/Tests/FolioCoreTests"
        ),
        .testTarget(
            name: "FolioFreshRSSTests",
            dependencies: ["FolioFreshRSS"],
            path: "Packages/FolioFreshRSS/Tests/FolioFreshRSSTests"
        ),
        .testTarget(
            name: "FolioReaderTests",
            dependencies: ["FolioReader"],
            path: "Packages/FolioReader/Tests/FolioReaderTests"
        ),
        .testTarget(
            name: "FolioAudioTests",
            dependencies: ["FolioAudio"],
            path: "Packages/FolioAudio/Tests/FolioAudioTests"
        ),
        .testTarget(
            name: "FolioStorageTests",
            dependencies: ["FolioStorage"],
            path: "Packages/FolioStorage/Tests/FolioStorageTests"
        ),
        .testTarget(
            name: "FolioSyncTests",
            dependencies: ["FolioSync"],
            path: "Packages/FolioSync/Tests/FolioSyncTests"
        ),
        .testTarget(
            name: "FolioFeedsTests",
            dependencies: ["FolioFeeds", "FolioFreshRSS", "FolioSync", "FolioStorage"],
            path: "Packages/FolioFeeds/Tests/FolioFeedsTests"
        ),
        .testTarget(
            name: "FolioIntegrationTests",
            dependencies: ["FolioFreshRSS", "FolioReader", "FolioAudio", "FolioStorage", "FolioSync"],
            path: "Tests/FolioIntegrationTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
