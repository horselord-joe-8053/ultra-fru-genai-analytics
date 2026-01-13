import { defineConfig } from "vite";
import react from "@vitejs/plugin-react-swc";

export default defineConfig({
  plugins: [react()],
  define: {
    // Inject build timestamp at build time
    BUILD_TIME: JSON.stringify(Date.now()),
  },
  server: {
    port: 5173,
    proxy: {
      "/query": {
        target: "http://localhost:5001",
        changeOrigin: true,
      },
      "/analytics": {
        target: "http://localhost:5001",
        changeOrigin: true,
      },
      "/query/stream": {
        target: "http://localhost:5001",
        changeOrigin: true,
      },
    },
  },
});
