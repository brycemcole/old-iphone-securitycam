#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');

const HOME = process.env.HOME || os.homedir();
const PROJECT = path.resolve(__dirname, '..');
const SCRYPTED_HOME = path.join(HOME, '.scrypted');
const HOST = process.env.SCRYPTED_HOST || '127.0.0.1:10443';
const DEVICE_NAME = process.env.IPHONE_SECURITYCAM_NAME || 'iPhone SE SecurityCam';
const BONJOUR_TYPE = '_oldiphonecam._tcp';
const FFPROBE = findCommand('ffprobe');
const DISCOVERED_PHONE = discoverPhoneHost();
const PHONE_HOST = process.env.IPHONE_SECURITYCAM_HOST || process.env.DEVICE_IP || DISCOVERED_PHONE.host || '';
const RTSP_URL = process.env.IPHONE_SECURITYCAM_RTSP_URL || (PHONE_HOST ? `rtsp://${PHONE_HOST}:8554/live` : '');
const STATUS_URL = process.env.IPHONE_SECURITYCAM_STATUS_URL || (PHONE_HOST ? `http://${PHONE_HOST}:8080/status` : '');
const SNAPSHOT_URL = process.env.IPHONE_SECURITYCAM_SNAPSHOT_URL || (PHONE_HOST ? `http://${PHONE_HOST}:8080/snapshot.jpg` : '');
const SCRIPT_PATH = path.join(PROJECT, 'scrypted/iphone-se-securitycam.ts');
const PREBUFFER_PLUGIN = '@scrypted/prebuffer-mixin';
const APPLY = process.argv.includes('--apply');
const SKIP_STREAM = process.argv.includes('--skip-stream');

function findCommand(name) {
  const result = spawnSync('/bin/sh', ['-lc', `command -v ${name}`], {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: process.env.PATH || '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
    },
  });
  return result.status === 0 ? result.stdout.trim() : '';
}

function run(command, args, options = {}) {
  return spawnSync(command, args, {
    cwd: options.cwd || HOME,
    encoding: 'utf8',
    timeout: options.timeout || 15000,
    env: {
      ...process.env,
      HOME,
      PATH: process.env.PATH || '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
    },
  });
}

function discoverPhoneHost() {
  if (process.env.IPHONE_SECURITYCAM_HOST || process.env.DEVICE_IP || process.env.IPHONE_SECURITYCAM_RTSP_URL)
    return {};
  if (!fs.existsSync('/usr/bin/dns-sd'))
    return {};

  const browse = run('/usr/bin/dns-sd', ['-B', BONJOUR_TYPE, 'local.'], { timeout: 5000 });
  const browseOutput = `${browse.stdout || ''}${browse.stderr || ''}`;
  const serviceLine = browseOutput
    .split(/\r?\n/)
    .find(line => line.includes('Add') && line.includes(BONJOUR_TYPE));
  const serviceName = serviceLine?.match(new RegExp(`${BONJOUR_TYPE.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\.?\\s+(.+)$`))?.[1]?.trim();
  if (!serviceName)
    return {};

  const lookup = run('/usr/bin/dns-sd', ['-L', serviceName, BONJOUR_TYPE, 'local.'], { timeout: 5000 });
  const lookupOutput = `${lookup.stdout || ''}${lookup.stderr || ''}`;
  const reached = lookupOutput.match(/can be reached at ([^:]+):(\d+)/);
  if (!reached)
    return { serviceName };

  return {
    serviceName,
    host: reached[1].replace(/\.$/, ''),
    httpPort: Number(reached[2]),
  };
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function findScryptedClientModule() {
  const candidates = [
    process.env.SCRYPTED_CLIENT_MODULE,
    path.join(HOME, '.npm/_npx/f8ff587849d254b8/node_modules/@scrypted/client'),
  ].filter(Boolean);

  const npxHome = path.join(HOME, '.npm/_npx');
  try {
    for (const entry of fs.readdirSync(npxHome))
      candidates.push(path.join(npxHome, entry, 'node_modules/@scrypted/client'));
  } catch {}

  for (const candidate of candidates) {
    if (fs.existsSync(candidate))
      return candidate;
  }

  return '@scrypted/client';
}

async function connectScrypted() {
  const loginMap = readJson(path.join(SCRYPTED_HOME, 'login.json'), {});
  const login = loginMap[HOST] || loginMap[`localhost:${HOST.split(':').at(-1)}`];
  if (!login)
    throw new Error(`Missing Scrypted login for ${HOST}. Run: npx scrypted login ${HOST}`);

  const { connectScryptedClient } = require(findScryptedClientModule());
  const originalLog = console.log;
  try {
    console.log = () => {};
    return await connectScryptedClient({
      baseUrl: `https://${HOST}`,
      pluginId: '@scrypted/core',
      username: login.username,
      password: login.token,
    });
  } finally {
    console.log = originalLog;
  }
}

function serviceSnapshot() {
  const result = run('/bin/launchctl', ['print', `gui/${process.getuid()}/app.scrypted.server`], { timeout: 10000 });
  const text = `${result.stdout || ''}${result.stderr || ''}`;
  return {
    ok: result.status === 0 && /\bstate = running\b/.test(text),
    state: (text.match(/\bstate = (\S+)/) || [])[1] || null,
    pid: (text.match(/\bpid = (\d+)/) || [])[1] || null,
  };
}

function httpsReady() {
  const result = run('/usr/bin/curl', ['-k', '-sS', '-I', '--max-time', '8', `https://${HOST}`], { timeout: 12000 });
  return {
    ok: result.status === 0 && /^HTTP\/.* (200|302)\b/m.test(result.stdout || ''),
    statusLine: (result.stdout || result.stderr || '').split('\n').find(line => line.startsWith('HTTP/')) || null,
  };
}

function phoneEndpoints() {
  if (SKIP_STREAM || !RTSP_URL || !STATUS_URL || !SNAPSHOT_URL) {
    return {
      skipped: true,
      reason: SKIP_STREAM ? '--skip-stream was provided' : 'missing iPhone stream URLs',
      status: null,
      snapshot: null,
      rtsp: null,
    };
  }
  const status = run('/usr/bin/curl', ['-sS', '--max-time', '5', STATUS_URL], { timeout: 8000 });
  const snapshot = run('/usr/bin/curl', ['-sS', '-I', '--max-time', '5', SNAPSHOT_URL], { timeout: 8000 });
  const rtspAttempts = [];
  let rtsp = null;
  if (FFPROBE) {
    for (let attempt = 1; attempt <= 2; attempt++) {
      rtsp = run(FFPROBE, ['-v', 'error', '-rtsp_transport', 'tcp', '-timeout', '15000000', '-i', RTSP_URL, '-show_entries', 'stream=codec_name,width,height', '-of', 'json'], { timeout: 22000 });
      rtspAttempts.push({
        attempt,
        ok: rtsp.status === 0,
        status: rtsp.status,
        signal: rtsp.signal,
        error: rtsp.error?.message,
        output: (rtsp.stdout || rtsp.stderr || '').slice(0, 800),
      });
      if (rtsp.status === 0)
        break;
    }
  } else {
    rtsp = { status: null, signal: null, stdout: '', stderr: 'ffprobe not found' };
    rtspAttempts.push({
      attempt: 1,
      ok: false,
      status: null,
      signal: null,
      error: 'ffprobe not found',
      output: '',
    });
  }
  return {
    skipped: false,
    status: {
      ok: status.status === 0,
      output: (status.stdout || status.stderr || '').slice(0, 1200),
    },
    snapshot: {
      ok: snapshot.status === 0 && /^HTTP\/.* 200\b/m.test(snapshot.stdout || ''),
      output: (snapshot.stdout || snapshot.stderr || '').slice(0, 1200),
    },
    rtsp: {
      ok: rtsp.status === 0,
      output: (rtsp.stdout || rtsp.stderr || '').slice(0, 1600),
      status: rtsp.status,
      signal: rtsp.signal,
      attempts: rtspAttempts,
    },
  };
}

function configuredScript() {
  return fs.readFileSync(SCRIPT_PATH, 'utf8')
    .replace(/const RTSP_URL = .*;/, `const RTSP_URL = ${JSON.stringify(RTSP_URL)};`)
    .replace(/const STATUS_URL = .*;/, `const STATUS_URL = ${JSON.stringify(STATUS_URL)};`)
    .replace(/const SNAPSHOT_URL = .*;/, `const SNAPSHOT_URL = ${JSON.stringify(SNAPSHOT_URL)};`);
}

function findDevices(state) {
  return Object.entries(state).map(([id, d]) => ({
    id,
    name: d.name?.value,
    pluginId: d.pluginId?.value,
    providerId: d.providerId?.value,
    interfaces: d.interfaces?.value || [],
    mixins: d.mixins?.value || [],
    type: d.type?.value,
  }));
}

function findByName(devices, name) {
  return devices.find(d => d.name === name);
}

async function sleep(ms) {
  await new Promise(resolve => setTimeout(resolve, ms));
}

async function applyScriptDevice(sdk, report) {
  const script = configuredScript();
  let devices = findDevices(sdk.systemManager.getSystemState());
  const scripts = devices.find(d => d.name === 'Scripts' && d.interfaces.includes('DeviceCreator'));
  if (!scripts)
    throw new Error('Scrypted Scripts device creator was not found.');

  let deviceInfo = findByName(devices, DEVICE_NAME);
  const scriptsDevice = sdk.systemManager.getDeviceById(scripts.id);
  if (!deviceInfo) {
    report.actions.push(`creating Scrypted script device ${DEVICE_NAME}`);
    await scriptsDevice.createDevice({ name: DEVICE_NAME });
    await sleep(1500);
    devices = findDevices(sdk.systemManager.getSystemState());
    deviceInfo = findByName(devices, DEVICE_NAME);
  }
  if (!deviceInfo)
    throw new Error(`Unable to find Scrypted device after createDevice: ${DEVICE_NAME}`);

  const device = sdk.systemManager.getDeviceById(deviceInfo.id);
  report.actions.push(`saving camera script on device ${deviceInfo.id}`);
  await device.saveScript({ script });
  await device.run();
  await sleep(2000);
  try {
    report.actions.push(`setting Scrypted device type to Camera`);
    await device.setType('Camera');
  } catch (error) {
    report.warnings.push(`Unable to set Scrypted device type automatically: ${error.message || error}. Set the type to Camera in the Scrypted UI.`);
  }

  devices = findDevices(sdk.systemManager.getSystemState());
  deviceInfo = findByName(devices, DEVICE_NAME) || deviceInfo;
  const homeKit = devices.find(d => d.name === 'HomeKit');
  const prebuffer = devices.find(d => d.name === 'Rebroadcast Plugin' || d.pluginId === PREBUFFER_PLUGIN);
  const mixinIds = [
    prebuffer?.id,
    homeKit?.id,
  ].filter(Boolean);
  const nextMixins = [...new Set([...(deviceInfo.mixins || []), ...mixinIds])];
  if (homeKit) {
    try {
      report.actions.push(`setting camera mixins: ${nextMixins.join(', ')}`);
      const plugins = await sdk.systemManager.getComponent('plugins');
      await plugins.setMixins(deviceInfo.id, nextMixins);
    } catch (error) {
      report.warnings.push(`Unable to set camera mixins automatically: ${error.message || error}. Add the HomeKit and Rebroadcast mixins in the Scrypted UI.`);
    }
  } else {
    report.warnings.push('HomeKit plugin was not found; install or enable Scrypted HomeKit, then add the HomeKit mixin in the UI.');
  }
  if (!prebuffer)
    report.warnings.push('Rebroadcast Plugin was not found; install @scrypted/prebuffer-mixin, then add the Rebroadcast mixin in the UI.');

  await sleep(2000);
  await configureHomeKitAndHksv(device, report);

  devices = findDevices(sdk.systemManager.getSystemState());
  return findByName(devices, DEVICE_NAME);
}

async function configureHomeKitAndHksv(device, report) {
  const settings = [
    ['homekit:standalone', true],
    ['homekit:rtpSender', 'FFmpeg'],
    ['homekit:debugMode', []],
    ['prebuffer:noAudio', true],
    ['prebuffer:enabledStreams', ['RTSP H.264']],
  ];

  for (const [key, value] of settings) {
    try {
      await device.putSetting(key, value);
      report.actions.push(`setting ${key}=${JSON.stringify(value)}`);
    } catch (error) {
      report.warnings.push(`Unable to set ${key}: ${error.message || error}`);
    }
  }

  try {
    const keys = new Set(settings.map(([key]) => key).concat([
      'homekit:pincode',
      'prebuffer:detectedResolution',
      'prebuffer:detectedCodec',
      'prebuffer:detectedKeyframe',
      'prebuffer:rtspRebroadcastUrl',
    ]));
    report.scrypted.hksvSettings = (await device.getSettings())
      .filter(setting => keys.has(setting.key))
      .map(setting => ({
        key: setting.key,
        title: setting.title,
        value: setting.value,
      }));
  } catch (error) {
    report.warnings.push(`Unable to read HKSV settings after apply: ${error.message || error}`);
  }
}

async function scryptedSnapshot(sdk) {
  const devices = findDevices(sdk.systemManager.getSystemState());
  const pluginSummary = devices
    .filter(d => ['Scrypted Core', 'Scripts', 'WebRTC Plugin', 'Rebroadcast Plugin', 'Snapshot Plugin', 'HomeKit'].includes(d.name) || /rtsp|prebuffer/i.test(`${d.name} ${d.pluginId}`))
    .map(d => ({ id: d.id, name: d.name, pluginId: d.pluginId, interfaces: d.interfaces, type: d.type }));
  return {
    plugins: pluginSummary,
    existingDevice: findByName(devices, DEVICE_NAME) || null,
    hasRTSPPlugin: pluginSummary.some(d => /rtsp/i.test(`${d.name} ${d.pluginId}`)),
    hasPrebufferPlugin: pluginSummary.some(d => d.name === 'Rebroadcast Plugin' || d.pluginId === PREBUFFER_PLUGIN),
  };
}

function installPrebufferPlugin(report) {
  report.actions.push(`installing ${PREBUFFER_PLUGIN}`);
  const result = run('npx', ['scrypted', 'install', PREBUFFER_PLUGIN, HOST], {
    cwd: SCRYPTED_HOME,
    timeout: 60000,
  });
  const output = `${result.stdout || ''}${result.stderr || ''}`.trim();
  if (output)
    report.actions.push(output);
  if (result.status !== 0)
    report.warnings.push(`Unable to install ${PREBUFFER_PLUGIN}: ${output || result.signal || result.status}`);
}

async function main() {
  const report = {
    at: new Date().toISOString(),
    apply: APPLY,
    deviceName: DEVICE_NAME,
    discovery: {
      bonjourType: BONJOUR_TYPE,
      discovered: DISCOVERED_PHONE,
      host: PHONE_HOST || null,
      source: process.env.IPHONE_SECURITYCAM_RTSP_URL ? 'explicit urls' : process.env.IPHONE_SECURITYCAM_HOST ? 'IPHONE_SECURITYCAM_HOST' : process.env.DEVICE_IP ? 'DEVICE_IP' : DISCOVERED_PHONE.host ? 'bonjour' : 'none',
    },
    urls: {
      rtsp: RTSP_URL,
      status: STATUS_URL,
      snapshot: SNAPSHOT_URL,
    },
    service: serviceSnapshot(),
    https: httpsReady(),
    phone: phoneEndpoints(),
    scrypted: null,
    actions: [],
    warnings: [],
    issues: [],
  };

  if (APPLY && (!RTSP_URL || !STATUS_URL || !SNAPSHOT_URL)) {
    report.issues.push('Set IPHONE_SECURITYCAM_HOST or DEVICE_IP before --apply, or provide IPHONE_SECURITYCAM_RTSP_URL, IPHONE_SECURITYCAM_STATUS_URL, and IPHONE_SECURITYCAM_SNAPSHOT_URL.');
    report.ok = false;
    console.log(JSON.stringify(report, null, 2));
    process.exit(1);
  }

  let sdk = await connectScrypted();
  try {
    report.scrypted = await scryptedSnapshot(sdk);
    if (!report.scrypted.hasRTSPPlugin) {
      report.warnings.push('No dedicated RTSP plugin is currently installed. The helper will use a script-backed camera device; install Scrypted RTSP plugin later if you want a first-class RTSP importer.');
    }
    if (APPLY && !report.scrypted.hasPrebufferPlugin) {
      sdk.disconnect();
      sdk = null;
      installPrebufferPlugin(report);
      await sleep(2000);
      sdk = await connectScrypted();
      report.scrypted = await scryptedSnapshot(sdk);
    }

    if (APPLY) {
      report.scrypted.appliedDevice = await applyScriptDevice(sdk, report);
    }
  } finally {
    sdk?.disconnect();
  }

  if (!report.service.ok)
    report.issues.push('Scrypted LaunchAgent is not running.');
  if (!report.https.ok)
    report.issues.push('Scrypted HTTPS endpoint is not ready.');
  if (!SKIP_STREAM) {
    if (!report.phone.status?.ok)
      report.issues.push('iPhone status endpoint is not reachable yet.');
    if (!report.phone.snapshot?.ok)
      report.issues.push('iPhone snapshot endpoint is not ready yet.');
    if (!report.phone.rtsp?.ok)
      report.issues.push('iPhone RTSP stream is not ready yet.');
  }
  if (APPLY && !report.scrypted?.appliedDevice)
    report.issues.push('Scrypted apply did not produce an iPhone camera device.');

  report.ok = report.issues.length === 0;
  console.log(JSON.stringify(report, null, 2));
  process.exit(report.ok ? 0 : 1);
}

main().catch(error => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});
