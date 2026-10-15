import { GreeterService } from "@examples/greeter-proto";

/** The GreeterService implementation, shared by the server and its in-process test. */
export function routes(router) {
  let count = 0n;
  router.service(GreeterService, {
    greet(request) {
      count += 1n;
      const name = request.name.trim() || "stranger";
      return { greeting: `Hello, ${name}!`, servedBy: "node", count };
    },
  });
}
