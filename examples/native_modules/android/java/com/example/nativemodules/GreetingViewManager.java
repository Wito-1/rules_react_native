package com.example.nativemodules;

import android.view.Gravity;
import android.widget.TextView;
import androidx.annotation.Nullable;
import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.ReactContext;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.common.MapBuilder;
import com.facebook.react.uimanager.SimpleViewManager;
import com.facebook.react.uimanager.ThemedReactContext;
import com.facebook.react.uimanager.UIManagerHelper;
import com.facebook.react.uimanager.ViewManagerDelegate;
import com.facebook.react.uimanager.annotations.ReactProp;
import com.facebook.react.uimanager.events.Event;
import com.facebook.react.uimanager.events.EventDispatcher;
import com.facebook.react.viewmanagers.GreetingViewManagerDelegate;
import com.facebook.react.viewmanagers.GreetingViewManagerInterface;
import java.util.Map;

/** Native side of the GreetingView Fabric component: a TextView that reports taps to JS. */
public class GreetingViewManager extends SimpleViewManager<TextView>
    implements GreetingViewManagerInterface<TextView> {
  public static final String NAME = "GreetingView";
  private static final String PRESS_EVENT = "topGreetingPress";

  private final ViewManagerDelegate<TextView> delegate = new GreetingViewManagerDelegate<>(this);

  @Override
  protected ViewManagerDelegate<TextView> getDelegate() {
    return delegate;
  }

  @Override
  public String getName() {
    return NAME;
  }

  @Override
  protected TextView createViewInstance(ThemedReactContext context) {
    TextView view = new TextView(context);
    view.setGravity(Gravity.CENTER);
    view.setTextSize(20);
    view.setBackgroundColor(0xFFE8F0FE);
    view.setOnClickListener(
        v -> {
          EventDispatcher dispatcher =
              UIManagerHelper.getEventDispatcherForReactTag((ReactContext) v.getContext(), v.getId());
          if (dispatcher != null) {
            dispatcher.dispatchEvent(
                new PressEvent(
                    UIManagerHelper.getSurfaceId(v), v.getId(), ((TextView) v).getText().toString()));
          }
        });
    return view;
  }

  @Override
  @ReactProp(name = "text")
  public void setText(TextView view, @Nullable String value) {
    view.setText(value);
  }

  @Override
  public Map<String, Object> getExportedCustomDirectEventTypeConstants() {
    return MapBuilder.<String, Object>of(PRESS_EVENT, MapBuilder.of("registrationName", "onGreetingPress"));
  }

  private static final class PressEvent extends Event<PressEvent> {
    private final String text;

    PressEvent(int surfaceId, int viewId, String text) {
      super(surfaceId, viewId);
      this.text = text;
    }

    @Override
    public String getEventName() {
      return PRESS_EVENT;
    }

    @Override
    protected WritableMap getEventData() {
      WritableMap data = Arguments.createMap();
      data.putString("text", text);
      return data;
    }
  }
}
