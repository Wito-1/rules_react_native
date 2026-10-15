package com.example.greeting;

import androidx.annotation.Nullable;
import com.example.greeting.specs.NativeLocalStorageSpec;
import com.facebook.react.BaseReactPackage;
import com.facebook.react.bridge.NativeModule;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.module.model.ReactModuleInfo;
import com.facebook.react.module.model.ReactModuleInfoProvider;
import com.facebook.react.uimanager.ViewManager;
import java.util.Collections;
import java.util.List;
import java.util.Map;

/** Registers the app's codegen'd TurboModule and Fabric component; listed in react_packages. */
public class AppSpecsPackage extends BaseReactPackage {
  @Override
  public @Nullable NativeModule getModule(String name, ReactApplicationContext context) {
    return NativeLocalStorageSpec.NAME.equals(name) ? new NativeLocalStorageModule(context) : null;
  }

  @Override
  public ReactModuleInfoProvider getReactModuleInfoProvider() {
    Map<String, ReactModuleInfo> infos =
        Collections.singletonMap(
            NativeLocalStorageSpec.NAME,
            new ReactModuleInfo(
                NativeLocalStorageSpec.NAME,
                NativeLocalStorageModule.class.getName(),
                /* canOverrideExistingModule= */ false,
                /* needsEagerInit= */ false,
                /* isCxxModule= */ false,
                /* isTurboModule= */ true));
    return () -> infos;
  }

  @Override
  public List<ViewManager> createViewManagers(ReactApplicationContext context) {
    return Collections.singletonList(new GreetingViewManager());
  }
}
