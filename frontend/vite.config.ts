import { defineConfig } from "vite";
import react from "@vitejs/plugin-react-swc";

export default defineConfig({
  plugins: [react()],
  define: {
    // Inject build timestamp at build time
    // This is evaluated when Vite processes the config, ensuring BUILD_TIME reflects the actual build time
    BUILD_TIME: JSON.stringify(Date.now()),
    // Inject build context (provider, container type, environment) from environment variables
    // These are set by deployment scripts before npm run build
    BUILD_PROVIDER: JSON.stringify(process.env.VITE_PROVIDER || "local"),
    BUILD_CONTAINER_TYPE: JSON.stringify(process.env.VITE_CONTAINER_TYPE || "none"),
    BUILD_ENVIRONMENT: JSON.stringify(process.env.VITE_ENVIRONMENT || "dev"),
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
