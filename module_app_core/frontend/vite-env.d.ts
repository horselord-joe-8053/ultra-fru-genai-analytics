/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_FRONTEND_POLL_FREQUENCY_IN_SEC?: string;
  readonly VITE_FRONTEND_EXEC_LOG_PANEL_WIDTH_PERCENT?: string;
  readonly VITE_FRONTEND_BATCH_ANALYTIC_PANEL_WIDTH_PERCENT?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

