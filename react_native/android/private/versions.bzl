"""Pinned Android SDK/NDK archives and the React Native versions they serve.

Archives come from https://dl.google.com/android/repository/repository2-3.xml. To support a new
React Native minor, add a REACT_NATIVE_PROFILES entry after checking, at that release's tag:
  - `ndkVersion`, `compileSdk`, `buildTools` in packages/react-native/gradle/libs.versions.toml;
  - ReactAndroid/cmake-utils/default-app-setup/OnLoad.cpp against android/native/OnLoad.cpp;
  - the flags in ReactCommon/cmake-utils/react-native-flags.cmake and
    ReactAndroid/cmake-utils/folly-flags.cmake against appmodules.bzl;
  - GenerateEntryPointTask / GeneratePackageListTask in the gradle plugin against android_app.bzl.
"""

PLATFORMS = {
    36: struct(
        url = "https://dl.google.com/android/repository/platform-36_r02.zip",
        sha256 = "37607369a28c5b640b3a7998868d45898ebcb777565a0e85f9acf36f29631d2e",
        strip_prefix = "android-36",
    ),
    37: struct(
        url = "https://dl.google.com/android/repository/platform-37.0_r02.zip",
        sha256 = "840b23e827f96e64aea4c89a1194aac3dc5f6bad37edb231c5c795d890330e8d",
        strip_prefix = "android-37.0",
    ),
}

# build-tools 36's archive root is "android-16" on every host; 37 finally names it after itself.
# The macOS binaries are universal (x86_64 + arm64).
BUILD_TOOLS = {
    "36.0.0": {
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
    },
    "37.0.0": {
        "linux": struct(
            url = "https://dl.google.com/android/repository/build-tools_r37_linux.zip",
            sha256 = "01af179347cbcd9c208b7f8171f7b21f6dd1d2f85bcd15e88caa51d5d7b86060",
            strip_prefix = "android-37.0",
        ),
        "macos": struct(
            url = "https://dl.google.com/android/repository/build-tools_r37_macosx.zip",
            sha256 = "b5b1ac529028a49f11b596b89d9b34252e0f39388ee7dbd16ae3110f1c9c5722",
            strip_prefix = "android-37.0",
        ),
    },
}

PLATFORM_TOOLS = {
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

# The app's libappmodules.so must use the same libc++ as the libc++_shared.so react-android ships,
# so the NDK follows React Native's `ndkVersion`.
NDKS = {
    "27.1.12297006": {
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
    },
}

# Keyed by React Native minor version, as read from the consumer's react-android lockfile entry.
#   compile_sdk / build_tools / ndk: React Native's gradle/libs.versions.toml at that release.
#   appmodules_copts: what react-native-flags.cmake adds beyond the flags shared by every version.
REACT_NATIVE_PROFILES = {
    "0.86": struct(
        compile_sdk = 36,
        build_tools = "36.0.0",
        ndk = "27.1.12297006",
        appmodules_copts = [],
    ),
    "0.87": struct(
        compile_sdk = 37,
        build_tools = "37.0.0",
        ndk = "27.1.12297006",
        # react-native-flags.cmake defines this unconditionally from 0.87 on (Hermes V1).
        appmodules_copts = ["-DHERMES_V1_ENABLED=1"],
    ),
}

# Used when no consumer pins react-android, e.g. building this module's own tests.
DEFAULT_PROFILE = "0.87"
