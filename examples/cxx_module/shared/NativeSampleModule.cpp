#include "NativeSampleModule.h"

#include <algorithm>
#include <vector>

namespace facebook::react {

NativeSampleModule::NativeSampleModule(std::shared_ptr<CallInvoker> jsInvoker)
    : NativeSampleModuleCxxSpec(std::move(jsInvoker)) {}

std::string NativeSampleModule::reverseString(jsi::Runtime& rt, std::string input) {
  return std::string(input.rbegin(), input.rend());
}

double NativeSampleModule::nthPrime(jsi::Runtime& rt, double n) {
  auto target = static_cast<size_t>(std::max(1.0, n));
  std::vector<long> primes;
  for (long candidate = 2; primes.size() < target; ++candidate) {
    bool isPrime = true;
    for (long p : primes) {
      if (p * p > candidate) {
        break;
      }
      if (candidate % p == 0) {
        isPrime = false;
        break;
      }
    }
    if (isPrime) {
      primes.push_back(candidate);
    }
  }
  return static_cast<double>(primes.back());
}

} // namespace facebook::react
