// 전체 98개를 다시 돌리지 않고, 지정한 id들만 재실행한다(수정 검증 + 이전에 일시적
// 오류로 끝난 케이스 재확인용).
import { runAll } from "./harness.mjs";
import { scenarios } from "./scenarios.mjs";
import { writeFileSync } from "node:fs";

const ids = process.argv[2].split(",");
const outPath = process.argv[3] ?? "./subset_results.json";
const concurrency = Number(process.argv[4] ?? 1);

const subset = scenarios.filter((s) => ids.includes(s.id));
console.log(`running ${subset.length}/${ids.length} requested scenarios`);

runAll(subset, concurrency).then((results) => {
  writeFileSync(outPath, JSON.stringify(results, null, 2));
  console.log(`done -> ${outPath}`);
});
