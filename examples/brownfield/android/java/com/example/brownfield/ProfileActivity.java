package com.example.brownfield;

import android.os.Bundle;
import androidx.annotation.Nullable;
import com.facebook.react.ReactActivity;
import com.facebook.react.ReactActivityDelegate;
import com.facebook.react.defaults.DefaultNewArchitectureEntryPoint;
import com.facebook.react.defaults.DefaultReactActivityDelegate;

/** The one screen built in React Native; native code hands it initial props. */
public class ProfileActivity extends ReactActivity {
  static final String EXTRA_NAME = "name";

  @Override
  protected String getMainComponentName() {
    return "ProfileScreen";
  }

  @Override
  protected ReactActivityDelegate createReactActivityDelegate() {
    return new DefaultReactActivityDelegate(
        this, getMainComponentName(), DefaultNewArchitectureEntryPoint.getFabricEnabled()) {
      @Override
      protected @Nullable Bundle getLaunchOptions() {
        Bundle props = new Bundle();
        props.putString("name", getIntent().getStringExtra(EXTRA_NAME));
        props.putString("openedFrom", "NativeHomeActivity");
        return props;
      }
    };
  }
}
