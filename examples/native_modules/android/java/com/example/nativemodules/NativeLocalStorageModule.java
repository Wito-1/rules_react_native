package com.example.nativemodules;

import android.content.Context;
import android.content.SharedPreferences;
import androidx.annotation.Nullable;
import com.example.nativemodules.specs.NativeLocalStorageSpec;
import com.facebook.react.bridge.ReactApplicationContext;

/** Implements the NativeLocalStorage TurboModule spec on top of SharedPreferences. */
public class NativeLocalStorageModule extends NativeLocalStorageSpec {
  public NativeLocalStorageModule(ReactApplicationContext context) {
    super(context);
  }

  private SharedPreferences prefs() {
    return getReactApplicationContext().getSharedPreferences("local_storage", Context.MODE_PRIVATE);
  }

  @Override
  public void setItem(String value, String key) {
    prefs().edit().putString(key, value).apply();
  }

  @Override
  public @Nullable String getItem(String key) {
    return prefs().getString(key, null);
  }

  @Override
  public void removeItem(String key) {
    prefs().edit().remove(key).apply();
  }

  @Override
  public void clear() {
    prefs().edit().clear().apply();
  }
}
