import { runAll, runScenario } from "./harness.mjs";
import { scenarios } from "./scenarios.mjs";
import { writeFileSync } from "node:fs";

const mode = process.argv[2] ?? "full";
const outPath = process.argv[3] ?? "./results.json";

async function main() {
  if (mode === "smoke") {
    const subset = scenarios.slice(0, 3);
    const results = [];
    for (const s of subset) {
      process.stderr.write(`running ${s.id}...\n`);
      results.push(await runScenario(s));
    }
    writeFileSync(outPath, JSON.stringify(results, null, 2));
    console.log(`smoke test done, ${results.length} scenarios -> ${outPath}`);
    return;
  }
  const concurrency = Number(process.argv[4] ?? 6);
  const results = await runAll(scenarios, concurrency);
  writeFileSync(outPath, JSON.stringify(results, null, 2));
  console.log(`full run done, ${results.length} scenarios -> ${outPath}`);
}

main().catch((error) => {
  console.error("FATAL:", error);
  process.exit(1);
});
