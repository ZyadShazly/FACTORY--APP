import { execFileSync } from "node:child_process";

function git(args) {
  return execFileSync("git", args, { encoding: "utf8" }).trim();
}

const status = git(["status", "--porcelain", "--untracked-files=no"]);
if (status) {
  console.error("Tracked files changed during install/test/build:\n" + status);
  process.exit(1);
}

console.log("Tracked working tree remained clean after install/test/build.");
