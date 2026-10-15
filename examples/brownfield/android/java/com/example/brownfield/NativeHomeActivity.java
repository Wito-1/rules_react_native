package com.example.brownfield;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

/** The existing, fully native app. React Native only appears behind one button. */
public class NativeHomeActivity extends Activity {
  @Override
  protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    LinearLayout layout = new LinearLayout(this);
    layout.setOrientation(LinearLayout.VERTICAL);
    layout.setGravity(Gravity.CENTER);
    layout.setPadding(64, 64, 64, 64);

    TextView title = new TextView(this);
    title.setText("Native home screen");
    title.setTextSize(24);
    layout.addView(title);

    EditText name = new EditText(this);
    name.setHint("Your name");
    name.setText("Ada");
    layout.addView(name);

    Button open = new Button(this);
    open.setText("Open React Native profile");
    open.setOnClickListener(
        v -> {
          Intent intent = new Intent(this, ProfileActivity.class);
          intent.putExtra(ProfileActivity.EXTRA_NAME, name.getText().toString());
          startActivity(intent);
        });
    layout.addView(open);
    setContentView(layout);
  }
}
