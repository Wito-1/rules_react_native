"""Expo modules: the generated `expo.modules.ExpoModulesPackageList`."""

load(":library.bzl", "react_native_android_library")

def _kotlin_string(s):
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$")

def _expo_package_list_source_impl(ctx):
    packages = ",\n".join(["      %s()" % p for p in ctx.attr.packages])
    modules = ",\n".join([
        "      %s::class.java to %s" % (cls, _kotlin_string(name) if name else "null")
        for cls, name in sorted(ctx.attr.modules.items())
    ])
    services = ",\n".join(["      %s::class.java" % s for s in ctx.attr.services])

    # Same class as expo-modules-autolinking's GeneratePackagesListTask writes; ExpoModulesPackage
    # finds it by name through reflection.
    content = """package expo.modules

import expo.modules.core.interfaces.Package
import expo.modules.kotlin.ModulesProvider
import expo.modules.kotlin.modules.Module

class ExpoModulesPackageList : ModulesProvider {
  companion object {
    val packagesList: List<Package> = listOf<Package>(
%s
    )

    val modulesMap: Map<Class<out Module>, String?> = mapOf<Class<out Module>, String?>(
%s
    )

    @JvmStatic
    fun getPackageList(): List<Package> {
      return packagesList
    }
  }

  override fun getModulesMap(): Map<Class<out Module>, String?> {
    return modulesMap
  }

  override fun getServices(): List<Class<out expo.modules.kotlin.services.Service>> {
    return listOf<Class<out expo.modules.kotlin.services.Service>>(
%s
    )
  }
}
""" % (packages, modules, services)
    out = ctx.actions.declare_file(ctx.label.name + "/ExpoModulesPackageList.kt")
    ctx.actions.write(out, content)
    return [DefaultInfo(files = depset([out]))]

_expo_package_list_source = rule(
    implementation = _expo_package_list_source_impl,
    attrs = {
        "modules": attr.string_dict(),
        "packages": attr.string_list(),
        "services": attr.string_list(),
    },
)

def react_native_expo_package_list(name, packages = [], modules = {}, services = [], deps = [], **kwargs):
    """`expo.modules.ExpoModulesPackageList`: the Expo modules, packages and services an app links.

    What Expo's Gradle plugin generates from `expo-modules-autolinking resolve`; `react_native_autolink`
    writes this target for apps that depend on `expo`. The `expo` package's ExpoModulesPackage loads
    it by name.

    Args:
        name: Target name.
        packages: `expo.modules.core.interfaces.Package` classes, instantiated in this order.
        modules: Expo module classes, `{class: name}`; an empty name keeps the module's own.
        services: `expo.modules.kotlin.services.Service` classes.
        deps: The Expo module libraries that define those classes.
        **kwargs: Common attributes (visibility, tags).
    """
    _expo_package_list_source(
        name = name + "_src",
        packages = packages,
        modules = modules,
        services = services,
        visibility = ["//visibility:private"],
        tags = kwargs.get("tags"),
    )
    # An Android library rather than a plain Java one: it compiles against react-android (and its
    # Kotlin stdlib), like the modules it lists.
    react_native_android_library(
        name = name,
        srcs = [":%s_src" % name],
        package = "expo.modules.packagelist",
        deps = deps,
        **kwargs
    )
