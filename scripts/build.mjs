import { build } from "vite";
import react from "@vitejs/plugin-react";

await build({
  configFile: false,
  plugins: [react()],
  build: { outDir: "dist", emptyOutDir: true },
});
