// Stub suite. The real Model.js harness lands with the model task; until then
// this keeps the name run.sh registers green, printing the same summary shape
// as the other node suites.

const pass = 0;
const fail = 0;

console.log("\nmodel: " + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
