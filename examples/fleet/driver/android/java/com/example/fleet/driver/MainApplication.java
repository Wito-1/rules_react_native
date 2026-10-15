package com.example.fleet.driver;

import static com.facebook.react.ReactNativeApplicationEntryPoint.loadReactNative;

import android.app.Application;
import com.facebook.react.PackageList;
import com.facebook.react.ReactApplication;
import com.facebook.react.ReactHost;
import com.facebook.react.defaults.DefaultReactHost;

public class MainApplication extends Application implements ReactApplication {
  private ReactHost reactHost;

  @Override
  public ReactHost getReactHost() {
    if (reactHost == null) {
      // Java can't use the Kotlin default arguments the stock template relies on, so every
      // parameter of getDefaultReactHost is spelled out with its default.
      reactHost =
          DefaultReactHost.getDefaultReactHost(
              getApplicationContext(),
              new PackageList(this).getPackages(),
              "index",
              "index.android.bundle",
              null,
              null,
              BuildConfig.DEBUG,
              java.util.Collections.emptyList(),
              e -> {
                throw new RuntimeException(e);
              },
              null);
    }
    return reactHost;
  }

  @Override
  public void onCreate() {
    super.onCreate();
    loadReactNative(this);
  }
}
