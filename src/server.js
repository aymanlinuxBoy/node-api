const app = require('./app');
const { initSchema } = require('./db');

const PORT = process.env.PORT || 3000;

async function start() {
  await initSchema();
  app.listen(PORT, () => {
    console.log(`node-api-poc listening on port ${PORT}`);
  });
}

start().catch((err) => {
  console.error('Failed to start server:', err);
  process.exit(1);
});
