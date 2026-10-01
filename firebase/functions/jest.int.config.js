// Integration tests (*.int.test.ts) — run against the LOCAL Firestore emulator,
// never real data: `npm run test:int` starts the emulator, sets
// FIRESTORE_EMULATOR_HOST, runs these, and shuts it down. Kept out of the
// default `npm test` (see package.json) because they need Java + the emulator.
module.exports = {
  preset: "ts-jest",
  testEnvironment: "node",
  testMatch: ["**/*.int.test.ts"],
  testPathIgnorePatterns: ["/node_modules/", "/lib/"],
  testTimeout: 30000,
};
