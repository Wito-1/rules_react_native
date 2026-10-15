import type { TurboModule } from "react-native";
import { TurboModuleRegistry } from "react-native";

export interface Spec extends TurboModule {
  readonly reverseString: (input: string) => string;
  readonly nthPrime: (n: number) => number;
}

export default TurboModuleRegistry.getEnforcing<Spec>("NativeSampleModule");
