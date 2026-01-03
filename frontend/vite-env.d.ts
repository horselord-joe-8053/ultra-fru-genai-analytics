/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_FRONTEND_POLL_FREQUENCY_IN_SEC?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

