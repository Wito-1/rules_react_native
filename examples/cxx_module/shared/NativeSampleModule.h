#pragma once

#include <AppSpecsJSI.h>

#include <memory>
#include <string>

namespace facebook::react {

// One implementation for Android and iOS: no Java, no Objective-C.
class NativeSampleModule : public NativeSampleModuleCxxSpec<NativeSampleModule> {
 public:
  explicit NativeSampleModule(std::shared_ptr<CallInvoker> jsInvoker);

  std::string reverseString(jsi::Runtime& rt, std::string input);

  double nthPrime(jsi::Runtime& rt, double n);
};

} // namespace facebook::react
