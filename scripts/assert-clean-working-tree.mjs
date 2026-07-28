import { execFileSync } from "node:child_process";

function git(args) {
  return execFileSync("git", args, { encoding: "utf8" }).trim();
}

const status = git(["status", "--porcelain", "--untracked-files=all"]);
if (status) {
  console.error("Working tree changed during install/test/build:\n" + status);
  process.exit(1);
}

console.log("Working tree remained clean after install/test/build.");
