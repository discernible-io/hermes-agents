#!/usr/bin/env node
import { main } from "../src/server.mjs";

main().catch((err) => {
  console.error(JSON.stringify({ ok: false, error: err.message || String(err) }));
  process.exit(1);
});
