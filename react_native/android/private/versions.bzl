"""Pinned Android SDK component archives from https://dl.google.com/android/repository/repository2-3.xml."""

COMPILE_SDK = 36
BUILD_TOOLS = "36.0.0"

PLATFORM = struct(
    url = "https://dl.google.com/android/repository/platform-36_r02.zip",
    sha256 = "37607369a28c5b640b3a7998868d45898ebcb777565a0e85f9acf36f29631d2e",
    strip_prefix = "android-36",
)

# The archive root is "android-16" for every host; Google never renamed it.
BUILD_TOOLS_ARCHIVES = {
    "linux": struct(
        url = "https://dl.google.com/android/repository/build-tools_r36_linux.zip",
        sha256 = "5d9ac77fb6ff43d9da518a337b4fcf8f9097113df531d99ccefe80ef7ce8250b",
        strip_prefix = "android-16",
    ),
    "macos": struct(
        url = "https://dl.google.com/android/repository/build-tools_r36_macosx.zip",
        sha256 = "04e7f3a72044de4926fa038fa0e251a37bba1e1c3fb8beab6f8401bfd9eb4bf3",
        strip_prefix = "android-16",
    ),
}

PLATFORM_TOOLS_ARCHIVES = {
    "linux": struct(
        url = "https://dl.google.com/android/repository/platform-tools_r37.0.1-linux.zip",
        sha256 = "d230f13842f60f782a8645f9c813f8f845bf36089ea7289f28c48f17979313f1",
        strip_prefix = "platform-tools",
    ),
    "macos": struct(
        url = "https://dl.google.com/android/repository/platform-tools_r37.0.1-darwin.zip",
        sha256 = "ee39ad5967e95c2a07f04dbcbde96b1a0c916ba376096db5d2f498b7727a5d1d",
        strip_prefix = "platform-tools",
    ),
}

# React Native 0.86 builds with NDK 27.1.12297006 (r27b); the app's libappmodules.so must use the
# same libc++ as the libc++_shared.so react-android ships.
NDK_ARCHIVES = {
    "linux": struct(
        url = "https://dl.google.com/android/repository/android-ndk-r27b-linux.zip",
        sha256 = "33e16af1a6bbabe12cad54b2117085c07eab7e4fa67cdd831805f0e94fd826c1",
        strip_prefix = "android-ndk-r27b",
        host_dir = "linux-x86_64",
    ),
    "macos": struct(
        url = "https://dl.google.com/android/repository/android-ndk-r27b-darwin.zip",
        sha256 = "cf9b9eef50841f409f586e7ae12901007c7f545722612065bd63afbab1844152",
        strip_prefix = "android-ndk-r27b",
        host_dir = "darwin-x86_64",
    ),
}
