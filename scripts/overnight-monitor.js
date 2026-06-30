#!/usr/bin/env node
'use strict';

const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const { spawnSync } = require('child_process');

const project = path.resolve(__dirname, '..');
const artifactsDir = path.join(project, 'artifacts');
const host = process.env.IPHONE_SECURITYCAM_HOST || process.env.DEVICE_IP || '';
const statusUrl = process.env.IPHONE_SECURITYCAM_STATUS_URL || (host ? `http://${host}:8080/status` : '');
const rtspUrl = process.env.IPHONE_SECURITYCAM_RTSP_URL || (host ? `rtsp://${host}:8554/live` : '');
const intervalSeconds = Number(process.env.INTERVAL_SECONDS || 60);
const durationSeconds = Number(process.env.DURATION_SECONDS || 8 * 60 * 60);
const outputPath = process.env.OUT || path.join(artifactsDir, `overnight-${new Date().toISOString().replace(/[:.]/g, '-')}.jsonl`);

if (!statusUrl || !rtspUrl) {
  console.error('Set DEVICE_IP, IPHONE_SECURITYCAM_HOST, or explicit IPHONE_SECURITYCAM_STATUS_URL and IPHONE_SECURITYCAM_RTSP_URL.');
  process.exit(2);
}

fs.mkdirSync(path.dirname(outputPath), { recursive: true });

function requestJson(url, timeoutMs = 5000) {
  return new Promise((resolve) => {
    const client = url.startsWith('https:') ? https : http;
    const req = client.get(url, { timeout: timeoutMs }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        body += chunk;
      });
      res.on('end', () => {
        try {
          resolve({ ok: res.statusCode >= 200 && res.statusCode < 300, statusCode: res.statusCode, body: JSON.parse(body) });
        } catch (error) {
          resolve({ ok: false, statusCode: res.statusCode, error: `invalid json: ${error.message}`, body });
        }
      });
    });
    req.on('timeout', () => {
      req.destroy(new Error('timeout'));
    });
    req.on('error', (error) => {
      resolve({ ok: false, error: error.message });
    });
  });
}

function probeRtsp(url) {
  const result = spawnSync('ffprobe', [
    '-v', 'error',
    '-rtsp_transport', 'tcp',
    '-select_streams', 'v:0',
    '-show_entries', 'stream=codec_name,width,height,r_frame_rate',
    '-of', 'json',
    url,
  ], { encoding: 'utf8', timeout: 12000 });

  if (result.status !== 0) {
    return { ok: false, error: (result.stderr || result.stdout || `ffprobe exited ${result.status}`).trim() };
  }
  try {
    const parsed = JSON.parse(result.stdout || '{}');
    return { ok: true, stream: parsed.streams && parsed.streams[0] ? parsed.streams[0] : null };
  } catch (error) {
    return { ok: false, error: `invalid ffprobe json: ${error.message}` };
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const startedAt = Date.now();
  const endAt = startedAt + durationSeconds * 1000;
  let sample = 0;
  let lastFrames = null;

  console.log(`Writing monitor log to ${outputPath}`);
  console.log(`Status: ${statusUrl}`);
  console.log(`RTSP:   ${rtspUrl}`);

  while (Date.now() <= endAt) {
    const timestamp = new Date().toISOString();
    const status = await requestJson(statusUrl);
    const rtsp = probeRtsp(rtspUrl);
    const encodedFrames = status.ok && status.body ? Number(status.body.encodedFrames || 0) : null;
    const frameDelta = encodedFrames !== null && lastFrames !== null ? encodedFrames - lastFrames : null;
    if (encodedFrames !== null) {
      lastFrames = encodedFrames;
    }

    const row = {
      sample,
      timestamp,
      statusUrl,
      rtspUrl,
      statusOk: status.ok,
      rtspOk: rtsp.ok,
      encodedFrames,
      frameDelta,
      thermalState: status.body && status.body.thermalState,
      batteryLevel: status.body && status.body.batteryLevel,
      batteryState: status.body && status.body.batteryState,
      captureRunning: status.body && status.body.captureRunning,
      lastCaptureEvent: status.body && status.body.lastCaptureEvent,
      thermalPaused: status.body && status.body.thermalPaused,
      host: status.body && status.body.host,
      statusError: status.error,
      rtspError: rtsp.error,
      rtspStream: rtsp.stream,
    };

    fs.appendFileSync(outputPath, `${JSON.stringify(row)}\n`);
    console.log(`${timestamp} status=${row.statusOk ? 'ok' : 'fail'} rtsp=${row.rtspOk ? 'ok' : 'fail'} frames=${encodedFrames === null ? 'n/a' : encodedFrames} delta=${frameDelta === null ? 'n/a' : frameDelta} thermal=${row.thermalState || 'n/a'} battery=${row.batteryLevel === undefined ? 'n/a' : row.batteryLevel}`);

    sample += 1;
    await sleep(intervalSeconds * 1000);
  }
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});
