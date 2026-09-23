const request = require('supertest');
const app = require('../src/app');
const { pool } = require('../src/db');

afterAll(async () => {
  await pool.end();
});

describe('GET /health', () => {
  it('returns 200 ok without needing a database connection', async () => {
    const res = await request(app).get('/health');
    expect(res.statusCode).toBe(200);
    expect(res.body).toEqual({ status: 'ok' });
  });
});

describe('POST /api/items', () => {
  it('rejects a request with no name', async () => {
    const res = await request(app).post('/api/items').send({});
    expect(res.statusCode).toBe(400);
    expect(res.body).toHaveProperty('error');
  });
});
