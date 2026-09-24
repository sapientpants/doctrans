// Runtime capability detection must be independent of the adapter being tested.
const supported: boolean = true
if (!supported) throw new Error("TypeScript capability probe failed")
