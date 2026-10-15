<!-- Generated with Stardoc: http://skydoc.bazel.build -->

The `react_native` module extension.

The ruleset owns the Android SDK, NDK and its host tool jars (`@rn_android_sdk`, `@rn_android_ndk`,
`@rn_android_tools_maven`, `@rn_kotlin_compiler_maven`). Each consumer supplies the React Native artifact sets it builds against:

```starlark
react_native = use_extension("@rules_react_native//react_native:extensions.bzl", "react_native")
react_native.maven(name = "rn_maven", lock_file = "//android:maven_lock.json")
react_native.maven(name = "rn_maven_debug", lock_file = "//android:maven_debug_lock.json")
```

The react-android version in those lockfiles selects a toolchain profile (compileSdk, build-tools,
NDK, native compile flags) from `REACT_NATIVE_PROFILES`; an unsupported version fails here rather
than producing an app that crashes at startup. The root module can override the SDK/NDK choice
with `react_native.android_toolchain`.

The rules default to the release and debug sets (told apart by each lockfile's `build_type`), so
consumers only `use_repo` the hubs to reference individual artifacts.

<a id="react_native"></a>

## react_native

<pre>
react_native = use_extension("@rules_react_native//react_native:extensions.bzl", "react_native")
react_native.android_toolchain(<a href="#react_native.android_toolchain-build_tools">build_tools</a>, <a href="#react_native.android_toolchain-compile_sdk">compile_sdk</a>, <a href="#react_native.android_toolchain-ndk">ndk</a>)
react_native.maven(<a href="#react_native.maven-name">name</a>, <a href="#react_native.maven-lock_file">lock_file</a>)
</pre>

Android SDK and NDK, the ruleset's host tools, and each consumer's React Native Maven artifact sets.


**TAG CLASSES**

<a id="react_native.android_toolchain"></a>

### android_toolchain

Overrides the SDK/NDK the React Native profile picks. Root module only; values must be pinned in versions.bzl.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="react_native.android_toolchain-build_tools"></a>build_tools |  e.g. "37.0.0"   | String | optional |  `""`  |
| <a id="react_native.android_toolchain-compile_sdk"></a>compile_sdk |  e.g. 37   | Integer | optional |  `0`  |
| <a id="react_native.android_toolchain-ndk"></a>ndk |  e.g. "27.1.12297006"   | String | optional |  `""`  |

<a id="react_native.maven"></a>

### maven

An Android Maven artifact set (react-android, hermes-android and their closure), pinned by `react_native_maven_pin`.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="react_native.maven-name"></a>name |  Repository name; `@<name>//:all` is the whole set.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="react_native.maven-lock_file"></a>lock_file |  Lockfile written by `react_native_maven_pin`. Its `build_type` makes it the default release or debug set.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |


