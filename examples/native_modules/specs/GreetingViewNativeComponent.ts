import type { CodegenTypes, HostComponent, ViewProps } from "react-native";
import { codegenNativeComponent } from "react-native";

export interface NativeProps extends ViewProps {
  text: string;
  onGreetingPress?: CodegenTypes.DirectEventHandler<{ text: string }>;
}

export default codegenNativeComponent<NativeProps>("GreetingView") as HostComponent<NativeProps>;
