import { act, create } from "react-test-renderer";
import { App } from "./App";

test("the counter goes up when the button is pressed", async () => {
  let renderer!: ReturnType<typeof create>;
  await act(async () => {
    renderer = create(<App />);
  });
  const label = () => renderer.root.findAll((node) => node.props.children?.[0] === "Pressed ")[0].props.children.join("");
  expect(label()).toBe("Pressed 0 times");
  const button = renderer.root.findAll((node) => typeof node.props.onPress === "function")[0];
  await act(async () => {
    button.props.onPress();
  });
  expect(label()).toBe("Pressed 1 times");
});
