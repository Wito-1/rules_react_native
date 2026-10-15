// protobuf-es needs TextEncoder and TextDecoder when it loads; Hermes ships only TextEncoder.
// Imported first from index.js, before anything that pulls in generated protobuf code.
import "fast-text-encoding";
