# FRU Analytics Frontend

React + Vite + Tailwind single-page app that talks to the FRU backend `/query` endpoint.

## Dev setup

1. Ensure the backend API is running and listening on `http://localhost:5000/query`
   (e.g. via `python backend/api/app.py` or docker-compose for db + api).

2. Install dependencies:

   ```bash
   cd frontend
   npm install
   ```

3. Start dev server:

   ```bash
   npm run dev
   ```

   This serves the app on `http://localhost:5173`.

4. Open the URL in the browser and start asking questions like:

   - "Why are Samsung customers unhappy?"
   - "Which store has the most negative feedback?"

## How it talks to the backend

- The frontend calls `fetch("/query", ...)`.
- Vite's dev server is configured with a proxy in `vite.config.ts`:

  ```ts
  server: {
    proxy: {
      "/query": {
        target: "http://localhost:5000",
        changeOrigin: true,
      },
    },
  }
  ```

- In production, you would typically:
  - serve the built assets from a static host or CDN
  - route `/query` to the Flask API (via Nginx, ALB, or API Gateway).

## Layout

- Left: chat interface.
- Right: analytics panel, showing:
  - total matches
  - counts by brand, store, rating
  - sample records in a compact table.
