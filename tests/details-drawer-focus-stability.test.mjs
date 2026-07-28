import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const source=fs.readFileSync(new URL("../src/ui/foundation.jsx",import.meta.url),"utf8");

test("details drawer does not rerun focus lifecycle when inline onClose changes",()=>{
  assert.match(source,/const onCloseRef = useRef\(onClose\)/);
  assert.match(source,/onCloseRef\.current = onClose/);
  assert.match(source,/onCloseRef\.current\?\.\(\)/);
  assert.match(source,/\}, \[open\]\);/);
  assert.doesNotMatch(source,/\[onClose, open\]/);
});
