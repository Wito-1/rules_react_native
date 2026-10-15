package com.example.fleet.vehicle;

import androidx.annotation.Nullable;
import com.example.fleet.vehicle.specs.NativeVehicleInfoSpec;
import com.facebook.react.BaseReactPackage;
import com.facebook.react.bridge.NativeModule;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.module.model.ReactModuleInfo;
import com.facebook.react.module.model.ReactModuleInfoProvider;
import java.util.Collections;
import java.util.Map;

public class VehiclePackage extends BaseReactPackage {
  @Override
  public @Nullable NativeModule getModule(String name, ReactApplicationContext context) {
    return NativeVehicleInfoSpec.NAME.equals(name) ? new VehicleInfoModule(context) : null;
  }

  @Override
  public ReactModuleInfoProvider getReactModuleInfoProvider() {
    Map<String, ReactModuleInfo> infos =
        Collections.singletonMap(
            NativeVehicleInfoSpec.NAME,
            new ReactModuleInfo(
                NativeVehicleInfoSpec.NAME,
                VehicleInfoModule.class.getName(),
                /* canOverrideExistingModule= */ false,
                /* needsEagerInit= */ false,
                /* isCxxModule= */ false,
                /* isTurboModule= */ true));
    return () -> infos;
  }
}
