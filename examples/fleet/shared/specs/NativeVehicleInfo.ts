import type { TurboModule } from "react-native";
import { TurboModuleRegistry } from "react-native";

export interface Spec extends TurboModule {
  getDeviceModel(): string;
  getAppRole(): string;
}

export default TurboModuleRegistry.getEnforcing<Spec>("NativeVehicleInfo");
