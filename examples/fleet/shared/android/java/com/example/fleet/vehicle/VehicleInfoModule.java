package com.example.fleet.vehicle;

import android.os.Build;
import com.example.fleet.vehicle.specs.NativeVehicleInfoSpec;
import com.facebook.react.bridge.ReactApplicationContext;

/** One implementation of the shared spec; each app reports its own role from its manifest. */
public class VehicleInfoModule extends NativeVehicleInfoSpec {
  public VehicleInfoModule(ReactApplicationContext context) {
    super(context);
  }

  @Override
  public String getDeviceModel() {
    return Build.MANUFACTURER + " " + Build.MODEL;
  }

  @Override
  public String getAppRole() {
    return getReactApplicationContext().getString(R.string.fleet_app_role);
  }
}
