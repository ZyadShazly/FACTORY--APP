import { createServer } from "vite";
import react from "@vitejs/plugin-react";

const server = await createServer({
  configFile: false,
  plugins: [react()],
  server: { host: "127.0.0.1" },
});
await server.listen();
server.printUrls();
